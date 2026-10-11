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
    assert_select "form[action='#{retry_failed_experiment_path(@own_experiment)}'] input[name='billing_source'][value='managed']"
    assert_select "p", text: /may add cost/
    assert_select "[data-testid='retry-payer']", text: I18n.t("ai_billing.retry_payer.managed")

    assert_no_difference -> { TranslationRun.count } do
      assert_enqueued_with(job: TranslationRunJob, args: [ failed.id ]) do
        post retry_failed_experiment_path(@own_experiment), params: { billing_source: "managed" }
      end
    end

    assert_redirected_to @own_experiment
    assert failed.reload.pending?
    assert_equal "managed", failed.billing_source
    assert @own_experiment.reload.running?
  end

  # The retry runs inside the transaction that holds the owner's lock, so its
  # jobs are enqueued at that commit; the notice must report what happened then.
  test "a retry whose job cannot be enqueued says so" do
    failed = @own_experiment.translation_runs.failed.first
    real_new = TranslationRunJob.method(:new)
    TranslationRunJob.define_singleton_method(:new) do |*args|
      real_new.call(*args).tap { |job| job.define_singleton_method(:enqueue) { |*| false } }
    end

    post retry_failed_experiment_path(@own_experiment), params: { billing_source: "managed" }

    assert_redirected_to @own_experiment
    follow_redirect!
    assert_select "[role=status]", text: I18n.t("retry_feedback.translation.queue_failed")
    assert_equal "enqueue_failed", failed.reload.error_code
  ensure
    TranslationRunJob.singleton_class.remove_method(:new)
  end

  test "the retry shows the personal payer and stamps exactly that key" do
    @current_test_user.update!(managed_ai_access: false)
    credential = @current_test_user.open_router_credentials.create!(api_key: "sk-or-v1-#{"5d" * 32}")
    @current_test_user.update!(ai_payment_source: "personal")
    failed = @own_experiment.translation_runs.failed.first

    get experiment_path(@own_experiment)
    assert_select "[data-testid='retry-payer']", text: I18n.t("ai_billing.retry_payer.personal", hint: "…#{"5d" * 2}")
    assert_select "input[name='billing_source'][value='personal']"
    assert_select "input[name='billing_key'][value='#{credential.id}']"

    post retry_failed_experiment_path(@own_experiment), params: { billing_source: "personal", billing_key: credential.id }

    assert_redirected_to @own_experiment
    assert_equal [ "personal", credential.id ], [ failed.reload.billing_source, failed.open_router_credential_id ]
  end

  # The page said the platform (or a key that was since replaced) would pay;
  # another tab changed it before the click. The retry must not charge a payer
  # the user did not see, and a page without the payer (rendered before this
  # check) is refused the same way.
  test "a retry whose shown payer is no longer current is refused without queueing" do
    replaced = @current_test_user.open_router_credentials.create!(api_key: "sk-or-v1-#{"6e" * 32}")
    replaced.revoke!(reason: "replaced")
    @current_test_user.open_router_credentials.create!(api_key: "sk-or-v1-#{"7f" * 32}")
    @current_test_user.update!(ai_payment_source: "personal")
    failed = @own_experiment.translation_runs.failed.first

    [ { billing_source: "managed" }, { billing_source: "personal", billing_key: replaced.id }, {} ].each do |params|
      assert_no_enqueued_jobs do
        post retry_failed_experiment_path(@own_experiment), params: params
      end
      assert_redirected_to @own_experiment
      follow_redirect!
      assert_select "[role='alert']", text: I18n.t("ai_billing.retry_payer_changed")
      assert failed.reload.failed?
    end
  end

  test "every retry route refuses a payer that is no longer current before queueing" do
    final_translation = create_final_translation_workspace
    judge_round = final_translation.experiment.review_round.judge_round
    round = final_translation.finalization_rounds.create!(base_version: final_translation.current_version, selection_key: "b" * 64, status: :running)
    clear_enqueued_jobs

    {
      retry_failed_review_round_path(judge_round.review_round) => review_round_path(judge_round.review_round),
      retry_failed_judge_round_path(judge_round) => judge_round_path(judge_round),
      retry_failed_final_translation_finalization_round_path(final_translation, round) => final_translation_path(final_translation)
    }.each do |path, page|
      assert_no_enqueued_jobs do
        post path, params: { billing_source: "personal" }
      end
      assert_redirected_to page
      follow_redirect!
      assert_select "[role='alert']", text: I18n.t("ai_billing.retry_payer_changed")
    end
  end

  test "a user who cannot start AI work sees why instead of a retry button" do
    @current_test_user.update!(managed_ai_access: false)

    get experiment_path(@own_experiment)

    assert_select "form[action='#{retry_failed_experiment_path(@own_experiment)}']", count: 0
    assert_select "[data-testid='retry-payer']", text: /#{Regexp.escape(I18n.t("ai_billing.denied.managed_ai_access_revoked"))}/
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
      billing_source: "managed",
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
