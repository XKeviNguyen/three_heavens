require "application_system_test_case"

class ModelBrowserFallbackTest < ApplicationSystemTestCase
  test "saved outage choice submits a persisted ID and survives rejected form and draft restore" do
    user = users(:normal)
    saved = llm_models(:openrouter_claude)
    OpenRouter::Catalog.transport = -> { raise OpenRouter::Catalog::Error }
    visit login_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
    visit new_translation_workspace_path
    within "#workspace-manual-models" do
      find("[role=option][data-identifier='#{saved.model_identifier}'] button").click
      assert_selector "input[name='translation_workspace[model_ids][]'][value='#{saved.id}']", visible: :all
      assert_no_selector "input[name='translation_workspace[model_identifiers][]']", visible: :all
    end
    fill_in "Project name", with: "Outage project"
    choose_known_language "Source language", "Vietnamese"
    choose_known_language "Target language", "Japanese"
    fill_in "Document title", with: "Outage source"
    click_button "Paste text"
    fill_in "Source text", with: "Nguồn cho bản dịch."
    fill_in "Instructions for the translation", with: "Translate faithfully."
    # Explicitly save before refresh, using the real autosave status as a barrier.
    assert_selector "[data-workspace-guard-target='status']", text: I18n.t("workspace.saved")
    refresh
    assert_field "Project name", with: "Outage project"
    assert_selector "input[name='translation_workspace[model_ids][]'][value='#{saved.id}']", visible: :all
    fill_in "Instructions for the translation", with: "   "
    click_button "Start translation"
    assert_selector "#form-errors-heading"
    assert_selector "input[name='translation_workspace[model_ids][]'][value='#{saved.id}']", visible: :all
    fill_in "Instructions for the translation", with: "Translate faithfully."
    assert_difference -> { TranslationRun.count }, 1 do
      assert_no_difference -> { AiProviderAttempt.count } do
        click_button "Start translation"
        assert_text "Outage source"
        assert_no_selector "#workspace-form"
      end
    end
  end
end
