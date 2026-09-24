require "application_system_test_case"

class TranslationWorkspaceDraftTest < ApplicationSystemTestCase
  setup do
    sign_in_in_browser
  end

  test "language search requires selection and Escape restores the committed value" do
    visit new_translation_workspace_path
    choose_language("Source language", "Vietnamese")
    source = find_field("Source language")
    assert_equal "Vietnamese", find("input[name='translation_workspace[source_language]']", visible: :all).value

    source.fill_in with: "French"
    assert_equal "", find("input[name='translation_workspace[source_language]']", visible: :all).value
    source.send_keys(:escape)
    assert_field "Source language", with: "Vietnamese"
    assert_equal "Vietnamese", find("input[name='translation_workspace[source_language]']", visible: :all).value

    source.fill_in with: "Japanese"
    source.send_keys(:arrow_down, :enter)
    assert_equal "Japanese", find("input[name='translation_workspace[source_language]']", visible: :all).value
  end

  test "switching English to Japanese to Vietnamese preserves the workspace draft" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Locale draft"
    fill_in "Source text", with: "Private source across locales"

    within "aside#app-sidebar" do
      select "日本語", from: "Interface language"
      click_button "Apply"
    end
    assert_selector "html[lang='ja']"
    assert_field "プロジェクト名", with: "Locale draft"
    assert_equal "Private source across locales", find("textarea[name='translation_workspace[source_text]']", visible: :all).value
    assert_selector "[data-workspace-guard-target='status']", text: "下書きを復元しました", wait: 10

    within "aside#app-sidebar" do
      select "Tiếng Việt", from: "表示言語"
      click_button "適用"
    end
    assert_selector "html[lang='vi']"
    assert_field "Tên dự án", with: "Locale draft"
    assert_equal "Private source across locales", find("textarea[name='translation_workspace[source_text]']", visible: :all).value
  end

  test "autosaves source and configuration then restores after navigation and refresh" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Autosaved project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    fill_in "Document title", with: "Autosaved title"
    fill_in "Source text", with: "Private autosaved source"
    fill_in "Instructions for the translation", with: "Preserve nuance."
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    assert_not_includes page.current_url, "Private autosaved source"
    assert_equal false, page.evaluate_script("Object.values(localStorage).join('').includes('Private autosaved source') || Object.values(sessionStorage).join('').includes('Private autosaved source') || JSON.stringify(history.state).includes('Private autosaved source')")

    click_link "Projects"
    assert_current_path projects_path
    assert_no_selector "dialog[open]", text: "Leave this translation?"

    click_link "New translation"
    assert_field "Project name", with: "Autosaved project"
    assert_field "Source text", with: "Private autosaved source"
    assert_field "Instructions for the translation", with: "Preserve nuance."
    refresh
    assert_field "Document title", with: "Autosaved title"
    assert_field "Source text", with: "Private autosaved source"
  end


  test "failed draft save keeps the leave protection and Stay preserves fields" do
    visit new_translation_workspace_path
    page.execute_script(<<~JS)
      window.__originalDraftFetch = window.fetch.bind(window)
      window.fetch = (url, options) => {
        if (new URL(url, location.origin).pathname === "/translation_workspace_draft") {
          return Promise.resolve(new Response("", { status: 503 }))
        }
        return window.__originalDraftFetch(url, options)
      }
    JS
    fill_in "Project name", with: "Unsaved local project"
    fill_in "Source text", with: "Unsaved local source"
    assert_selector "[data-workspace-guard-target='status']", text: "Could not save", wait: 10

    click_link "Projects"
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Stay"
    assert_current_path new_translation_workspace_path
    assert_field "Project name", with: "Unsaved local project"
    assert_field "Source text", with: "Unsaved local source"

    click_link "Projects"
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Leave without saving"
    assert_current_path projects_path
    click_link "New translation"
    assert_field "Project name", with: ""
    assert_field "Source text", with: ""
  end

  test "explicit discard clears a saved draft after confirmation" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Discard me"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10

    accept_confirm do
      click_button "Discard draft"
    end
    assert_current_path new_translation_workspace_path
    assert_field "Project name", with: ""
    assert_equal 0, users(:normal).translation_workspace_drafts.count
  end

  test "validation failure retains the draft through refresh" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Retry project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    fill_in "Document title", with: "Retry document"
    fill_in "Source text", with: "Private retry source"
    fill_in "Instructions for the translation", with: "Translate carefully."
    click_button "Start translation"
    assert_selector "#form-errors-heading"
    assert_equal 1, users(:normal).translation_workspace_drafts.count

    refresh
    assert_field "Source text", with: "Private retry source"
  end


  test "successful Start translation consumes the saved draft" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Launch project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    fill_in "Document title", with: "Launch document"
    fill_in "Source text", with: "Private launch source"
    fill_in "Instructions for the translation", with: "Translate carefully."
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add"
      first("button", text: "Add").click
    end
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    assert_equal 1, users(:normal).translation_workspace_drafts.count

    click_button "Start translation"
    assert_current_path(/\A\/experiments\/\d+\z/)
    assert_equal 0, users(:normal).translation_workspace_drafts.count
    assert_equal 0, AiProviderAttempt.count
  end

  private

  def sign_in_in_browser
    visit login_path
    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  def choose_language(label, value)
    choose_known_language(label, value)
  end
end
