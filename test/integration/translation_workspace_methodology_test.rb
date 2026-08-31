require "test_helper"
require_relative "../support/methodology_profile_test_helper"
require_relative "../support/workflow_profile_test_helper"

class TranslationWorkspaceMethodologyTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MethodologyProfileTestHelper
  include WorkflowProfileTestHelper

  setup do
    sign_in_as users(:normal)
    @model = llm_models(:openrouter_claude)
  end

  test "manual launch snapshots the exact current methodology revision" do
    methodology = create_methodology_profile
    selected = methodology.current_revision

    get new_translation_workspace_path
    assert_response :success
    assert_select "input[name='translation_workspace[methodology_profile_revision_id]'][value='#{selected.id}']"

    assert_difference -> { Experiment.count }, 1 do
      post translation_workspace_path, params: {
        translation_workspace: workspace_params.merge(
          methodology_profile_revision_id: selected.id.to_s
        )
      }
    end

    experiment = Experiment.order(:id).last
    assert_redirected_to experiment_path(experiment)
    assert_equal selected, experiment.methodology_profile_revision
    get experiment_path(experiment)
    assert_response :success
    assert_includes response.body, "#{selected.name} · revision #{selected.version}"
    get history_path
    assert_response :success
    assert_includes response.body, "#{selected.name} · revision #{selected.version}"

    MethodologyProfiles::Revise.call(
      methodology_profile: methodology,
      expected_version: "1",
      attributes: methodology_profile_attributes(guidance: "Future guidance")
    )
    MethodologyProfiles::ChangeStatus.deactivate(methodology_profile: methodology)
    assert_equal selected, experiment.reload.methodology_profile_revision
    assert_equal "Preserve theological nuance.\n\nUse a natural literary register.", experiment.methodology_profile_revision.guidance
  end

  test "automatic launch snapshots methodology independently from workflow and glossary" do
    methodology = create_methodology_profile
    workflow = create_workflow_profile
    glossary = Glossaries::Create.call(
      user: users(:normal),
      attributes: {
        name: "Terms", source_language: "Vietnamese", target_language: "Japanese",
        entries: [ { source_term: "Source", preferred_target_term: "原文" } ]
      }
    )

    assert_difference -> { PipelineRun.count }, 1 do
      post translation_workspace_path, params: {
        translation_workspace: workspace_params.merge(
          workflow_mode: "automatic",
          model_ids: [],
          workflow_profile_revision_id: workflow.current_revision_id.to_s,
          glossary_revision_id: glossary.current_revision_id.to_s,
          methodology_profile_revision_id: methodology.current_revision_id.to_s,
          automatic_confirmation: "1"
        )
      }
    end

    experiment = PipelineRun.order(:id).last.experiment
    assert_equal workflow.current_revision, experiment.pipeline_run.workflow_profile_revision
    assert_equal glossary.current_revision, experiment.glossary_revision
    assert_equal methodology.current_revision, experiment.methodology_profile_revision
    get pipeline_run_path(experiment.pipeline_run)
    assert_response :success
    assert_includes response.body, "#{methodology.current_revision.name} · revision #{methodology.current_revision.version}"
  end

  test "malformed foreign archived stale and mismatched methodology selections are rejected" do
    foreign = create_methodology_profile(user: users(:other))
    archived = create_methodology_profile(name: "Archived")
    MethodologyProfiles::ChangeStatus.deactivate(methodology_profile: archived)
    stale = create_methodology_profile(name: "Stale")
    old_revision = stale.current_revision
    MethodologyProfiles::Revise.call(
      methodology_profile: stale,
      expected_version: "1",
      attributes: methodology_profile_attributes(name: "Stale current", guidance: "Current")
    )
    mismatch = create_methodology_profile(name: "Mismatch", target_language: "English")

    values = [
      "not-an-id",
      foreign.current_revision_id.to_s,
      archived.current_revision_id.to_s,
      old_revision.id.to_s,
      mismatch.current_revision_id.to_s
    ]
    values.each do |value|
      assert_no_difference -> { Experiment.count } do
        post translation_workspace_path, params: {
          translation_workspace: workspace_params.merge(
            submission_token: issue_translation_workspace_token,
            methodology_profile_revision_id: value
          )
        }
      end
      assert_response :unprocessable_content
    end
  end

  test "no methodology preserves existing launch behavior and parameter boundary is scalar" do
    assert_difference -> { Experiment.count }, 1 do
      post translation_workspace_path, params: { translation_workspace: workspace_params }
    end
    assert_nil Experiment.order(:id).last.methodology_profile_revision

    assert_no_difference -> { Experiment.count } do
      post translation_workspace_path, params: {
        translation_workspace: workspace_params.merge(
          submission_token: issue_translation_workspace_token,
          methodology_profile_revision_id: [ "1" ]
        )
      }
    end
    assert_response :bad_request
  end

  private

  def workspace_params
    {
      project_name: "Methodology workspace",
      source_language: "Vietnamese",
      target_language: "Japanese",
      document_title: "Source",
      source_text: "Source theological text",
      experiment_name: "Methodology experiment",
      instruction_prompt: "Translate faithfully.",
      workflow_mode: "manual",
      model_ids: [ @model.id.to_s ],
      submission_token: issue_translation_workspace_token
    }
  end
end
