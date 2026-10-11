require "application_system_test_case"

class TranslationReferenceUploadTest < ApplicationSystemTestCase
  PASSWORD = "correct horse battery staple".freeze

  setup do
    @user = users(:normal)
    @files = Dir.mktmpdir("reference-upload")
    sign_in_in_browser
    visit new_translation_reference_path
    assert_selector "[data-react-island='file-field'][data-react-mounted='true']", count: 2
  end

  teardown { FileUtils.remove_entry(@files) }

  test "each file is chosen, replaced, and removed on its own, and the form submits both" do
    source = file("Nguồn ベトナム 🎉.txt", "Xin chào thế giới.")
    approved = file("approved.md", "こんにちは、世界。")

    attach_file "Or upload source file", source
    within(source_field) { assert_selection "Nguồn ベトナム 🎉.txt", "23 B" }
    attach_file "Or upload approved translation file", file("draft.txt", "Draft")
    attach_file "Or upload approved translation file", approved
    within(translation_field) do
      assert_selection "approved.md", "27 B"
      assert_button "Choose a different file"
    end

    remove = source_field.find_button("Remove")
    assert_equal "Remove Nguồn ベトナム 🎉.txt", remove["aria-label"]
    remove.click
    within(source_field) { assert_text "No file selected." }
    assert_equal "Choose file", active_element_text, "focus returns to the choose button"
    assert_equal [ 0, 1 ], selected_file_counts
    within(translation_field) { assert_selection "approved.md", "27 B" }

    attach_file "Or upload source file", source
    fill_in "Title", with: "Greeting"
    choose_known_language "Source language", "Vietnamese"
    choose_known_language "Target language", "Japanese"
    assert_equal [ 1, 1 ], selected_file_counts
    assert_equal 0, TranslationReference.count, "choosing files never submits the form"

    click_button "Create a reference"

    assert_text "Xin chào thế giới."
    assert_text "こんにちは、世界。"
    assert_equal 1, @user.translation_references.count
  end

  test "unsupported, oversized, and multiple files are refused and the accepted file is kept" do
    attach_file "Or upload source file", file("source.txt", "Source")
    attach_file "Or upload source file", file("notes.csv", "a,b")
    within(source_field) do
      assert_text "notes.csv is not a supported file."
      assert_selection "source.txt", "6 B"
    end
    assert_equal [ 1, 0 ], selected_file_counts

    oversized = file("large.pdf", "")
    File.truncate(oversized, SourceImports::Limits::MAX_UPLOAD_BYTES + 1)
    attach_file "Or upload approved translation file", oversized
    within(translation_field) do
      assert_text "large.pdf is larger than the upload limit."
      assert_text "No file selected."
    end
    assert_equal [ 1, 0 ], selected_file_counts

    drop_files(translation_field, "one.txt", "two.txt")
    within(translation_field) { assert_text "Choose one file only." }
    assert_equal [ 1, 0 ], selected_file_counts

    drop_files(translation_field, "dropped.txt")
    within(translation_field) { assert_selection "dropped.txt", "11 B" }
    assert_equal [ 1, 1 ], selected_file_counts
    assert_current_path new_translation_reference_path
    assert_equal 0, TranslationReference.count, "dropping a file never creates a reference"
  end

  test "pasting text and choosing a file for the same side is flagged before saving" do
    attach_file "Or upload source file", file("source.txt", "Source")
    within(source_field) { assert_no_text "You also pasted text above." }

    fill_in "Pasted source text", with: "Also pasted"
    within(source_field) { assert_text "You also pasted text above." }
    within(translation_field) { assert_no_text "You also pasted text above." }
  end

  private

  def sign_in_in_browser
    visit login_path
    find("input[type=email]").fill_in with: @user.email
    find("input[type=password]").fill_in with: PASSWORD
    find("input[type=email]").ancestor("form").find("[type=submit]").click
    assert_selector "#app-sidebar", visible: :all
  end

  def file(name, content)
    path = File.join(@files, name)
    File.write(path, content)
    path
  end

  def source_field = find_field("Or upload source file", visible: :all).ancestor("[data-react-island='file-field']")

  def translation_field = find_field("Or upload approved translation file", visible: :all).ancestor("[data-react-island='file-field']")

  def assert_selection(name, size)
    within("[data-testid='file-field-selection']") do
      assert_text name
      assert_text size
    end
  end

  # What the Rails form would submit for each file input.
  def selected_file_counts
    page.evaluate_script(<<~JS)
      ["translation_reference[source_file]", "translation_reference[approved_translation_file]"].map((name) => document.querySelector(`input[type=file][name="${name}"]`).files.length)
    JS
  end

  def drop_files(field, *names)
    page.execute_script(<<~JS, field.find("[data-testid='file-field']"), names)
      const [zone, names] = arguments
      const transfer = new DataTransfer()
      names.forEach((name) => transfer.items.add(new File([`${name} body`.slice(0, 11)], name, { type: "text/plain" })))
      zone.dispatchEvent(new DragEvent("dragover", { dataTransfer: transfer, bubbles: true, cancelable: true }))
      zone.dispatchEvent(new DragEvent("drop", { dataTransfer: transfer, bubbles: true, cancelable: true }))
    JS
  end

  def active_element_text
    page.evaluate_script("document.activeElement.textContent.trim()")
  end
end

# Without JavaScript the server-rendered input is the form's file field.
class TranslationReferenceUploadWithoutJavascriptTest < ActionDispatch::SystemTestCase
  driven_by :rack_test

  test "the plain file inputs submit a reference" do
    user = users(:normal)
    visit login_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"

    visit new_translation_reference_path
    assert_selector "[data-react-island='file-field'] input[type=file][name='translation_reference[source_file]']"
    Dir.mktmpdir do |directory|
      source = File.join(directory, "source.txt").tap { |path| File.write(path, "Plain source") }
      approved = File.join(directory, "approved.txt").tap { |path| File.write(path, "Plain approved") }
      fill_in "Title", with: "Without JavaScript"
      # The language combobox needs JavaScript (a pre-existing limitation);
      # set its submitted values to test the file inputs alone.
      find("#translation_reference_source_language-value", visible: false).set("Vietnamese")
      find("#translation_reference_target_language-value", visible: false).set("Japanese")

      attach_file "Or upload source file", source
      attach_file "Or upload approved translation file", approved
      click_button "Create a reference"
    end

    assert_text "Plain source"
    assert_text "Plain approved"
    assert_equal 1, user.translation_references.count
  end
end
