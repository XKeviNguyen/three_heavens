require "test_helper"

class ManagedAiAccessTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "unapproved user cannot launch manual or automatic work or enqueue provider jobs" do
    user = users(:normal)
    user.update!(managed_ai_access: false)
    sign_in_as user

    get new_translation_workspace_path
    assert_response :success
    assert_select "[role='status']", text: /AI translation access/

    %w[manual automatic].each do |mode|
      assert_no_difference "AiProviderAttempt.count" do
        assert_no_difference "Experiment.count" do
          assert_no_enqueued_jobs do
            post translation_workspace_path, params: {
              translation_workspace: {
                project_name: "Denied project",
                source_language: "Vietnamese",
                target_language: "Japanese",
                document_title: "Denied document",
                source_text: "Source text",
                instruction_prompt: "Translate faithfully.",
                workflow_mode: mode,
                model_ids: [ llm_models(:openrouter_claude).id ],
                submission_token: issue_translation_workspace_token(user: user)
              }
            }
          end
        end
      end
      assert_redirected_to new_translation_workspace_path
    end
  end

  test "forged paid-work routes are denied before scheduling any run" do
    user = users(:normal)
    user.update!(managed_ai_access: false)
    sign_in_as user
    experiment = experiments(:one)
    paid_paths = [
      retry_failed_experiment_path(experiment),
      experiment_review_rounds_path(experiment),
      retry_failed_review_round_path(1),
      review_round_judge_rounds_path(1),
      retry_failed_judge_round_path(1),
      refine_final_translation_path(1),
      retry_failed_final_translation_finalization_round_path(1, 1)
    ]

    paid_paths.each do |path|
      assert_no_difference "AiProviderAttempt.count" do
        assert_no_difference [ "TranslationRun.count", "ReviewRun.count", "JudgeRun.count", "FinalizationRun.count" ] do
          assert_no_enqueued_jobs do
            post path, params: { reviewer_ids: [ 1 ], judge_ids: [ 1 ], finalizer_ids: [ 1 ] }
          end
        end
      end
      assert_redirected_to new_translation_workspace_path
    end
  end

  test "revoked access blocks an already scheduled provider attempt before claim" do
    user = users(:normal)
    run = translation_runs(:one)
    run.update!(scheduled_job_id: "scheduled-test-job", pending_since: Time.current)
    user.update!(managed_ai_access: false)
    assert_no_difference "AiProviderAttempt.count" do
      result = Ai::ExecutionClaim.call(run, active_job_id: "scheduled-test-job", active_job_execution: 1)
      assert_equal :terminal, result.state
    end
    assert run.reload.failed?
    assert_equal "managed_ai_access_revoked", run.error_code
  end
end
