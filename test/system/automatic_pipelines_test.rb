require "application_system_test_case"
require_relative "../support/workflow_profile_test_helper"

class AutomaticPipelinesTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include WorkflowProfileTestHelper

  test "owner creates edits and duplicates a winner draft profile in the browser" do
    sign_in_in_browser(users(:normal), "correct horse battery staple")
    visit new_workflow_profile_path
    fill_in "Name", with: "Browser winner profile"
    fill_in "Description", with: "Browser managed"
    choose "Winner draft only"
    select_role_models
    click_button "Create workflow setup"

    assert_text "Workflow setup created."
    assert_text "Version 1 · Current"
    assert_text "Translators (2)"
    assert_text "Reviewers (1)"
    assert_text "Judges (1)"
    assert_text "Suggestion models (0)"

    click_link "Edit", match: :first
    fill_in "Name", with: "Browser winner profile revised"
    click_button "Save new version"
    assert_text "Workflow setup saved as version 2."
    assert_text "Version 2 · Current"
    assert_text "Version 1"

    visit workflow_profiles_path
    click_button "Duplicate", match: :first
    assert_text "Workflow setup duplicated."
    assert_text "Copy of Browser winner profile revised"

    visit new_workflow_profile_path
    fill_in "Name", with: "Browser refinement profile"
    choose "Winner draft + AI suggestions"
    select_role_models(finalizer: true)
    click_button "Create workflow setup"

    assert_text "Workflow setup created."
    assert_text "Winner draft + AI suggestions"
    assert_text "Suggestion models (1)"
  end

  test "automatic workspace requires confirmation starts a pipeline and lets owner stop" do
    profile = create_workflow_profile
    sign_in_in_browser(users(:normal), "correct horse battery staple")
    visit new_translation_workspace_path
    fill_workspace
    assert_selector "fieldset[data-workflow-mode-target='manual']", visible: true
    assert_selector "fieldset[data-workflow-mode-target='automatic']", visible: false
    choose "Automatic"
    assert_selector "fieldset[data-workflow-mode-target='manual']", visible: false
    assert_selector "fieldset[data-workflow-mode-target='automatic']", visible: true
    choose "translation_workspace_workflow_profile_revision_id_#{profile.current_revision_id}"

    click_button "Start translation"
    assert_text "Cost approval must be checked each time you start a translation"
    assert_field "Automatic", checked: true
    assert_selector "fieldset[data-workflow-mode-target='automatic']", visible: true
    assert_equal 0, PipelineRun.count

    check "translation_workspace_automatic_confirmation"
    assert_enqueued_jobs 2, only: TranslationRunJob do
      click_button "Start translation"
      assert_text "Automatic workflow started."
    end
    pipeline = PipelineRun.order(:id).last
    assert_text profile.name
    assert_text "Version 1"
    assert_text "Translation"
    assert_button "Stop automation"

    accept_confirm { click_button "Stop automation" }
    assert_text "Automation stopped. AI requests that had already started will still finish."
    assert pipeline.reload.stopped?
  end

  test "private profile and pipeline pages reject another owner and editor-ready page has no automatic editorial action" do
    profile = create_workflow_profile
    pipeline = create_pipeline_run(experiment: experiments(:one), profile: profile)
    pipeline.update!(status: :ready_for_editor, current_stage: :editor, ready_for_editor_at: Time.current)

    sign_in_in_browser(users(:normal), "correct horse battery staple")
    visit pipeline_run_path(pipeline)
    assert_text "Ready for you to edit"
    assert_no_button "Apply suggestion"
    assert_no_button "Finalize translation"
    assert_no_button "Stop automation"

    click_button "Log out"
    assert_text "Signed out successfully."
    sign_in_in_browser(users(:other), "other secure password value")
    visit workflow_profile_path(profile)
    assert_text "We couldn’t find that page"
    visit pipeline_run_path(pipeline)
    assert_text "We couldn’t find that page"
  end

  private

  def sign_in_in_browser(user, password)
    visit login_path
    fill_in "Email", with: user.email
    fill_in "Password", with: password
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  def select_role_models(finalizer: false)
    add_catalog_models("Translators", 2)
    add_catalog_models("Reviewers", 1)
    add_catalog_models("Judges", 1)
    add_catalog_models("Suggestion models", 1) if finalizer
  end

  def add_catalog_models(role_label, count)
    within find("fieldset", text: role_label, match: :first) do
      find("input[placeholder='Search OpenRouter models…']").click
      count.times do
        assert_selector "button", text: "Add", exact_text: true
        first("button", text: "Add", exact_text: true).click
      end
    end
  end

  def fill_workspace
    fill_in "Project name", with: "Automatic system project"
    choose_known_language "Source language", "Vietnamese"
    choose_known_language "Target language", "Japanese"
    fill_in "Document title", with: "Automatic system source"
    fill_in "Source text", with: "Source for deterministic browser test"
    fill_in "Translation name", with: "Automatic system experiment"
    fill_in "Instructions for the translation", with: "Translate faithfully."
  end
end
