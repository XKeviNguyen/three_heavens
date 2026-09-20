require "test_helper"
require_relative "../support/document_io_test_helper"
require_relative "../support/workflow_profile_test_helper"

class TranslationWorkspaceSubmissionTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include DocumentIoTestHelper
  include WorkflowProfileTestHelper

  setup do
    sign_in_as users(:normal)
    @model = llm_models(:openrouter_claude)
  end

  test "new workspace issues an opaque owner-scoped submission identity" do
    assert_difference -> { users(:normal).translation_workspace_submissions.available.count }, 1 do
      get new_translation_workspace_path
    end

    assert_response :success
    assert_select "input[type='hidden'][name='translation_workspace[submission_token]']" do |inputs|
      token = inputs.sole["value"]
      assert TranslationWorkspaceSubmission.valid_public_token?(token)
      assert_not TranslationWorkspaceSubmission.column_names.include?("public_token")
    end
  end

  test "manual duplicate post and successful replay return one experiment and one paid schedule" do
    token = issue_translation_workspace_token
    attributes = manual_attributes(submission_token: token)

    assert_difference -> { Experiment.count }, 1 do
      assert_enqueued_jobs 1, only: TranslationRunJob do
        post translation_workspace_path, params: { translation_workspace: attributes }
      end
    end
    experiment = Experiment.order(:id).last
    assert_redirected_to experiment_path(experiment)

    counts = workspace_counts
    assert_no_enqueued_jobs only: TranslationRunJob do
      post translation_workspace_path, params: {
        translation_workspace: attributes.merge(project_name: "Ignored replay mutation")
      }
    end
    assert_redirected_to experiment_path(experiment)
    assert_equal counts, workspace_counts
    assert_equal "Manual idempotency", experiment.document.project.name
    assert TranslationWorkspaceSubmission.find_owned_by_token!(user: users(:normal), token: token).consumed?
  end

  test "automatic duplicate post replays exactly one pipeline and one authorized translation batch" do
    profile = create_workflow_profile
    token = issue_translation_workspace_token
    attributes = automatic_attributes(profile: profile, submission_token: token)

    assert_enqueued_jobs 2, only: TranslationRunJob do
      post translation_workspace_path, params: { translation_workspace: attributes }
    end
    pipeline = PipelineRun.order(:id).last
    assert_redirected_to pipeline_run_path(pipeline)

    counts = workspace_counts
    assert_no_enqueued_jobs only: TranslationRunJob do
      post translation_workspace_path, params: { translation_workspace: attributes }
    end
    assert_redirected_to pipeline_run_path(pipeline)
    assert_equal counts, workspace_counts
    assert_equal 1, TranslationWorkspaceSubmission.where(experiment: pipeline.experiment, status: :consumed).count
  end

  test "long automatic launch requires a second confirmation of the exact request multiplier" do
    profile = create_workflow_profile
    profile.current_revision.model_selections.each do |selection|
      selection.llm_model.update!(context_window_tokens: 64_000, max_output_tokens: 4_096)
    end
    token = issue_translation_workspace_token
    source = "Long paragraph。\n\n" * 500
    attributes = automatic_attributes(profile: profile, submission_token: token).merge(source_text: source)

    assert_no_difference [ -> { Experiment.count }, -> { PipelineRun.count }, -> { DocumentExecutionPlan.count } ] do
      assert_no_enqueued_jobs only: TranslationSegmentRunJob do
        post translation_workspace_path, params: { translation_workspace: attributes }
      end
    end
    assert_response :unprocessable_content
    assert_select "h3", text: "Paid-work authorization"
    segment_count = LongDocuments::Segmenter.call(source).size
    request_slots = profile.current_revision.model_selections.count * segment_count
    assert_select "p", text: /#{segment_count} source segment\(s\) require #{request_slots} initial provider request slots and authorize at most #{request_slots * Ai::ProviderRetryPolicy::MAX_ATTEMPTS_PER_AUTHORIZATION} requests/
    digest = css_select("input[name='translation_workspace[automatic_plan_digest]']").sole["value"]
    assert_match(/\A\h{64}\z/, digest)
    assert_select "input[name='translation_workspace[automatic_confirmation]'][type='checkbox']:not([checked])"

    assert_enqueued_jobs 2 * segment_count, only: TranslationSegmentRunJob do
      post translation_workspace_path, params: {
        translation_workspace: attributes.merge(
          automatic_confirmation: "1",
          automatic_plan_digest: digest
        )
      }
    end
    pipeline = PipelineRun.order(:id).last
    assert_redirected_to pipeline_run_path(pipeline)
    assert_equal request_slots, pipeline.authorized_initial_provider_run_count
  end

  test "validation failure preserves the identity and a corrected retry consumes it" do
    token = issue_translation_workspace_token
    attributes = manual_attributes(submission_token: token, project_name: "")

    assert_no_difference -> { Experiment.count } do
      post translation_workspace_path, params: { translation_workspace: attributes }
    end
    assert_response :unprocessable_content
    assert_select "input[name='translation_workspace[submission_token]'][value='#{token}']"
    submission = TranslationWorkspaceSubmission.find_owned_by_token!(user: users(:normal), token: token)
    assert submission.available?

    assert_enqueued_jobs 1, only: TranslationRunJob do
      post translation_workspace_path, params: {
        translation_workspace: attributes.merge(project_name: "Corrected retry")
      }
    end
    assert_response :redirect
    assert submission.reload.consumed?
  end

  test "foreign expired and malformed identities fail closed without workspace or jobs" do
    foreign_token = issue_translation_workspace_token(user: users(:other))
    assert_no_workspace_or_jobs do
      post translation_workspace_path, params: {
        translation_workspace: manual_attributes(submission_token: foreign_token)
      }
    end
    assert_response :not_found

    expired_token = nil
    travel_to 2.days.ago do
      expired_token = issue_translation_workspace_token
    end
    assert_no_workspace_or_jobs do
      post translation_workspace_path, params: {
        translation_workspace: manual_attributes(submission_token: expired_token)
      }
    end
    assert_response :unprocessable_content
    assert_select "li", text: /Submission token.*expired/i

    malformed_values = [ nil, "short", "x" * 101, [ issue_translation_workspace_token ], { nested: "token" } ]
    malformed_values.each do |value|
      assert_no_workspace_or_jobs do
        post translation_workspace_path, params: {
          translation_workspace: manual_attributes(submission_token: value)
        }
      end
      assert_response :bad_request
    end

    %i[user_id consumed experiment_id pipeline_run_id].each do |key|
      assert_no_workspace_or_jobs do
        post translation_workspace_path, params: {
          translation_workspace: manual_attributes(
            submission_token: issue_translation_workspace_token
          ).merge(key => "1")
        }
      end
      assert_response :bad_request
    end
  end

  test "source import replay redirects after consumption without creating or scheduling twice" do
    source_import = create_ready_import(user: users(:normal))
    token = issue_translation_workspace_token
    attributes = manual_attributes(
      submission_token: token,
      source_import_id: source_import.id,
      source_import_project_token: source_import_binding(source_import),
      source_text: "Reviewed import"
    )

    assert_enqueued_jobs 1, only: TranslationRunJob do
      post translation_workspace_path, params: { translation_workspace: attributes }
    end
    experiment = Experiment.order(:id).last
    assert source_import.reload.consumed?

    counts = workspace_counts
    assert_no_enqueued_jobs only: TranslationRunJob do
      post translation_workspace_path, params: { translation_workspace: attributes }
    end
    assert_redirected_to experiment_path(experiment)
    assert_equal counts, workspace_counts
    assert_equal experiment.document, source_import.resulting_document
  end

  private

  def manual_attributes(submission_token:, **overrides)
    {
      project_name: "Manual idempotency",
      source_language: "Vietnamese",
      target_language: "Japanese",
      document_title: "One submission",
      source_text: "Source",
      experiment_name: "One launch",
      instruction_prompt: "Translate faithfully.",
      workflow_mode: "manual",
      model_ids: [ @model.id.to_s ],
      submission_token: submission_token
    }.merge(overrides)
  end

  def automatic_attributes(profile:, submission_token:)
    manual_attributes(submission_token: submission_token).merge(
      workflow_mode: "automatic",
      model_ids: [],
      workflow_profile_revision_id: profile.current_revision_id.to_s,
      automatic_confirmation: "1"
    )
  end

  def workspace_counts
    [ Project.count, Document.count, Experiment.count, PipelineRun.count, TranslationRun.count ]
  end

  def assert_no_workspace_or_jobs
    before = workspace_counts
    assert_no_enqueued_jobs only: TranslationRunJob do
      yield
    end
    assert_equal before, workspace_counts
  end
end
