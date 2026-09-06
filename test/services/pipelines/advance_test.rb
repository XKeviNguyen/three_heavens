require "test_helper"
require_relative "../../support/judging_test_helper"
require_relative "../../support/final_translation_test_helper"
require_relative "../../support/workflow_profile_test_helper"
require_relative "../../support/translation_reference_test_helper"

class Pipelines::AdvanceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include JudgingTestHelper
  include FinalTranslationTestHelper
  include WorkflowProfileTestHelper
  include TranslationReferenceTestHelper

  test "automatic pipeline keeps the original reference revision through every later stage" do
    experiment = create_completed_experiment
    reference = create_translation_reference(
      source_language: experiment.document.project.source_language,
      target_language: experiment.document.project.target_language,
      source_text: "AUTOMATIC_REFERENCE_SOURCE_V1",
      approved_translation: "AUTOMATIC_REFERENCE_APPROVED_V1"
    )
    selected = reference.current_revision
    snapshot_reference(experiment: experiment, revision: selected)
    profile = create_workflow_profile(completion_mode: "refinement_proposals")
    pipeline = create_pipeline_run(experiment: experiment, profile: profile)

    TranslationReferences::Revise.call(
      translation_reference: reference,
      expected_version: "1",
      attributes: translation_reference_attributes(
        source_language: experiment.document.project.source_language,
        target_language: experiment.document.project.target_language,
        source_text: "AUTOMATIC_REFERENCE_SOURCE_V2",
        approved_translation: "AUTOMATIC_REFERENCE_APPROVED_V2"
      )
    )
    TranslationReferences::ChangeStatus.deactivate(translation_reference: reference)

    assert_prompt_uses_reference(
      TranslationSegments::Prompt.build(experiment: experiment, source_text: experiment.document.source_text),
      selected
    )
    Pipelines::Advance.call(pipeline_run: pipeline)
    review_run = experiment.reload.review_round.review_runs.sole
    assert_prompt_uses_reference(BlindReviews::Prompt.build(review_run), selected)
    complete_review_run(review_run)
    BlindReviews::ReconcileRound.call(review_run.review_round)
    clear_enqueued_jobs

    Pipelines::Advance.call(pipeline_run: pipeline)
    judge_run = review_run.review_round.reload.judge_round.judge_runs.sole
    assert_prompt_uses_reference(Judging::Prompt.build(judge_run), selected)
    complete_judge_run(judge_run)
    Judging::ReconcileRound.call(judge_run.judge_round)
    clear_enqueued_jobs

    Pipelines::Advance.call(pipeline_run: pipeline)
    finalization_run = pipeline.reload.finalization_round.finalization_runs.sole
    assert_prompt_uses_reference(Finalizations::Prompt.build(finalization_run), selected)
    assert_equal selected, experiment.reload.translation_reference_revisions.sole
  end

  test "winner draft advances through existing services exactly once and stops for editor" do
    review_round = create_completed_review_round
    pipeline = create_pipeline_run(experiment: review_round.experiment)

    Pipelines::Advance.call(pipeline_run: pipeline)
    assert pipeline.reload.current_stage_review?
    assert_equal review_round, pipeline.experiment.review_round

    assert_difference -> { JudgeRound.count }, 1 do
      assert_enqueued_jobs 1, only: JudgeRunJob do
        Pipelines::Advance.call(pipeline_run: pipeline)
      end
    end
    judge_round = review_round.reload.judge_round
    clear_enqueued_jobs
    complete_judge_run(judge_round.judge_runs.sole)
    Judging::ReconcileRound.call(judge_round)
    clear_enqueued_jobs

    assert_difference -> { FinalTranslation.count }, 1 do
      Pipelines::Advance.call(pipeline_run: pipeline)
    end
    assert pipeline.reload.ready_for_editor?
    assert pipeline.current_stage_editor?
    assert pipeline.experiment.final_translation.draft?
    assert_equal 1, pipeline.experiment.final_translation.versions.count
    assert_nil pipeline.experiment.final_translation.finalized_at

    counts = [ ReviewRound.count, JudgeRound.count, FinalTranslation.count ]
    Pipelines::Advance.call(pipeline_run: pipeline)
    assert_equal counts, [ ReviewRound.count, JudgeRound.count, FinalTranslation.count ]
    assert_equal 1, pipeline.events.where(event_key: "ready_for_editor").count
  end

  test "refinement mode creates proposals once and never applies or finalizes them" do
    review_round = create_completed_review_round
    profile = create_workflow_profile(completion_mode: "refinement_proposals")
    pipeline = create_pipeline_run(experiment: review_round.experiment, profile: profile)
    Pipelines::Advance.call(pipeline_run: pipeline)
    Pipelines::Advance.call(pipeline_run: pipeline)
    judge_round = review_round.reload.judge_round
    clear_enqueued_jobs
    complete_judge_run(judge_round.judge_runs.sole)
    Judging::ReconcileRound.call(judge_round)
    clear_enqueued_jobs

    assert_enqueued_jobs 1, only: FinalizationRunJob do
      Pipelines::Advance.call(pipeline_run: pipeline)
    end
    assert pipeline.reload.current_stage_finalization?
    round = pipeline.finalization_round
    original = pipeline.experiment.final_translation.current_version.content
    clear_enqueued_jobs
    complete_finalization_run(round.finalization_runs.sole)
    clear_enqueued_jobs
    Pipelines::Advance.call(pipeline_run: pipeline)

    final_translation = pipeline.experiment.final_translation.reload
    assert pipeline.reload.ready_for_editor?
    assert_equal original, final_translation.current_version.content
    assert_equal 1, final_translation.versions.count
    assert final_translation.draft?
    assert round.finalization_runs.sole.proposed_translation.present?
  end

  test "terminal stage failure blocks and explicit retry state can resume" do
    experiment = create_failed_experiment
    pipeline = create_pipeline_run(experiment: experiment)

    Pipelines::Advance.call(pipeline_run: pipeline)
    assert pipeline.reload.blocked?
    assert_equal "stage_failed", pipeline.blocked_reason_code

    experiment.translation_runs.failed.update_all(status: "pending", completed_at: nil)
    experiment.update!(status: :running)
    Pipelines::Advance.call(pipeline_run: pipeline)
    assert pipeline.reload.running?
    assert pipeline.current_stage_translation?
    assert_equal 1, pipeline.events.where(event_type: "translation_blocked", reason_code: "stage_failed").count
  end

  test "reference context exhaustion blocks the automatic pipeline with a safe operational error code" do
    pipeline = create_pipeline_run(experiment: create_completed_experiment)
    original_start = BlindReviews::Start.method(:call)
    BlindReviews::Start.define_singleton_method(:call) do |**|
      raise BlindReviews::Start::ContextBudgetError, TranslationReferences::ContextBudgetMessage::MESSAGE
    end

    begin
      Pipelines::Advance.call(pipeline_run: pipeline)
    ensure
      BlindReviews::Start.define_singleton_method(:call, original_start)
    end

    assert pipeline.reload.blocked?
    assert_equal "reference_context_budget", pipeline.blocked_reason_code
    assert_equal TranslationReferences::ContextBudgetMessage::MESSAGE, pipeline.blocked_message
  end

  test "repeated block and resume episodes are distinct while unchanged reconciliation is deduplicated" do
    experiment = create_failed_experiment
    pipeline = create_pipeline_run(experiment: experiment)

    results = concurrently(2) { Pipelines::Advance.call(pipeline_run: PipelineRun.find(pipeline.id)) }
    assert_empty results.grep(Exception)
    Pipelines::Advance.call(pipeline_run: pipeline)
    assert_equal 1, pipeline.events.where(event_type: "translation_blocked").count

    failed_run = experiment.translation_runs.failed.sole
    failed_run.update!(status: :pending, completed_at: nil)
    experiment.update!(status: :running)
    Pipelines::Advance.call(pipeline_run: pipeline)

    failed_run.update!(status: :failed, completed_at: Time.current)
    experiment.update!(status: :failed)
    Pipelines::Advance.call(pipeline_run: pipeline)
    Pipelines::Advance.call(pipeline_run: pipeline)

    failed_run.update!(status: :pending, completed_at: nil)
    experiment.update!(status: :running)
    Pipelines::Advance.call(pipeline_run: pipeline)

    blocked = pipeline.events.where(event_type: "translation_blocked").order(:sequence_number)
    resumed = pipeline.events.where(event_type: "translation_retry_resumed").order(:sequence_number)
    assert_equal [ 1, 2 ], blocked.map { |event| event.metadata.fetch("episode") }
    assert_equal [ 1, 2 ], resumed.map { |event| event.metadata.fetch("episode") }
    assert_equal 2, blocked.pluck(:event_key).uniq.size
    assert_equal 2, resumed.pluck(:event_key).uniq.size
    assert_equal (1..pipeline.events.count).to_a, pipeline.events.pluck(:sequence_number)
  end

  test "review and judge terminal failures block then resume only after explicit recovery completes" do
    experiment = create_completed_experiment
    pipeline = create_pipeline_run(experiment: experiment)
    Pipelines::Advance.call(pipeline_run: pipeline)
    review_round = experiment.reload.review_round
    review_run = review_round.review_runs.sole
    review_run.update!(status: :failed, completed_at: Time.current)
    BlindReviews::ReconcileRound.call(review_round)
    clear_enqueued_jobs

    Pipelines::Advance.call(pipeline_run: pipeline)
    assert pipeline.reload.blocked?
    assert_equal "review", pipeline.blocked_stage
    assert_nil review_round.reload.judge_round

    complete_review_run(review_run)
    BlindReviews::ReconcileRound.call(review_round)
    clear_enqueued_jobs
    Pipelines::Advance.call(pipeline_run: pipeline)
    assert pipeline.reload.current_stage_judge?
    judge_round = review_round.reload.judge_round

    judge_run = judge_round.judge_runs.sole
    judge_run.update!(status: :failed, completed_at: Time.current)
    Judging::ReconcileRound.call(judge_round)
    clear_enqueued_jobs
    Pipelines::Advance.call(pipeline_run: pipeline)
    assert pipeline.reload.blocked?
    assert_equal "judge", pipeline.blocked_stage
    assert_nil experiment.reload.final_translation

    complete_judge_run(judge_run)
    Judging::ReconcileRound.call(judge_round)
    clear_enqueued_jobs
    assert_difference -> { FinalTranslation.count }, 1 do
      Pipelines::Advance.call(pipeline_run: pipeline)
    end
    assert pipeline.reload.ready_for_editor?
  end

  test "finalizer failure preserves completed proposals and resumes at the human checkpoint" do
    first = llm_models(:openrouter_claude)
    second = llm_models(:openrouter_gpt)
    profile = WorkflowProfiles::Create.call(
      user: users(:normal),
      attributes: workflow_profile_attributes(
        completion_mode: "refinement_proposals",
        finalizer_ids: [ first.id, second.id ]
      )
    )
    review_round = create_completed_review_round
    pipeline = create_pipeline_run(experiment: review_round.experiment, profile: profile)
    Pipelines::Advance.call(pipeline_run: pipeline)
    Pipelines::Advance.call(pipeline_run: pipeline)
    judge_round = review_round.reload.judge_round
    clear_enqueued_jobs
    complete_judge_run(judge_round.judge_runs.sole)
    Judging::ReconcileRound.call(judge_round)
    clear_enqueued_jobs
    Pipelines::Advance.call(pipeline_run: pipeline)
    round = pipeline.reload.finalization_round
    completed, failed = round.finalization_runs.order(:id).to_a
    complete_finalization_run(completed, proposal: "Preserved proposal")
    failed.update!(status: :failed, completed_at: Time.current)
    Finalizations::ReconcileRound.call(round)
    clear_enqueued_jobs

    Pipelines::Advance.call(pipeline_run: pipeline)
    assert pipeline.reload.blocked?
    assert_equal "finalization", pipeline.blocked_stage
    assert_equal "Preserved proposal", completed.reload.proposed_translation

    complete_finalization_run(failed, proposal: "Recovered proposal")
    clear_enqueued_jobs
    Pipelines::Advance.call(pipeline_run: pipeline)
    assert pipeline.reload.ready_for_editor?
    assert_equal 2, round.finalization_runs.completed.count
    assert_equal 1, pipeline.experiment.final_translation.versions.count
  end

  test "later model routing identity change blocks before starting paid stage" do
    review_round = create_completed_review_round
    judge = LlmModel.create!(
      gateway: "openrouter", provider: "changeable", model_identifier: "changeable/judge-one",
      display_name: "Changeable judge", active: true
    )
    attributes = workflow_profile_attributes.merge(judge_ids: [ judge.id ])
    profile = WorkflowProfiles::Create.call(user: users(:normal), attributes: attributes)
    pipeline = create_pipeline_run(experiment: review_round.experiment, profile: profile)
    Pipelines::Advance.call(pipeline_run: pipeline)

    judge.update!(model_identifier: "changeable/judge-two")
    assert_no_difference -> { JudgeRound.count } do
      assert_no_enqueued_jobs only: JudgeRunJob do
        Pipelines::Advance.call(pipeline_run: pipeline)
      end
    end
    assert pipeline.reload.blocked?
    assert_equal "configuration_unavailable", pipeline.blocked_reason_code
  end

  test "simultaneous advancement creates exactly one review round and no duplicate events" do
    experiment = create_completed_experiment
    pipeline = create_pipeline_run(experiment: experiment)

    results = concurrently(2) do
      Pipelines::Advance.call(pipeline_run: PipelineRun.find(pipeline.id))
    end
    clear_enqueued_jobs

    assert_empty results.grep(Exception)
    assert_equal 1, experiment.reload.review_round ? 1 : 0
    assert_equal 1, ReviewRound.where(experiment: experiment).count
    assert_equal 1, experiment.review_round.review_runs.count
    assert_equal 1, pipeline.events.where(event_key: "review_started").count
  end

  test "stop serializes with advancement and prevents every future stage when it wins first" do
    experiment = create_completed_experiment
    pipeline = create_pipeline_run(experiment: experiment)
    Pipelines::Stop.call(pipeline_run: pipeline)
    Pipelines::Advance.call(pipeline_run: pipeline)

    assert pipeline.reload.stopped?
    assert_nil experiment.reload.review_round
    assert_equal 1, pipeline.events.where(event_key: "automation_stopped").count
  end

  test "cost summary preserves unknown telemetry without join multiplication" do
    experiment = create_completed_experiment
    runs = experiment.translation_runs.order(:id)
    runs.first.update!(cost: BigDecimal("0.25"), cost_complete: true)
    runs.second.update!(cost: nil, cost_complete: false)

    summary = Pipelines::CostSummary.call(experiment: experiment)
    assert_equal BigDecimal("0.25"), summary.known_cost
    assert_equal 1, summary.known_count
    assert_equal 1, summary.complete_count
    assert_equal 2, summary.record_count
    assert summary.incomplete?

    runs.update_all(cost: nil, cost_complete: false)
    all_unknown = Pipelines::CostSummary.call(experiment: experiment)
    assert_nil all_unknown.known_cost
    assert_equal 0, all_unknown.known_count
    assert all_unknown.incomplete?

    empty_project = users(:normal).projects.create!(
      name: "Empty cost pipeline",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    empty_experiment = empty_project.documents.create!(title: "Source", source_text: "Source").experiments.create!(
      instruction_prompt: "Translate faithfully."
    )
    empty = Pipelines::CostSummary.call(experiment: empty_experiment)
    assert_nil empty.known_cost
    assert_equal 0, empty.record_count
    assert_not empty.incomplete?
  end

  test "events are append-only bounded and deterministically ordered" do
    pipeline = create_pipeline_run(experiment: create_completed_experiment)
    event = pipeline.events.first
    assert_not event.update(event_type: "rewritten")
    assert_not event.destroy
    assert_equal [ 1, 2 ], pipeline.events.pluck(:sequence_number)
    assert_equal pipeline.events.first,
                 pipeline.append_event!(event_key: "pipeline_started", event_type: "duplicate")

    oversized = pipeline.events.build(
      sequence_number: 3,
      event_key: "oversized",
      event_type: "test",
      metadata: { "value" => "x" * PipelineEvent::MAX_METADATA_BYTES }
    )
    assert_not oversized.valid?
    assert_includes oversized.errors[:metadata], "is too large"
  end

  private

  def assert_prompt_uses_reference(prompt, revision)
    user_prompt = prompt.fetch(:user_prompt)
    data = if user_prompt.start_with?("<UNTRUSTED_")
      JSON.parse(user_prompt.lines[1...-1].join)
    else
      JSON.parse(user_prompt)
    end
    assert_equal [ {
      "source_text" => revision.source_text,
      "approved_translation" => revision.approved_translation
    } ], data.fetch("reference_examples")
    assert_not_includes user_prompt, "AUTOMATIC_REFERENCE_SOURCE_V2"
  end

  def create_completed_experiment
    project = users(:normal).projects.create!(name: "Pipeline concurrency", source_language: "Vietnamese", target_language: "Japanese")
    experiment = project.documents.create!(title: "Source", source_text: "Source").experiments.create!(
      instruction_prompt: "Translate faithfully.", status: :completed
    )
    [ llm_models(:openrouter_claude), llm_models(:openrouter_gpt) ].each_with_index do |model, index|
      experiment.translation_runs.create!(llm_model: model, status: :completed, translated_text: "Translation #{index}")
    end
    experiment
  end

  def create_failed_experiment
    experiment = create_completed_experiment
    experiment.translation_runs.first.update!(status: :failed, translated_text: nil, completed_at: Time.current)
    experiment.update!(status: :failed)
    experiment
  end

  def complete_review_run(review_run)
    review_run.review_evaluations.each do |evaluation|
      evaluation.update!(
        faithfulness_score: 9,
        naturalness_score: 9,
        terminology_score: 9,
        instruction_adherence_score: 9,
        overall_score: 9,
        strengths: "Strong",
        issues: "None",
        recommended_corrections: "None",
        suggested_translation: "Suggested"
      )
    end
    review_run.update!(status: :completed, completed_at: Time.current)
  end

  def concurrently(count)
    ready = Queue.new
    gate = Queue.new
    results = Queue.new
    threads = count.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          gate.pop
          results << yield
        rescue StandardError => error
          results << error
        end
      end
    end
    count.times { ready.pop }
    count.times { gate << true }
    threads.each(&:join)
    count.times.map { results.pop }
  end
end
