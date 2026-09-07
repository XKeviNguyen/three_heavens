require "test_helper"
require_relative "../support/translation_reference_test_helper"
require_relative "../support/workflow_profile_test_helper"

class TranslationWorkspaceReferencesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include TranslationReferenceTestHelper
  include WorkflowProfileTestHelper

  setup do
    sign_in_as users(:normal)
    @model = llm_models(:openrouter_claude)
  end

  test "zero references is valid and one reference snapshots its exact current revision" do
    assert_difference -> { Experiment.count }, 1 do
      post translation_workspace_path, params: { translation_workspace: workspace_params }
    end
    assert_empty Experiment.order(:id).last.translation_reference_revisions

    reference = create_translation_reference
    selected = reference.current_revision
    assert_difference -> { ExperimentReferenceRevision.count }, 1 do
      post translation_workspace_path, params: {
        translation_workspace: workspace_params.merge(
          submission_token: issue_translation_workspace_token,
          translation_reference_revision_ids: [ selected.id.to_s ]
        )
      }
    end
    experiment = Experiment.order(:id).last
    assert_equal [ selected ], experiment.translation_reference_revisions
    assert_equal [ 1 ], experiment.experiment_reference_revisions.pluck(:position)

    TranslationReferences::Revise.call(
      translation_reference: reference,
      expected_version: "1",
      attributes: translation_reference_attributes(approved_translation: "New current translation")
    )
    TranslationReferences::ChangeStatus.deactivate(translation_reference: reference)
    assert_equal selected, experiment.reload.translation_reference_revisions.sole
    assert_equal "承認された翻訳。\n\n  字下げを保持します。", selected.approved_translation
  end

  test "five references launch in deterministic order and more than five is rejected" do
    references = 6.times.map do |index|
      create_translation_reference(title: "Reference #{index}")
    end
    selected_ids = references.first(5).map { |reference| reference.current_revision_id.to_s }.reverse

    post translation_workspace_path, params: {
      translation_workspace: workspace_params.merge(
        translation_reference_revision_ids: selected_ids
      )
    }
    assert_response :redirect
    snapshots = Experiment.order(:id).last.experiment_reference_revisions
    assert_equal references.first(5).map(&:current_revision_id).sort,
                 snapshots.map(&:translation_reference_revision_id)
    assert_equal (1..5).to_a, snapshots.map(&:position)

    assert_no_difference -> { Experiment.count } do
      post translation_workspace_path, params: {
        translation_workspace: workspace_params.merge(
          submission_token: issue_translation_workspace_token,
          translation_reference_revision_ids: references.map { |reference| reference.current_revision_id.to_s }
        )
      }
    end
    assert_response :unprocessable_content
  end

  test "malformed foreign archived stale and language-mismatched references are rejected" do
    foreign = create_translation_reference(user: users(:other), title: "Foreign")
    archived = create_translation_reference(title: "Archived")
    TranslationReferences::ChangeStatus.deactivate(translation_reference: archived)
    stale = create_translation_reference(title: "Stale")
    stale_revision = stale.current_revision
    TranslationReferences::Revise.call(
      translation_reference: stale,
      expected_version: "1",
      attributes: translation_reference_attributes(title: "Stale now current", approved_translation: "Current")
    )
    mismatch = create_translation_reference(title: "Mismatch", target_language: "English")

    [
      "not-an-id",
      foreign.current_revision_id.to_s,
      archived.current_revision_id.to_s,
      stale_revision.id.to_s,
      mismatch.current_revision_id.to_s
    ].each do |value|
      assert_no_difference -> { Experiment.count } do
        post translation_workspace_path, params: {
          translation_workspace: workspace_params.merge(
            submission_token: issue_translation_workspace_token,
            translation_reference_revision_ids: [ value ]
          )
        }
      end
      assert_response :unprocessable_content
    end

    assert_no_difference -> { Experiment.count } do
      post translation_workspace_path, params: {
        translation_workspace: workspace_params.merge(
          submission_token: issue_translation_workspace_token,
          translation_reference_revision_ids: "1"
        )
      }
    end
    assert_response :bad_request
  end

  test "manual and automatic launches persist reference and guidance snapshots independently" do
    reference = create_translation_reference
    workflow = create_workflow_profile

    post translation_workspace_path, params: {
      translation_workspace: workspace_params.merge(
        translation_reference_revision_ids: [ reference.current_revision_id.to_s ],
        guidance_preference: "glossary"
      )
    }
    manual = Experiment.order(:id).last
    assert_equal "glossary", manual.guidance_preference
    assert_equal reference.current_revision, manual.translation_reference_revisions.sole

    post translation_workspace_path, params: {
      translation_workspace: workspace_params.merge(
        submission_token: issue_translation_workspace_token,
        workflow_mode: "automatic",
        model_ids: [],
        workflow_profile_revision_id: workflow.current_revision_id.to_s,
        translation_reference_revision_ids: [ reference.current_revision_id.to_s ],
        guidance_preference: "experiment_instruction",
        automatic_confirmation: "1"
      )
    }
    automatic = PipelineRun.order(:id).last.experiment
    assert_equal "experiment_instruction", automatic.guidance_preference
    assert_equal reference.current_revision, automatic.translation_reference_revisions.sole
  end

  test "all exact preferences are accepted unknown values rejected and form defaults to references" do
    get new_translation_workspace_path
    assert_response :success
    assert_select "input[name='translation_workspace[guidance_preference]'][value='reference_examples'][checked]"

    Experiment.guidance_preferences.each_key do |preference|
      post translation_workspace_path, params: {
        translation_workspace: workspace_params.merge(
          submission_token: issue_translation_workspace_token,
          guidance_preference: preference
        )
      }
      assert_response :redirect
      assert_equal preference, Experiment.order(:id).last.guidance_preference
    end

    assert_no_difference -> { Experiment.count } do
      post translation_workspace_path, params: {
        translation_workspace: workspace_params.merge(
          submission_token: issue_translation_workspace_token,
          guidance_preference: "unknown"
        )
      }
    end
    assert_response :unprocessable_content
  end

  test "submission replay creates no duplicate snapshot experiment jobs or pipeline" do
    reference = create_translation_reference
    token = issue_translation_workspace_token
    params = workspace_params.merge(
      submission_token: token,
      translation_reference_revision_ids: [ reference.current_revision_id.to_s ]
    )

    post translation_workspace_path, params: { translation_workspace: params }
    assert_response :redirect
    counts = [ Experiment.count, ExperimentReferenceRevision.count, TranslationRun.count, PipelineRun.count ]
    jobs = enqueued_jobs.size

    post translation_workspace_path, params: { translation_workspace: params }
    assert_response :redirect
    assert_equal counts, [ Experiment.count, ExperimentReferenceRevision.count, TranslationRun.count, PipelineRun.count ]
    assert_equal jobs, enqueued_jobs.size
  end

  private

  def workspace_params
    {
      project_name: "Reference workspace",
      source_language: "Vietnamese",
      target_language: "Japanese",
      document_title: "Source",
      source_text: "Source theological text",
      experiment_name: "Reference experiment",
      instruction_prompt: "Translate faithfully.",
      workflow_mode: "manual",
      model_ids: [ @model.id.to_s ],
      submission_token: issue_translation_workspace_token,
      guidance_preference: "reference_examples"
    }
  end
end
