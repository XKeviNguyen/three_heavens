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
    manual = completed_experiment

    result = Pipelines::Reconcile.call(batch_size: 100)
    clear_enqueued_jobs

    assert_operator result.examined_count, :>=, 1
    assert_equal "review", running.reload.current_stage
    assert_nil stopped_experiment.reload.review_round
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
