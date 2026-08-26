require "test_helper"
require_relative "../../support/analytics_test_helper"

class Benchmarking::JudgeDiagnosticsTest < ActiveSupport::TestCase
  include AnalyticsTestHelper

  test "counts agreement only for completed judge runs in completed rounds" do
    judge = create_analytics_model(name: "Agreement judge")
    failing_judge = create_analytics_model(name: "Failing sibling judge")
    candidate = create_analytics_model(name: "Aggregate candidate")
    other = create_analytics_model(name: "Other aggregate candidate")

    create_round_for_judge(judge: judge, candidate: candidate, other: other, judge_winner: :candidate, aggregate_winner: :candidate)
    create_round_for_judge(judge: judge, candidate: candidate, other: other, judge_winner: :other, aggregate_winner: :candidate)

    failed_experiment, failed_runs = create_analytics_experiment(name: "Failed judge run", models: [ candidate, other ])
    failed_review = completed_review_for(failed_experiment, failed_runs, judge)
    create_judge_round_with_runs(
      review_round: failed_review,
      specs: [ { judge: judge, status: :failed } ],
      status: :failed
    )

    failed_round_experiment, failed_round_runs = create_analytics_experiment(name: "Failed aggregate round", models: [ candidate, other ])
    failed_round_review = completed_review_for(failed_round_experiment, failed_round_runs, judge)
    create_judge_round_with_runs(
      review_round: failed_round_review,
      specs: [
        {
          judge: judge,
          scores: { failed_round_runs[candidate] => 90, failed_round_runs[other] => 80 },
          winner: failed_round_runs[candidate]
        },
        { judge: failing_judge, status: :failed }
      ],
      status: :failed
    )

    result = Benchmarking::JudgeDiagnostics.call.fetch(judge.id)

    assert_equal 2, result.eligible_run_count
    assert_equal 1, result.agreement_count
    assert_equal BigDecimal("0.5"), result.agreement_rate
  end

  private

  def create_round_for_judge(judge:, candidate:, other:, judge_winner:, aggregate_winner:)
    experiment, runs = create_analytics_experiment(name: SecureRandom.hex(4), models: [ candidate, other ])
    review_round = completed_review_for(experiment, runs, judge)
    scores = if judge_winner == :candidate
      { runs[candidate] => 90, runs[other] => 80 }
    else
      { runs[candidate] => 80, runs[other] => 90 }
    end
    create_judge_round_with_runs(
      review_round: review_round,
      specs: [
        {
          judge: judge,
          scores: scores,
          winner: runs.fetch(judge_winner == :candidate ? candidate : other)
        }
      ],
      winner: runs.fetch(aggregate_winner == :candidate ? candidate : other)
    )
  end

  def completed_review_for(experiment, runs, reviewer)
    create_review_round_with_runs(
      experiment: experiment,
      specs: [ { reviewer: reviewer, scores: runs.values.index_with { 8 } } ]
    )
  end
end
