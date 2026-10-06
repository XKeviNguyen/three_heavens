require "application_system_test_case"
require_relative "../support/methodology_profile_test_helper"
require_relative "../support/workflow_profile_test_helper"

# Changing a configuration page saves the draft, posts, and shows the
# requested page restored from that draft; the URL carries only identifiers.
class TranslationWorkspacePaginationTest < ApplicationSystemTestCase
  include MethodologyProfileTestHelper
  include WorkflowProfileTestHelper

  setup do
    @oldest = create_methodology_profile(name: "Oldest methodology")
    TranslationWorkspacesController::CONFIGURATION_OPTION_LIMIT.times { |index| create_methodology_profile(name: "Paged methodology #{index}") }
    visit login_path
    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  test "an edit made just before Older is kept on the requested page without a launch" do
    visit new_translation_workspace_path
    assert_field "Project name"
    fill_in "Project name", with: "Typed just before paging"
    assert_no_difference [ -> { Experiment.count }, -> { TranslationWorkspaceSubmission.count } ] do
      change_methodology_page(2)
    end
    assert_field "Project name", with: "Typed just before paging"
    assert_equal "Typed just before paging", draft_payload.fetch("project_name")
  end

  test "a selection survives Older then Newer, including one outside the shown page" do
    visit new_translation_workspace_path
    # A methodology applies only to its own language pair.
    choose_known_language("Source language", "Vietnamese")
    choose_known_language("Target language", "Japanese")
    # Newest first: the oldest profile is on page 2.
    change_methodology_page(2)
    open_methodology
    find("input[name='translation_workspace[methodology_profile_revision_id]'][value='#{@oldest.current_revision_id}']", visible: :all)
      .find(:xpath, "./ancestor::label[1]").click
    assert_until { draft_payload&.fetch("methodology_profile_revision_id", nil) == @oldest.current_revision_id.to_s }

    change_methodology_page(1)
    assert_selector "input[name='translation_workspace[methodology_profile_revision_id]'][value='#{@oldest.current_revision_id}']:checked", visible: :all
    change_methodology_page(2)
    assert_selector "input[name='translation_workspace[methodology_profile_revision_id]'][value='#{@oldest.current_revision_id}']:checked", visible: :all
  end

  test "a large source is restored from the draft and never placed in the URL" do
    visit new_translation_workspace_path
    source = "Private paragraph #{'x' * 120}. " * 60
    fill_in "Source text", with: source
    change_methodology_page(2)
    assert_equal source.strip, find_field("Source text").value.strip
    url = page.evaluate_script("location.href")
    assert_no_match(/Private|paragraph/, url)
    assert_operator url.length, :<, 200
    assert_equal "methodology_profile_page=2", URI.parse(url).query
  end

  test "an existing project keeps its context across a page change" do
    project = users(:normal).projects.create!(name: "Paged project", source_language: "Vietnamese", target_language: "Japanese")
    visit new_translation_workspace_path(project_id: project.id)
    fill_in "Document title", with: "Project document"
    change_methodology_page(2)
    assert_equal({ "project_id" => [ project.id.to_s ], "methodology_profile_page" => [ "2" ] }, CGI.parse(URI.parse(page.evaluate_script("location.href")).query))
    assert_field "Document title", with: "Project document"
    assert_equal "Project document", draft_payload(project).fetch("document_title")
  end

  test "Back after a page change shows the current draft, not the earlier page state" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Before paging"
    change_methodology_page(2)
    fill_in "Project name", with: "Edited on page two"
    assert_selector "[data-workspace-guard-target='status']", text: I18n.t("workspace.saved")
    page.go_back
    assert_current_path new_translation_workspace_path
    assert_field "Project name", with: "Edited on page two"
  end

  test "the paid-work authorization survives a page change only while its plan holds" do
    first_workflow = create_workflow_profile(name: "First workflow")
    second_workflow = create_workflow_profile(name: "Second workflow", completion_mode: "refinement_proposals")
    visit new_translation_workspace_path
    fill_in "Source text", with: "A source for the automatic plan."
    find("label", text: "Automatic").click
    find("input[name='translation_workspace[workflow_profile_revision_id]'][value='#{first_workflow.current_revision_id}']").choose
    check I18n.t("workflow_ui.authorize_plan")

    # Nothing showed the plan yet, so nothing specific was authorized.
    change_methodology_page(2)
    assert_text I18n.t("workflow_ui.paid_authorization")
    assert_no_checked_field I18n.t("workflow_ui.authorize_plan")

    check I18n.t("workflow_ui.authorize_plan")
    change_methodology_page(1)
    assert_checked_field I18n.t("workflow_ui.authorize_plan")

    find("input[name='translation_workspace[workflow_profile_revision_id]'][value='#{second_workflow.current_revision_id}']").choose
    change_methodology_page(2)
    assert_no_checked_field I18n.t("workflow_ui.authorize_plan")
  end

  private

  def open_methodology
    summary = find("details > summary", text: I18n.t("workspace_ui.advanced"))
    summary.click unless summary.find(:xpath, "..").matches_css?("[open]")
  end

  # Clicks the methodology list's page button and waits for the requested page.
  def change_methodology_page(number)
    open_methodology
    find("nav[aria-label='Methodology profiles pagination'] button[name='methodology_profile_page'][value='#{number}']").click
    assert_selector "nav[aria-label='Methodology profiles pagination']", text: /Page #{number} of 2/, visible: :all
  end

  def draft_payload(project = nil)
    users(:normal).translation_workspace_drafts.find_by(context_key: TranslationWorkspaceDraft.context_key(project))&.payload
  end

  def assert_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end
end
