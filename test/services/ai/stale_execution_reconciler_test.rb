require "test_helper"
require_relative "../../support/authorized_ai_job_helper"

class Ai::StaleExecutionReconcilerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include AuthorizedAiJobHelper

  setup do
    project = Project.create!(
      user: users(:normal),
      name: "Stale work",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Source", source_text: "Sensitive source")
    @experiment = document.experiments.create!(instruction_prompt: "Translate.", status: :running)
    clear_enqueued_jobs
  end

  test "marks only stale running work failed and reconciles idempotently without enqueueing" do
    now = Time.zone.parse("2026-08-27 12:00:00")
    stale = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      status: :running,
      execution_attempt: 1,
      started_at: now - 4.hours,
      last_claimed_at: now - 3.hours
    )
    fresh = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_gpt),
      status: :running,
      execution_attempt: 1,
      started_at: now - 4.hours,
      last_claimed_at: now - 30.minutes
    )

    assert_no_enqueued_jobs do
      result = Ai::StaleExecutionReconciler.call(now: now)
      assert_equal 1, result.total
    end

    assert stale.reload.failed?
    assert_equal "stale_execution", stale.error_code
    assert_equal Ai::StaleExecutionReconciler::ERROR_MESSAGE, stale.error_message
    assert fresh.reload.running?
    assert @experiment.reload.running?

    fresh.update!(last_claimed_at: now - 3.hours)
    assert_equal 1, Ai::StaleExecutionReconciler.call(now: now).total
    assert @experiment.reload.failed?
    assert_equal 0, Ai::StaleExecutionReconciler.call(now: now).total
    assert_no_enqueued_jobs
  end

  test "rechecks freshness while holding the run lock" do
    now = Time.zone.parse("2026-08-27 12:00:00")
    run = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      status: :running,
      execution_attempt: 2,
      started_at: now - 4.hours,
      last_claimed_at: now - 10.minutes
    )

    changed = Ai::StaleExecutionReconciler.send(
      :fail_running_if_still_stale,
      run,
      now - 2.hours,
      now
    )

    assert_not changed
    assert run.reload.running?
  end

  test "terminal records are never stale and late attempts cannot overwrite recovered state" do
    now = Time.zone.parse("2026-08-27 12:00:00")
    run = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      status: :failed,
      execution_attempt: 3,
      started_at: now - 4.hours,
      last_claimed_at: now - 3.hours,
      completed_at: now - 2.hours,
      error_code: "stale_execution"
    )
    error = Ai::OpenRouterClient::PermanentError.new("late", code: "late_result")

    assert_equal 0, Ai::StaleExecutionReconciler.call(now: now).total
    assert_not Ai::RunResult.persist_failure(run, error: error, attempt: 3)
    assert_equal "stale_execution", run.reload.error_code
  end

  test "each built in job retry refreshes claim timing and advances the execution attempt" do
    run = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      scheduled_job_id: "same-active-job",
      pending_since: Time.current
    )
    first_claim = Ai::ExecutionClaim.call(
      run,
      active_job_id: "same-active-job",
      active_job_execution: 1
    )
    run.reload
    first_claimed_at = run.last_claimed_at
    first_started_at = run.started_at

    travel 1.minute do
      retry_claim = Ai::ExecutionClaim.call(
        run,
        active_job_id: "same-active-job",
        active_job_execution: 2
      )
      assert_equal :claimed, retry_claim.state
      assert_equal first_claim.attempt + 1, retry_claim.attempt
    end

    assert_operator run.reload.last_claimed_at, :>, first_claimed_at
    assert_equal 2, run.execution_attempt
    assert_equal first_started_at, run.started_at
  end

  test "stale pending work fails while fresh pending work remains recoverable" do
    now = Time.zone.parse("2026-08-27 12:00:00")
    stale = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      scheduled_job_id: "stale-pending-job",
      pending_since: now - 3.hours
    )
    fresh = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_gpt),
      scheduled_job_id: "fresh-pending-job",
      pending_since: now - 30.minutes
    )

    assert_no_enqueued_jobs do
      result = Ai::StaleExecutionReconciler.call(now: now)
      assert_equal 1, result.total
      assert_equal 1, result.pending_failed_counts.fetch("TranslationRun")
      assert_equal 0, result.running_failed_counts.fetch("TranslationRun")
    end

    assert stale.reload.failed?
    assert_equal "stale_pending", stale.error_code
    assert_equal Ai::StaleExecutionReconciler::PENDING_ERROR_MESSAGE, stale.error_message
    assert fresh.reload.pending?
    assert @experiment.reload.running?
    assert_equal 0, Ai::StaleExecutionReconciler.call(now: now).total

    old_job_id = stale.scheduled_job_id
    clear_enqueued_jobs
    assert_equal 1, TranslationExperiments::RetryFailed.call(@experiment).retried_count
    assert stale.reload.pending?
    assert_not_equal old_job_id, stale.scheduled_job_id
  end

  test "late queued job after stale pending recovery is terminal and makes no provider request" do
    now = Time.zone.parse("2026-08-27 12:00:00")
    run = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      scheduled_job_id: "late-pending-job",
      pending_since: now - 3.hours
    )
    assert_equal 1, Ai::StaleExecutionReconciler.call(now: now).total

    calls = 0
    client = Object.new
    client.define_singleton_method(:chat_completion) do |**|
      calls += 1
      raise "Provider must not be called"
    end
    original = TranslationRunJob.client_factory
    TranslationRunJob.client_factory = -> { client }
    begin
      build_authorized_ai_job(
        TranslationRunJob,
        run,
        job_id: "late-pending-job",
        execution: 1
      ).perform_now
    ensure
      TranslationRunJob.client_factory = original
    end

    assert_equal 0, calls
    assert run.reload.failed?
    assert_equal "stale_pending", run.error_code
    assert_no_enqueued_jobs
  end
end
