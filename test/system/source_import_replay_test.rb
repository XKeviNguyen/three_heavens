require "application_system_test_case"

class SourceImportReplayTest < ApplicationSystemTestCase
  setup do
    visit login_path
    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  # The first delivery is stored and answered by the server, but the browser
  # discards the answer as if the connection dropped. Uploading the same chosen
  # file again must resolve to that import rather than storing a second copy.
  test "retrying an upload whose response was lost keeps one import and one blob" do
    visit new_translation_workspace_path
    click_button "Upload file"
    source = Tempfile.new([ "lost-response", ".txt" ])
    source.write("Uploaded once despite a lost response")
    source.flush
    attach_file "Source file", source.path
    page.execute_script(<<~JS)
      const deliver = window.fetch.bind(window)
      window.__pendingUploadDrops = 1
      window.fetch = async (url, options = {}) => {
        const response = await deliver(url, options)
        if (new URL(url, location.origin).pathname === "/source_imports.json" && window.__pendingUploadDrops > 0) {
          window.__pendingUploadDrops -= 1
          await response.arrayBuffer()
          throw new TypeError("Failed to fetch")
        }
        return response
      }
    JS

    click_button "Upload and review"
    assert_text "Failed to fetch"
    assert_equal 1, users(:normal).source_imports.count

    click_button "Upload and review"
    assert_field "Reviewed source text", with: "Uploaded once despite a lost response"
    source_import = users(:normal).source_imports.sole
    assert_equal source_import.id.to_s, find("#translation_workspace_source_import_id", visible: :all).value
    assert_equal 1, ActiveStorage::Attachment.where(record: source_import).count
  ensure
    source&.close!
  end
end
