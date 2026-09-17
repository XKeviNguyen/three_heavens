require "test_helper"
require_relative "../../support/final_translation_test_helper"
require_relative "../../support/authorized_ai_job_helper"

class Ai::RunSchedulerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper
  include AuthorizedAiJobHelper

  setup do
    @current_test_user = users(:normal)
    clear_enqueued_jobs
  end

  test "shared scheduler turns enqueue failures into generic reconciled failures for every workflow" do
    runs = workflow_runs
    clear_enqueued_jobs

    runs.each do |run|
      schedule = run.class.transaction do
        Ai::RunScheduler.prepare(run: run, job_class: failing_job_class)
      end

      assert_not Ai::RunScheduler.enqueue(schedule)
      assert run.reload.failed?, "expected #{run.class.name} to fail"
      assert_equal "enqueue_failed", run.error_code
      assert_equal Ai::RunScheduler::ERROR_MESSAGE, run.error_message
      assert_not_includes run.error_message, "private queue detail"
      assert parent_for(run).reload.failed?, "expected parent for #{run.class.name} to reconcile"
    end

    assert_no_enqueued_jobs
  end

  test "one enqueue failure does not corrupt a successfully queued sibling" do
    experiment = create_experiment
    queued = experiment.translation_runs.create!(llm_model: llm_models(:openrouter_claude))
    failed = experiment.translation_runs.create!(llm_model: llm_models(:openrouter_gpt))
    schedules = TranslationRun.transaction do
      [
        Ai::RunScheduler.prepare(run: queued, job_class: TranslationRunJob),
        Ai::RunScheduler.prepare(run: failed, job_class: failing_job_class)
      ]
    end

    assert_enqueued_with(job: TranslationRunJob, args: [ queued.id ]) do
      Ai::RunScheduler.enqueue_all(schedules)
    end

    assert queued.reload.pending?
    assert queued.pending_since
    assert queued.scheduled_job_id.present?
    assert failed.reload.failed?
    assert_equal "enqueue_failed", failed.error_code
    assert experiment.reload.running?
  end

  test "built in retry enqueue failure fails and reconciles the current execution" do
    experiment = create_experiment(status: :pending)
    run = TranslationExperiments::Start.call(
      experiment: experiment,
      llm_models: [ llm_models(:openrouter_claude) ]
    ).first
    clear_enqueued_jobs
    job = build_authorized_ai_job(TranslationRunJob, run)
    job.define_singleton_method(:enqueue) { |_options = {}| false }
    client = Object.new
    client.define_singleton_method(:chat_completion) do |**|
      raise Ai::OpenRouterClient::RetryableError.new("Provider busy", code: "busy")
    end

    original = TranslationRunJob.client_factory
    TranslationRunJob.client_factory = -> { client }
    begin
      job.perform_now
    ensure
      TranslationRunJob.client_factory = original
    end

    assert run.reload.failed?
    assert_equal "enqueue_failed", run.error_code
    assert_equal Ai::RunScheduler::ERROR_MESSAGE, run.error_message
    assert experiment.reload.failed?
    assert_no_enqueued_jobs
  end

  test "unexpected initial enqueue exception is not converted into enqueue failed" do
    experiment = create_experiment
    run = experiment.translation_runs.create!(llm_model: llm_models(:openrouter_claude))
    schedule = TranslationRun.transaction do
      Ai::RunScheduler.prepare(run: run, job_class: unexpected_failure_job_class)
    end

    error = assert_raises ArgumentError do
      Ai::RunScheduler.enqueue(schedule)
    end

    assert_equal "simulated programming error", error.message
    assert run.reload.pending?
    assert_nil run.error_code
    assert experiment.reload.running?
  end

  test "unexpected built in retry enqueue exception is not converted into enqueue failed" do
    experiment = create_experiment(status: :pending)
    run = TranslationExperiments::Start.call(
      experiment: experiment,
      llm_models: [ llm_models(:openrouter_claude) ]
    ).first
    clear_enqueued_jobs
    job = build_authorized_ai_job(TranslationRunJob, run)
    job.define_singleton_method(:enqueue) do |_options = {}|
      raise ArgumentError, "simulated retry programming error"
    end
    client = Object.new
    client.define_singleton_method(:chat_completion) do |**|
      raise Ai::OpenRouterClient::RetryableError.new("Provider busy", code: "busy")
    end

    original = TranslationRunJob.client_factory
    TranslationRunJob.client_factory = -> { client }
    begin
      error = assert_raises ArgumentError do
        job.perform_now
      end
    ensure
      TranslationRunJob.client_factory = original
    end

    assert_equal "simulated retry programming error", error.message
    assert run.reload.running?
    assert_nil run.error_code
    assert experiment.reload.running?
    assert_no_enqueued_jobs
  end

  private

  def failing_job_class
    Class.new do
      attr_reader :job_id

      def initialize(*)
        @job_id = SecureRandom.uuid
      end

      def enqueue
        raise SolidQueue::Job::EnqueueError, "private queue detail"
      end
    end
  end

  def unexpected_failure_job_class
    Class.new do
      attr_reader :job_id

      def initialize(*)
        @job_id = SecureRandom.uuid
      end

      def enqueue
        raise ArgumentError, "simulated programming error"
      end
    end
  end

  def workflow_runs
    [ translation_run, review_run, judge_run, finalization_run ]
  end

  def translation_run
    create_experiment.translation_runs.create!(llm_model: llm_models(:openrouter_claude))
  end

  def review_run
    round = create_completed_review_round
    mutate_historical_fixture { round.update!(status: :running) }
    round.review_runs.create!(reviewer_llm_model: llm_models(:openrouter_gpt))
  end

  def judge_run
    review_round = create_completed_review_round
    round = review_round.create_judge_round!(status: :running)
    round.judge_runs.create!(judge_llm_model: create_judge_model)
  end

  def finalization_run
    final_translation = create_final_translation_workspace
    round = final_translation.finalization_rounds.create!(
      base_version: final_translation.current_version,
      selection_key: SecureRandom.hex(32),
      status: :running
    )
    round.finalization_runs.create!(finalizer_llm_model: create_finalizer)
  end

  def create_experiment(status: :running)
    project = Project.create!(
      user: @current_test_user,
      name: "Scheduler #{SecureRandom.hex(3)}",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Source", source_text: "Source text")
    document.experiments.create!(instruction_prompt: "Translate.", status: status)
  end

  def parent_for(run)
    case run
    when TranslationRun then run.experiment
    when ReviewRun then run.review_round
    when JudgeRun then run.judge_round
    when FinalizationRun then run.finalization_round
    end
  end
end
