require "test_helper"
require_relative "../support/final_translation_test_helper"

class WorkflowRecoveryAuthorizationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper

  setup do
    @current_test_user = users(:other)
    @foreign_final_translation = create_final_translation_workspace
    @current_test_user = users(:normal)
    @own_experiment = create_failed_experiment(@current_test_user)
    clear_enqueued_jobs
    sign_in_as @current_test_user
  end

  test "owner sees a cost warning and retries only the existing failed translation run" do
    failed = @own_experiment.translation_runs.failed.first

    get experiment_path(@own_experiment)
    assert_response :success
    assert_select "form[action='#{retry_failed_experiment_path(@own_experiment)}']"
    assert_select "p", text: /incur additional cost/

    assert_no_difference -> { TranslationRun.count } do
      assert_enqueued_with(job: TranslationRunJob, args: [ failed.id ]) do
        post retry_failed_experiment_path(@own_experiment)
      end
    end

    assert_redirected_to @own_experiment
    assert failed.reload.pending?
    assert @own_experiment.reload.running?
  end

  test "foreign retry routes use safe not found behavior and enqueue nothing" do
    experiment = @foreign_final_translation.experiment
    review_round = experiment.review_round
    judge_round = review_round.judge_round
    finalization_round = @foreign_final_translation.finalization_rounds.create!(
      base_version: @foreign_final_translation.current_version,
      selection_key: "a" * 64,
      status: :running
    )

    [
      retry_failed_experiment_path(experiment),
      retry_failed_review_round_path(review_round),
      retry_failed_judge_round_path(judge_round),
      retry_failed_final_translation_finalization_round_path(
        @foreign_final_translation,
        finalization_round
      )
    ].each do |path|
      post path
      assert_response :not_found
    end
    assert_no_enqueued_jobs
  end

  test "retry endpoint accepts no run or replacement model selection" do
    failed = @own_experiment.translation_runs.failed.first
    replacement = llm_models(:openrouter_gpt)

    post retry_failed_experiment_path(@own_experiment), params: {
      translation_run_id: translation_runs(:two).id,
      model_id: replacement.id
    }

    assert_redirected_to @own_experiment
    assert_equal failed.llm_model_id, failed.reload.llm_model_id
    assert_equal 1, @own_experiment.translation_runs.count
  end

  private

  def create_failed_experiment(user)
    project = Project.create!(
      user: user,
      name: "Recovery authorization",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Source", source_text: "Source text")
    experiment = document.experiments.create!(instruction_prompt: "Translate.", status: :running)
    experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      status: :failed,
      error_code: "provider_failure",
      completed_at: Time.current
    )
    TranslationExperiments::ReconcileExperiment.call(experiment)
    experiment
  end
end
