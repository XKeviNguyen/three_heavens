require "test_helper"
require_relative "../support/workflow_profile_test_helper"

class GlossariesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include WorkflowProfileTestHelper

  setup { sign_in_as users(:normal) }

  test "owner lifecycle is private and strict parameters reject tampering" do
    assert_difference -> { Glossary.count }, 1 do
      post glossaries_path, params: { glossary: glossary_params }
    end
    glossary = Glossary.order(:id).last
    assert_redirected_to glossary_path(glossary)

    assert_difference -> { GlossaryRevision.count }, 1 do
      patch glossary_path(glossary), params: { glossary: glossary_params.merge(name: "Revision two", expected_version: "1") }
    end
    patch deactivate_glossary_path(glossary)
    assert_not glossary.reload.active?
    patch activate_glossary_path(glossary)
    assert glossary.reload.active?

    other = Glossaries::Create.call(user: users(:other), attributes: glossary_params)
    get glossary_path(other)
    assert_response :not_found

    [
      { glossary: "bad" },
      { glossary: glossary_params.merge(user_id: users(:other).id) },
      { glossary: glossary_params.merge(entries: "bad") },
      { glossary: glossary_params.merge(entries: [ { source_term: [ "bad" ], preferred_target_term: "神" } ]) },
      { glossary: glossary_params.merge(entries: [ { source_term: "bad", preferred_target_term: "神", id: "1" } ]) }
    ].each do |payload|
      assert_no_difference -> { Glossary.count } do
        post glossaries_path, params: payload
      end
      assert_response :bad_request
    end
  end

  test "workspace stores exact matching owned revision and rejects other owner and mismatch" do
    glossary = Glossaries::Create.call(user: users(:normal), attributes: glossary_params)
    assert_difference -> { Experiment.count }, 1 do
      post translation_workspace_path, params: { translation_workspace: workspace_params.merge(glossary_revision_id: glossary.current_revision_id.to_s) }
    end
    experiment = Experiment.order(:id).last
    assert_equal glossary.current_revision, experiment.glossary_revision
    Glossaries::Revise.call(glossary:, expected_version: "1", attributes: glossary_params.merge(name: "Future revision"))
    assert_equal 1, experiment.reload.glossary_revision.version
    assert_not experiment.update(glossary_revision: glossary.current_revision)

    other = Glossaries::Create.call(user: users(:other), attributes: glossary_params)
    assert_no_difference -> { Experiment.count } do
      post translation_workspace_path, params: { translation_workspace: workspace_params.merge(glossary_revision_id: other.current_revision_id.to_s) }
    end
    assert_response :unprocessable_content

    mismatch = Glossaries::Create.call(user: users(:normal), attributes: glossary_params.merge(target_language: "English"))
    assert_no_difference -> { Experiment.count } do
      post translation_workspace_path, params: { translation_workspace: workspace_params.merge(glossary_revision_id: mismatch.current_revision_id.to_s) }
    end
    assert_response :unprocessable_content
  end

  test "automatic pipeline snapshots a glossary revision despite later revision and archive" do
    glossary = Glossaries::Create.call(user: users(:normal), attributes: glossary_params)
    profile = create_workflow_profile

    assert_difference -> { PipelineRun.count }, 1 do
      post translation_workspace_path, params: {
        translation_workspace: workspace_params.merge(
          workflow_mode: "automatic",
          model_ids: [],
          workflow_profile_revision_id: profile.current_revision_id.to_s,
          automatic_confirmation: "1",
          glossary_revision_id: glossary.current_revision_id.to_s
        )
      }
    end
    pipeline = PipelineRun.order(:id).last
    selected_revision = glossary.current_revision
    assert_equal selected_revision, pipeline.experiment.glossary_revision

    Glossaries::Revise.call(glossary:, expected_version: "1", attributes: glossary_params.merge(name: "New terminology"))
    Glossaries::ChangeStatus.deactivate(glossary: glossary)

    assert_equal selected_revision, pipeline.experiment.reload.glossary_revision
    payload = JSON.parse(TranslationSegments::Prompt.build(
      experiment: pipeline.experiment,
      source_text: pipeline.experiment.document.source_text
    ).fetch(:user_prompt))
    assert_equal [ "Sabbath" ], payload.fetch("terminology_requirements").map { |entry| entry.fetch("source_term") }
  end

  private

  def glossary_params
    {
      name: "Bible terminology",
      description: "Required term choices",
      source_language: "Vietnamese",
      target_language: "Japanese",
      entries: [ { source_term: "Sabbath", preferred_target_term: "安息日", note: "Use the standard term" } ]
    }
  end

  def workspace_params
    {
      project_name: "Glossary project", source_language: "Vietnamese", target_language: "Japanese",
      document_title: "Source", source_text: "Sabbath source text", experiment_name: "Glossary experiment",
      instruction_prompt: "Translate faithfully.", workflow_mode: "manual",
      model_ids: [ llm_models(:openrouter_claude).id.to_s ], submission_token: issue_translation_workspace_token
    }
  end
end
