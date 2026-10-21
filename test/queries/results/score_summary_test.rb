require "test_helper"

class Results::ScoreSummaryTest < ActiveSupport::TestCase
  setup do
    @first = TranslationRun.new(id: 101, llm_model: llm_models(:openrouter_claude))
    @second = TranslationRun.new(id: 102, llm_model: llm_models(:openrouter_gpt))
  end

  test "averages each candidate over finished runs only, highest first, with its distance from the average" do
    runs = [
      review_run(:completed, @first => 9, @second => 6),
      review_run(:completed, @first => 7, @second => 6),
      review_run(:failed, @first => nil, @second => nil),
      review_run(:running, @first => 1, @second => 1)
    ]

    summary = Results::ScoreSummary.call(runs, evaluations: :review_evaluations, scale: ReviewEvaluation::SCORE_RANGE)

    assert_equal 7.0, summary.average
    assert_equal [ @first, @second ], summary.candidates.map(&:translation_run)
    assert_equal [ 8.0, 6.0 ], summary.candidates.map(&:average)
    assert_equal [ 1.0, -1.0 ], summary.candidates.map(&:delta)
    assert_equal [ 2, 2 ], summary.candidates.map(&:count)
    assert_equal [ 2, 4 ], [ summary.finished_runs, summary.total_runs ]
  end

  test "there is nothing to show until a run has finished" do
    assert_nil Results::ScoreSummary.call([], evaluations: :review_evaluations, scale: ReviewEvaluation::SCORE_RANGE)
    running = [ review_run(:running, @first => 9, @second => 8) ]
    assert_nil Results::ScoreSummary.call(running, evaluations: :review_evaluations, scale: ReviewEvaluation::SCORE_RANGE)
  end

  private

  def review_run(status, scores)
    ReviewRun.new(status: status, review_evaluations: scores.map do |translation_run, score|
      ReviewEvaluation.new(translation_run: translation_run, overall_score: score)
    end)
  end
end
