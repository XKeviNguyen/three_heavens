require "test_helper"
require_relative "../support/final_translation_test_helper"

class WorkflowRecoveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper

  setup do
    @current_test_user = users(:normal)
    clear_enqueued_jobs
  end

  test "translation retry preserves completed siblings and is duplicate safe" do
    experiment = create_experiment(status: :running)
    completed = experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      status: :completed,
      translated_text: "Keep this translation",
      completed_at: 1.minute.ago
    )
    failed = experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_gpt),
      status: :failed,
      error_code: "provider_error",
      error_message: "Sanitized failure",
      completed_at: Time.current
    )
    TranslationExperiments::ReconcileExperiment.call(experiment)

    assert_enqueued_with(job: TranslationRunJob, args: [ failed.id ]) do
      result = TranslationExperiments::RetryFailed.call(experiment)
      assert_equal 1, result.retried_count
    end

    assert experiment.reload.running?
    assert failed.reload.pending?
    scheduled_job_id = failed.scheduled_job_id
    assert scheduled_job_id.present?
    assert_equal "Keep this translation", completed.reload.translated_text
    assert completed.completed?

    assert_no_enqueued_jobs do
      assert_equal 0, TranslationExperiments::RetryFailed.call(experiment).retried_count
    end
    assert_equal scheduled_job_id, failed.reload.scheduled_job_id

    failed.update!(status: :completed, translated_text: "Recovered", completed_at: Time.current)
    TranslationExperiments::ReconcileExperiment.call(experiment)
    assert experiment.reload.completed?
  end

  test "translation retry rejects an inactive historical model without changing state" do
    experiment = create_experiment(status: :running)
    model = create_model("inactive-translation")
    failed = experiment.translation_runs.create!(llm_model: model, status: :failed, completed_at: Time.current)
    TranslationExperiments::ReconcileExperiment.call(experiment)
    model.update!(active: false)

    error = assert_raises(Ai::RetryFailedRuns::UnsupportedModelError) do
      TranslationExperiments::RetryFailed.call(experiment)
    end

    assert_match(/inactive or unsupported/, error.message)
    assert failed.reload.failed?
    assert experiment.reload.failed?
    assert_no_enqueued_jobs
  end

  test "review retry preserves completed output and anonymous mappings" do
    experiment = completed_experiment
    round = BlindReviews::Start.call(
      experiment: experiment,
      reviewer_ids: [ llm_models(:openrouter_claude).id, llm_models(:openrouter_gpt).id ]
    )
    clear_enqueued_jobs
    completed, failed = round.review_runs.order(:id).to_a
    complete_review_run(completed)
    failed.update!(status: :failed, error_code: "rejected", completed_at: Time.current)
    BlindReviews::ReconcileRound.call(round)
    mapping = failed.review_evaluations.order(:id).pluck(:id, :translation_run_id, :anonymous_label)
    completed_scores = completed.review_evaluations.order(:id).pluck(:overall_score)

    assert_enqueued_with(job: ReviewRunJob, args: [ failed.id ]) do
      assert_equal 1, BlindReviews::RetryFailed.call(round).retried_count
    end

    assert round.reload.running?
    assert failed.reload.pending?
    assert_equal mapping, failed.review_evaluations.order(:id).pluck(:id, :translation_run_id, :anonymous_label)
    assert_equal completed_scores, completed.reload.review_evaluations.order(:id).pluck(:overall_score)
    assert_no_enqueued_jobs { assert_equal 0, BlindReviews::RetryFailed.call(round).retried_count }

    failed.update!(status: :failed, error_code: "failed_again", completed_at: Time.current)
    BlindReviews::ReconcileRound.call(round)
    assert round.reload.failed?
    clear_enqueued_jobs
    assert_equal 1, BlindReviews::RetryFailed.call(round).retried_count
    complete_review_run(failed)
    BlindReviews::ReconcileRound.call(round)
    assert round.reload.completed?
  end

  test "judge retry clears official aggregate until all judges complete" do
    review_round = create_completed_review_round
    judges = [ create_judge_model, create_judge_model ]
    round = Judging::Start.call(review_round: review_round, judge_ids: judges.map(&:id))
    clear_enqueued_jobs
    completed, failed = round.judge_runs.order(:id).to_a
    complete_judge_run(completed)
    failed.update!(status: :failed, error_code: "rejected", completed_at: Time.current)
    Judging::ReconcileRound.call(round)
    mapping = failed.judge_evaluations.order(:id).pluck(:id, :translation_run_id, :anonymous_label)

    assert round.reload.failed?
    assert_nil round.winner_translation_run_id
    assert_enqueued_with(job: JudgeRunJob, args: [ failed.id ]) do
      assert_equal 1, Judging::RetryFailed.call(round).retried_count
    end

    assert round.reload.running?
    assert_nil round.winner_translation_run_id
    assert_empty round.aggregate_rankings
    assert_equal mapping, failed.reload.judge_evaluations.order(:id).pluck(:id, :translation_run_id, :anonymous_label)
    assert completed.reload.completed?
    assert_no_enqueued_jobs { assert_equal 0, Judging::RetryFailed.call(round).retried_count }

    failed.update!(status: :failed, error_code: "failed_again", completed_at: Time.current)
    Judging::ReconcileRound.call(round)
    assert round.reload.failed?
    assert_nil round.winner_translation_run_id
    clear_enqueued_jobs
    assert_equal 1, Judging::RetryFailed.call(round).retried_count
    complete_judge_run(failed)
    Judging::ReconcileRound.call(round)
    assert round.reload.completed?
    assert_not_nil round.winner_translation_run_id
  end

  test "finalization retry preserves completed proposals and refuses a newer draft" do
    final_translation = create_final_translation_workspace
    finalizers = [ create_finalizer, create_finalizer ]
    round = Finalizations::Start.call(final_translation: final_translation, finalizer_ids: finalizers.map(&:id))
    clear_enqueued_jobs
    completed, failed = round.finalization_runs.order(:id).to_a
    complete_finalization_run(completed, proposal: "Immutable completed proposal")
    failed.update!(status: :failed, error_code: "rejected", completed_at: Time.current)
    Finalizations::ReconcileRound.call(round)

    assert_enqueued_with(job: FinalizationRunJob, args: [ failed.id ]) do
      assert_equal 1, Finalizations::RetryFailed.call(round).retried_count
    end
    assert round.reload.running?
    assert_equal "Immutable completed proposal", completed.reload.proposed_translation
    assert failed.reload.pending?
    assert_no_enqueued_jobs { assert_equal 0, Finalizations::RetryFailed.call(round).retried_count }

    complete_finalization_run(failed, proposal: "Recovered proposal")
    assert round.reload.completed?

    clear_enqueued_jobs
    stale_finalizer = create_finalizer
    stale_round = Finalizations::Start.call(
      final_translation: final_translation,
      finalizer_ids: [ stale_finalizer.id ]
    )
    clear_enqueued_jobs
    stale_run = stale_round.finalization_runs.first
    stale_run.update!(status: :failed, completed_at: Time.current)
    Finalizations::ReconcileRound.call(stale_round)
    FinalTranslations::SaveRevision.call(
      final_translation: final_translation,
      content: "A newer draft",
      expected_version_number: final_translation.current_version.version_number
    )

    assert_raises(FinalTranslations::StaleVersionError) do
      Finalizations::RetryFailed.call(stale_round)
    end
    assert stale_run.reload.failed?
    assert_no_enqueued_jobs
  end

  private

  def create_experiment(status:)
    project = Project.create!(
      user: @current_test_user,
      name: "Recovery project #{SecureRandom.hex(3)}",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Recovery source", source_text: "Private source")
    document.experiments.create!(instruction_prompt: "Translate faithfully.", status: status)
  end

  def completed_experiment
    create_experiment(status: :completed).tap do |experiment|
      experiment.translation_runs.create!(
        llm_model: llm_models(:openrouter_claude),
        status: :completed,
        translated_text: "First"
      )
      experiment.translation_runs.create!(
        llm_model: llm_models(:openrouter_gpt),
        status: :completed,
        translated_text: "Second"
      )
    end
  end

  def complete_review_run(run)
    run.review_evaluations.each do |evaluation|
      evaluation.update!(
        faithfulness_score: 9,
        naturalness_score: 9,
        terminology_score: 9,
        instruction_adherence_score: 9,
        overall_score: 9,
        strengths: "Strong",
        issues: "None",
        recommended_corrections: "None"
      )
    end
    run.update!(status: :completed, completed_at: Time.current)
  end

  def create_model(suffix)
    LlmModel.create!(
      gateway: "openrouter",
      provider: "recovery",
      model_identifier: "recovery/#{suffix}",
      display_name: "Recovery #{suffix}"
    )
  end
end
