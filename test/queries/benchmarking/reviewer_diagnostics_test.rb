require "test_helper"
require_relative "../../support/analytics_test_helper"

class Benchmarking::ReviewerDiagnosticsTest < ActiveSupport::TestCase
  include AnalyticsTestHelper

  test "calculates positive negative and unavailable self-score differences from completed runs" do
    positive = create_analytics_model(name: "Positive reviewer")
    negative = create_analytics_model(name: "Negative reviewer")
    no_self = create_analytics_model(name: "No self samples reviewer")
    no_other = create_analytics_model(name: "No other samples reviewer")
    other = create_analytics_model(name: "Other candidate")
    experiment, runs = create_analytics_experiment(
      name: "Reviewer diagnostics",
      models: [ positive, negative, no_other, other ]
    )
    create_review_round_with_runs(
      experiment: experiment,
      specs: [
        {
          reviewer: positive,
          scores: { runs[positive] => 9, runs[negative] => 5, runs[no_other] => 5, runs[other] => 5 }
        },
        {
          reviewer: negative,
          scores: { runs[positive] => 7, runs[negative] => 3, runs[no_other] => 7, runs[other] => 7 }
        },
        {
          reviewer: no_self,
          scores: { runs[positive] => 6, runs[other] => 6 }
        },
        {
          reviewer: no_other,
          scores: { runs[no_other] => 8 }
        }
      ]
    )

    failed_experiment, failed_runs = create_analytics_experiment(
      name: "Failed reviewer diagnostics",
      models: [ positive, other ]
    )
    create_review_round_with_runs(
      experiment: failed_experiment,
      specs: [
        {
          reviewer: positive,
          scores: { failed_runs[positive] => 1, failed_runs[other] => 10 },
          status: :failed
        }
      ],
      status: :failed
    )

    diagnostics = Benchmarking::ReviewerDiagnostics.call

    assert_diagnostic diagnostics.fetch(positive.id), self_count: 1, self_average: 9, other_count: 3, other_average: 5, difference: 4
    assert_diagnostic diagnostics.fetch(negative.id), self_count: 1, self_average: 3, other_count: 3, other_average: 7, difference: -4

    no_self_result = diagnostics.fetch(no_self.id)
    assert_equal 0, no_self_result.self_sample_count
    assert_nil no_self_result.self_average_score
    assert_equal 2, no_self_result.other_sample_count
    assert_nil no_self_result.self_score_difference

    no_other_result = diagnostics.fetch(no_other.id)
    assert_equal 1, no_other_result.self_sample_count
    assert_equal 0, no_other_result.other_sample_count
    assert_nil no_other_result.other_average_score
    assert_nil no_other_result.self_score_difference
  end

  private

  def assert_diagnostic(result, self_count:, self_average:, other_count:, other_average:, difference:)
    assert_equal self_count, result.self_sample_count
    assert_equal BigDecimal(self_average.to_s), result.self_average_score
    assert_equal other_count, result.other_sample_count
    assert_equal BigDecimal(other_average.to_s), result.other_average_score
    assert_equal BigDecimal(difference.to_s), result.self_score_difference
  end
end
