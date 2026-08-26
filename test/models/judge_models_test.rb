require "test_helper"
require_relative "../support/judging_test_helper"

class JudgeModelsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include JudgingTestHelper

  setup do
    @review_round = create_completed_review_round
    @judge = create_judge_model
    @judge_round = Judging::Start.call(
      review_round: @review_round,
      judge_ids: [ @judge.id ]
    )
    clear_enqueued_jobs
    @judge_run = @judge_round.judge_runs.first
  end

  test "persists associations and restricts deletion of valuable history" do
    evaluation = @judge_run.judge_evaluations.first

    assert_equal @review_round, @judge_round.review_round
    assert_equal @judge, @judge_run.judge_llm_model
    assert_equal @judge_run, evaluation.judge_run
    assert_equal @review_round.experiment, evaluation.translation_run.experiment
    assert_not @judge.destroy
    assert_not evaluation.translation_run.destroy
    assert_not @review_round.destroy
  end

  test "enforces label translation and rank uniqueness" do
    first, second = @judge_run.judge_evaluations.order(:anonymous_label).to_a

    duplicate_translation = @judge_run.judge_evaluations.build(
      translation_run: first.translation_run,
      anonymous_label: "Candidate C"
    )
    assert_not duplicate_translation.valid?

    duplicate_label = @judge_run.judge_evaluations.build(
      translation_run: second.translation_run,
      anonymous_label: first.anonymous_label
    )
    assert_not duplicate_label.valid?

    first.update!(
      rank: 1,
      overall_score: 90,
      rationale: "Good",
      strengths: "Strong",
      risks: "Minor"
    )
    second.assign_attributes(
      rank: 1,
      overall_score: 80,
      rationale: "Okay",
      strengths: "Readable",
      risks: "Terms"
    )
    assert_not second.valid?
  end

  test "validates score rank and complete ranking lifecycle" do
    evaluation = @judge_run.judge_evaluations.first
    evaluation.assign_attributes(
      rank: 0,
      overall_score: 101,
      rationale: "Good",
      strengths: "Strong",
      risks: "Risk"
    )
    assert_not evaluation.valid?

    @judge_run.status = :completed
    assert_not @judge_run.valid?

    complete_judge_run(@judge_run)
    assert @judge_run.completed?
  end

  test "rejects cross-experiment candidates and winners" do
    other_review = create_completed_review_round(candidate_texts: [ "Other one", "Other two" ])
    foreign_candidate = other_review.experiment.translation_runs.first
    evaluation = @judge_run.judge_evaluations.first
    evaluation.translation_run = foreign_candidate
    assert_not evaluation.valid?
    assert_includes evaluation.errors[:translation_run], "must belong to the judged experiment"

    @judge_round.winner_translation_run = foreign_candidate
    assert_not @judge_round.valid?
    assert_includes @judge_round.errors[:winner_translation_run], "must belong to the judged experiment"
  end

  test "official winner must be one of the persisted judge candidates" do
    model = create_judge_model
    unranked = @review_round.experiment.translation_runs.create!(
      llm_model: model,
      status: :completed,
      translated_text: "Unranked late translation"
    )
    complete_judge_run(@judge_run)
    @judge_round.assign_attributes(
      status: :completed,
      winner_translation_run: unranked,
      aggregate_rankings: [
        {
          "translation_run_id" => unranked.id,
          "aggregate_rank" => 1,
          "borda_points" => 1,
          "mean_overall_score" => 100,
          "judge_count" => 1
        }
      ]
    )

    assert_not @judge_round.valid?
    assert_includes @judge_round.errors[:winner_translation_run], "must be a ranked candidate"
  end

  test "database constraints reject invalid scores and statuses" do
    evaluation = @judge_run.judge_evaluations.first
    assert_raises ActiveRecord::StatementInvalid do
      evaluation.update_column(:overall_score, 101)
    end
    assert_raises ActiveRecord::StatementInvalid do
      @judge_run.update_column(:status, "unknown")
    end
  end
end
