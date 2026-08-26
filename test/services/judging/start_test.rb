require "test_helper"
require_relative "../../support/judging_test_helper"

class Judging::StartTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include JudgingTestHelper

  setup do
    @review_round = create_completed_review_round
    @judges = [ create_judge_model, create_judge_model ]
  end

  test "creates one or multiple judge runs with independent persisted mappings" do
    calls = 0
    randomizer = lambda do |candidates|
      calls += 1
      calls.odd? ? candidates : candidates.reverse
    end

    assert_difference -> { JudgeRound.count }, 1 do
      assert_difference -> { JudgeRun.count }, 2 do
        assert_difference -> { JudgeEvaluation.count }, 4 do
          assert_enqueued_jobs 2, only: JudgeRunJob do
            @judge_round = Judging::Start.new(
              review_round: @review_round,
              judge_ids: @judges.map(&:id),
              randomizer: randomizer
            ).call
          end
        end
      end
    end

    runs = @judge_round.judge_runs.order(:judge_llm_model_id)
    assert @judge_round.running?
    assert_equal runs.first.judge_evaluations.order(:anonymous_label).pluck(:translation_run_id).reverse,
                 runs.second.judge_evaluations.order(:anonymous_label).pluck(:translation_run_id)
  end

  test "is idempotent for identical selection and rejects a changed selection" do
    first = Judging::Start.call(
      review_round: @review_round,
      judge_ids: [ @judges.first.id ]
    )
    clear_enqueued_jobs

    assert_no_difference [ -> { JudgeRound.count }, -> { JudgeRun.count } ] do
      assert_no_enqueued_jobs only: JudgeRunJob do
        assert_equal first, Judging::Start.call(
          review_round: @review_round,
          judge_ids: [ @judges.first.id ]
        )
      end
    end
    assert_raises Judging::Start::AlreadyStartedError do
      Judging::Start.call(
        review_round: @review_round,
        judge_ids: @judges.map(&:id)
      )
    end
  end

  test "rejects incomplete review and experiment lifecycle states" do
    %i[pending running failed].each do |status|
      @review_round.update_column(:status, status)
      assert_raises Judging::Start::InvalidReviewStateError do
        start_with(@judges.first)
      end
    end
    @review_round.update_column(:status, "completed")
    @review_round.experiment.update!(status: :running)
    assert_raises Judging::Start::InvalidReviewStateError do
      start_with(@judges.first)
    end
  end

  test "requires two candidates and complete correctly mapped review feedback" do
    candidate = @review_round.experiment.translation_runs.second
    candidate.update!(translated_text: "")
    assert_raises Judging::Start::InsufficientCandidatesError do
      start_with(@judges.first)
    end

    candidate.update!(translated_text: "Restored")
    evaluation = @review_round.review_runs.first.review_evaluations.second
    evaluation.update_column(:overall_score, nil)
    assert_raises Judging::Start::IncompleteReviewDataError do
      start_with(@judges.first)
    end
  end

  test "rejects missing malformed nonexistent inactive unsupported and mixed judge IDs" do
    inactive = create_judge_model(active: false)
    direct = create_judge_model(gateway: "direct")
    [ [], [ "bad" ], [ 99_999_999 ], [ inactive.id ], [ direct.id ],
      [ @judges.first.id, inactive.id ] ].each do |ids|
      assert_raises Judging::Start::InvalidJudgeSelectionError do
        Judging::Start.call(review_round: @review_round, judge_ids: ids)
      end
      assert_nil @review_round.reload.judge_round
    end
  end

  test "rejects cross-experiment review mappings" do
    other_review = create_completed_review_round(candidate_texts: [ "Other one", "Other two" ])
    evaluation = @review_round.review_runs.first.review_evaluations.first
    evaluation.update_column(
      :translation_run_id,
      other_review.experiment.translation_runs.first.id
    )

    assert_raises Judging::Start::IncompleteReviewDataError do
      start_with(@judges.first)
    end
  end

  test "rolls back state and jobs on domain failure and propagates unexpected errors" do
    assert_no_difference [ -> { JudgeRound.count }, -> { JudgeRun.count }, -> { JudgeEvaluation.count } ] do
      assert_no_enqueued_jobs only: JudgeRunJob do
        assert_raises ArgumentError do
          Judging::Start.new(
            review_round: @review_round,
            judge_ids: [ @judges.first.id ],
            randomizer: ->(candidates) { candidates.first(1) }
          ).call
        end
      end
    end

    error = assert_raises ActiveRecord::StatementInvalid do
      Judging::Start.new(
        review_round: @review_round,
        judge_ids: [ @judges.first.id ],
        randomizer: ->(_) { raise ActiveRecord::StatementInvalid, "SQL failed" }
      ).call
    end
    assert_equal "SQL failed", error.message
  end

  private

  def start_with(judge)
    Judging::Start.call(review_round: @review_round, judge_ids: [ judge.id ])
  end
end
