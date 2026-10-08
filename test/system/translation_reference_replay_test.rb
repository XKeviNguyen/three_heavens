require "application_system_test_case"

class TranslationReferenceReplayTest < ApplicationSystemTestCase
  test "a lost create redirect keeps the form action and retries to the same reference" do
    visit login_path
    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
    visit new_translation_reference_path
    fill_in "Title", with: "Lost redirect reference"
    choose_known_language("Source language", "English")
    choose_known_language("Target language", "Japanese")
    fill_in "Pasted source text", with: "Reference source"
    fill_in "Pasted approved translation", with: "Approved reference"
    key = find("input[name='translation_reference[creation_key]']", visible: :all).value
    page.execute_script(<<~JS)
      const deliver = window.fetch.bind(window)
      window.fetch = async (url, options = {}) => {
        const response = await deliver(url, options)
        if (new URL(url, location.origin).pathname === "/translation_references" && options.method?.toUpperCase() === "POST" && !window.__referenceRedirectLost) {
          await response.arrayBuffer()
          window.__referenceRedirectLost = true
          document.body.dataset.referenceRedirectLost = "true"
          throw new TypeError("synthetic lost redirect")
        }
        return response
      }
    JS
    click_button "Create a reference"
    assert_selector "body[data-reference-redirect-lost='true']"
    reference = users(:normal).translation_references.sole
    assert_equal key, find("input[name='translation_reference[creation_key]']", visible: :all).value
    click_button "Create a reference"
    assert_current_path translation_reference_path(reference)
    assert_selector "h1", text: "Lost redirect reference"
    assert_equal 1, users(:normal).translation_references.count
    assert_equal key, TranslationReferenceCreation.find_by!(translation_reference: reference).creation_key
    assert_equal 1, reference.revisions.count
  end
end
