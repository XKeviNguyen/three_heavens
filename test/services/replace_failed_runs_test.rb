require "test_helper"
require_relative "../support/judging_test_helper"

# A failed reviewer or judge can be swapped for another model inside its round:
# the failed run keeps its history and cost, only the replacement is scheduled
# (and billed), and the round then counts only current runs.
class ReplaceFailedRunsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include JudgingTestHelper

  setup do
    @current_test_user = users(:normal)
    @billing = Ai::BillingPolicy.authorize!(@current_test_user)
    clear_enqueued_jobs
  end

  test "a failed reviewer is replaced, the round completes and judging uses only current reviewers" do
    round, completed, failed = review_round_with_one_failed_reviewer
    failed.update_columns(cost: BigDecimal("0.001"))
    replacement = create_model("replacement-reviewer")
    candidate_ids = failed.review_evaluations.pluck(:translation_run_id).sort

    new_run = nil
    assert_enqueued_jobs 1, only: ReviewRunJob do
      new_run = BlindReviews::ReplaceFailed.call(
        review_round: round, review_run_id: failed.id, replacement: replacement, billing: @billing
      )
    end
    assert_enqueued_with(job: ReviewRunJob, args: [ new_run.id ])

    failed.reload
    assert failed.failed?, "the failed run keeps its status"
    assert_equal new_run, failed.superseded_by
    assert_equal BigDecimal("0.001"), failed.cost, "the failed run keeps its own cost"
    assert round.reload.running?
    assert_equal [ completed.id, new_run.id ].sort, round.review_runs.pluck(:id).sort
    assert_equal 3, round.all_review_runs.count
    assert_equal candidate_ids, new_run.review_evaluations.pluck(:translation_run_id).sort
    assert_equal @billing.billing_source, new_run.reload.billing_source

    complete_review_run(new_run)
    BlindReviews::ReconcileRound.call(round)
    assert round.reload.completed?, "a superseded failed reviewer no longer fails the round"

    judge_round = Judging::Start.call(review_round: round, judge_ids: [ create_judge_model.id ])
    prompt = Judging::Prompt.build(judge_round.judge_runs.first)
    assert prompt.values.join.present?, "judging prompts build from the current reviewers only"
  end

  test "only a current failed reviewer can be replaced, by a new active model, before judging" do
    round, completed, failed = review_round_with_one_failed_reviewer
    replace = ->(run, model) { BlindReviews::ReplaceFailed.call(review_round: round, review_run_id: run.id, replacement: model, billing: @billing) }

    assert_raises(BlindReviews::ReplaceFailed::NotReplaceableError) { replace.call(completed, create_model("x1")) }
    assert_raises(BlindReviews::ReplaceFailed::DuplicateModelError) { replace.call(failed, completed.reviewer_llm_model) }
    assert_raises(BlindReviews::ReplaceFailed::NotReplaceableError) { replace.call(failed, create_model("inactive", active: false)) }

    first = replace.call(failed, create_model("first-replacement"))
    first.update!(status: :failed, error_code: "http_404", completed_at: Time.current)
    BlindReviews::ReconcileRound.call(round)
    assert round.reload.failed?
    assert_raises(BlindReviews::ReplaceFailed::NotReplaceableError, "a superseded run is no longer current") do
      replace.call(failed, create_model("again"))
    end
    assert_raises(BlindReviews::ReplaceFailed::DuplicateModelError, "a model that already failed here cannot return") do
      replace.call(first, failed.reviewer_llm_model)
    end
    assert_equal 0, ReviewRun.where(review_round: round, status: "pending").count
  end

  test "the database refuses supersession that is not a failed run in the same round" do
    round, completed, failed = review_round_with_one_failed_reviewer
    other_round, = review_round_with_one_failed_reviewer

    assert_raises(ActiveRecord::StatementInvalid) do
      ReviewRun.transaction(requires_new: true) { failed.update_columns(superseded_at: Time.current) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ReviewRun.transaction(requires_new: true) do
        failed.update_columns(superseded_at: Time.current, superseded_by_id: other_round.review_runs.first.id)
      end
    end
    running = round.review_runs.create!(reviewer_llm_model: create_model("running"), status: :running)
    assert_raises(ActiveRecord::StatementInvalid) do
      ReviewRun.transaction(requires_new: true) { running.update_columns(superseded_at: Time.current, superseded_by_id: completed.id) }
    end
  end

  test "a failed judge is replaced and the round picks a winner from current judges" do
    review_round, = review_round_with_one_failed_reviewer
    replaced_reviewer = BlindReviews::ReplaceFailed.call(
      review_round: review_round, review_run_id: review_round.review_runs.failed.sole.id,
      replacement: create_model("reviewer-for-judging"), billing: @billing
    )
    complete_review_run(replaced_reviewer)
    BlindReviews::ReconcileRound.call(review_round)
    assert review_round.reload.completed?
    round = Judging::Start.call(review_round: review_round, judge_ids: [ create_judge_model.id, create_judge_model.id ])
    clear_enqueued_jobs
    completed, failed = round.judge_runs.order(:id).to_a
    complete_judge_run(completed)
    failed.update!(status: :failed, error_code: "structured_output_unavailable", completed_at: Time.current)
    Judging::ReconcileRound.call(round)
    assert round.reload.failed?

    new_run = nil
    assert_enqueued_jobs 1, only: JudgeRunJob do
      new_run = Judging::ReplaceFailed.call(judge_round: round, judge_run_id: failed.id, replacement: create_judge_model, billing: @billing)
    end
    assert_equal new_run, failed.reload.superseded_by
    assert round.reload.running?
    assert_nil round.winner_translation_run_id

    complete_judge_run(new_run)
    Judging::ReconcileRound.call(round)
    assert round.reload.completed?
    assert_not_nil round.winner_translation_run_id
    final_translation = FinalTranslations::Create.call(judge_round: round)
    assert final_translation.persisted?

    # The finalizer sees feedback from current reviewers and judges only, not
    # the empty rows the replaced runs left behind.
    finalization_run = Finalizations::Start.call(
      final_translation: final_translation, finalizer_ids: [ create_model("finalizer").id ], billing: @billing
    ).finalization_runs.first
    clear_enqueued_jobs
    user_prompt = Finalizations::Prompt.build(finalization_run).fetch(:user_prompt)
    data = JSON.parse(user_prompt.lines[1...-1].join)
    assert_equal 2, data.fetch("blind_review_feedback").size
    assert data.fetch("blind_review_feedback").all? { |feedback| feedback["overall_score"] }
    assert_equal 2, data.fetch("judge_feedback").size
    assert data.fetch("judge_feedback").all? { |feedback| feedback["rank"] }

    assert_raises(Judging::ReplaceFailed::NotReplaceableError, "judges are fixed once the final translation exists") do
      Judging::ReplaceFailed.call(judge_round: round, judge_run_id: new_run.id, replacement: create_judge_model, billing: @billing)
    end
  end

  private

  def review_round_with_one_failed_reviewer
    experiment = completed_experiment
    round = BlindReviews::Start.call(
      experiment: experiment,
      reviewer_ids: [ llm_models(:openrouter_claude).id, llm_models(:openrouter_gpt).id ],
      billing: @billing
    )
    clear_enqueued_jobs
    completed, failed = round.review_runs.order(:id).to_a
    complete_review_run(completed)
    failed.update!(status: :failed, error_code: "structured_output_unavailable", completed_at: Time.current)
    BlindReviews::ReconcileRound.call(round)
    assert round.reload.failed?
    [ round, completed, failed ]
  end

  def completed_experiment
    project = Project.create!(user: @current_test_user, name: "Replace #{SecureRandom.hex(3)}",
                              source_language: "Vietnamese", target_language: "Japanese")
    document = project.documents.create!(title: "Source", source_text: "Private source")
    document.experiments.create!(instruction_prompt: "Translate faithfully.", status: :completed).tap do |experiment|
      experiment.translation_runs.create!(llm_model: llm_models(:openrouter_claude), status: :completed, translated_text: "First")
      experiment.translation_runs.create!(llm_model: llm_models(:openrouter_gpt), status: :completed, translated_text: "Second")
    end
  end

  def complete_review_run(run)
    run.review_evaluations.each do |evaluation|
      evaluation.update!(faithfulness_score: 9, naturalness_score: 9, terminology_score: 9, instruction_adherence_score: 9,
                         overall_score: 9, strengths: "Strong", issues: "None", recommended_corrections: "None")
    end
    run.update!(status: :completed, completed_at: Time.current)
  end

  def create_model(suffix, active: true)
    LlmModel.create!(gateway: "openrouter", provider: "replace", model_identifier: "replace/#{suffix}-#{SecureRandom.hex(2)}",
                     display_name: "Replace #{suffix}", active: active)
  end
end
