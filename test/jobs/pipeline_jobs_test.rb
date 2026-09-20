require "test_helper"
require_relative "../support/workflow_profile_test_helper"

class PipelineJobsTest < ActiveJob::TestCase
  include ActiveJob::TestHelper
  include WorkflowProfileTestHelper

  test "duplicate advance job delivery is harmless" do
    experiment = completed_experiment
    pipeline = create_pipeline_run(experiment: experiment)

    assert_enqueued_jobs 1, only: ReviewRunJob do
      PipelineAdvanceJob.perform_now(pipeline.id)
    end
    clear_enqueued_jobs
    assert_no_difference [ -> { ReviewRound.count }, -> { ReviewRun.count }, -> { PipelineEvent.count } ] do
      PipelineAdvanceJob.perform_now(pipeline.id)
    end
    assert_equal 1, experiment.reload.review_round.review_runs.count
  end

  test "bounded reconciliation advances running pipelines and ignores manual and stopped workflows" do
    running_experiment = completed_experiment
    running = create_pipeline_run(experiment: running_experiment)
    stopped_experiment = completed_experiment
    stopped = create_pipeline_run(experiment: stopped_experiment)
    Pipelines::Stop.call(pipeline_run: stopped)
    ready_experiment = completed_experiment
    ready = create_pipeline_run(experiment: ready_experiment)
    ready.update!(status: :ready_for_editor, current_stage: :editor, ready_for_editor_at: Time.current)
    manual = completed_experiment

    result = Pipelines::Reconcile.call(batch_size: 100)
    clear_enqueued_jobs

    assert_operator result.examined_count, :>=, 1
    assert_equal "review", running.reload.current_stage
    assert_nil stopped_experiment.reload.review_round
    assert_nil stopped.reload.last_reconciled_at
    assert_nil ready_experiment.reload.review_round
    assert_nil ready.reload.last_reconciled_at
    assert_nil manual.reload.review_round
  end

  test "stale watchdog only fails current provider work and pipeline advancement blocks without starting review" do
    project = users(:normal).projects.create!(name: "Stale pipeline", source_language: "Vietnamese", target_language: "Japanese")
    experiment = project.documents.create!(title: "Source", source_text: "Source").experiments.create!(instruction_prompt: "Translate.")
    profile = create_workflow_profile
    pipeline = Pipelines::Start.call(
      experiment: experiment,
      user: users(:normal),
      workflow_profile_revision: profile.current_revision,
      confirmation: "1"
    )
    clear_enqueued_jobs
    experiment.translation_runs.update_all(pending_since: 3.hours.ago)

    assert_no_enqueued_jobs only: ReviewRunJob do
      Ai::StaleExecutionReconciler.call(now: Time.current, batch_size: 10)
      perform_enqueued_jobs only: PipelineAdvanceJob
    end

    assert experiment.reload.failed?
    assert pipeline.reload.blocked?
    assert_equal "translation", pipeline.blocked_stage
    assert_nil experiment.review_round
  end

  test "recurring job accepts only a bounded batch argument" do
    result = PipelineReconciliationJob.perform_now(1)
    assert_kind_of Pipelines::Reconcile::Result, result
    assert_operator result.examined_count, :<=, 1
    assert_raises(ArgumentError) { Pipelines::Reconcile.call(batch_size: 0) }
  end

  test "least recently reconciled cursor prevents blocked rows from starving later recoverable work" do
    blocked = 3.times.map do
      experiment = completed_experiment
      mutate_historical_fixture do
        experiment.translation_runs.first.update!(status: :failed, translated_text: nil, completed_at: Time.current)
      end
      experiment.update!(status: :failed)
      create_pipeline_run(experiment: experiment).tap do |pipeline|
        Pipelines::Advance.call(pipeline_run: pipeline)
      end
    end
    recoverable_experiment = completed_experiment
    recoverable = create_pipeline_run(experiment: recoverable_experiment)
    clear_enqueued_jobs

    first = Pipelines::Reconcile.call(batch_size: 3, clock: -> { 2.minutes.ago })
    assert_equal 3, first.examined_count
    assert_nil recoverable.reload.last_reconciled_at
    assert blocked.all? { |pipeline| pipeline.reload.last_reconciled_at.present? }
    assert blocked.all?(&:blocked?)

    second = Pipelines::Reconcile.call(batch_size: 3, clock: -> { 1.minute.ago })
    clear_enqueued_jobs
    assert_operator second.examined_count, :>=, 1
    assert recoverable.reload.last_reconciled_at
    assert recoverable.current_stage_review?
    assert_equal 1, ReviewRound.where(experiment: recoverable_experiment).count
  end

  private

  def completed_experiment
    project = users(:normal).projects.create!(name: "Recurring pipeline", source_language: "Vietnamese", target_language: "Japanese")
    experiment = project.documents.create!(title: "Source", source_text: "Source").experiments.create!(
      instruction_prompt: "Translate.", status: :completed
    )
    [ llm_models(:openrouter_claude), llm_models(:openrouter_gpt) ].each_with_index do |model, index|
      experiment.translation_runs.create!(llm_model: model, status: :completed, translated_text: "Translation #{index}")
    end
    experiment
  end
end
