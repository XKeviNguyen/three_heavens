require "test_helper"
require_relative "../../support/analytics_test_helper"

class Benchmarking::ModelHistoryTest < ActiveSupport::TestCase
  include AnalyticsTestHelper

  test "keeps requested grouping stable and reports resolved identifiers scores costs and wins" do
    requested = create_analytics_model(name: "Requested history model")
    other = create_analytics_model(name: "History opponent")
    reviewer = create_analytics_model(name: "History detail reviewer")
    judge = create_analytics_model(name: "History detail judge")

    first_experiment, first_runs = create_analytics_experiment(
      name: "Resolved served model",
      models: [ requested, other ],
      run_attributes: {
        requested => { resolved_model_identifier: "served/model-v2", cost: BigDecimal("0.01") },
        other => { resolved_model_identifier: "served/other" }
      }
    )
    first_review = create_review_round_with_runs(
      experiment: first_experiment,
      specs: [ { reviewer: reviewer, scores: { first_runs[requested] => 9, first_runs[other] => 7 } } ]
    )
    create_judge_round_with_runs(
      review_round: first_review,
      specs: [ { judge: judge, scores: { first_runs[requested] => 90, first_runs[other] => 70 } } ],
      winner: first_runs[requested]
    )

    second_experiment, second_runs = create_analytics_experiment(
      name: "Unreported served model",
      models: [ requested, other ],
      run_attributes: {
        requested => { resolved_model_identifier: " ", cost: nil },
        other => { resolved_model_identifier: "served/other" }
      }
    )
    second_review = create_review_round_with_runs(
      experiment: second_experiment,
      specs: [ { reviewer: reviewer, scores: { second_runs[requested] => 7, second_runs[other] => 8 } } ]
    )
    create_judge_round_with_runs(
      review_round: second_review,
      specs: [ { judge: judge, scores: { second_runs[requested] => 60, second_runs[other] => 80 } } ],
      winner: second_runs[other]
    )

    result = Benchmarking::ModelHistory.new(model: requested).call
    served = result.resolved_models.find { |row| row.resolved_model_identifier == "served/model-v2" }
    unknown = result.resolved_models.find { |row| row.resolved_model_identifier.nil? }

    assert_equal 2, result.entries.size
    assert_equal second_experiment, result.entries.first.translation_run.experiment
    assert_equal BigDecimal("7"), result.entries.first.review_average_score
    assert_equal BigDecimal("60"), result.entries.first.judge_average_score
    assert_not result.entries.first.official_winner
    assert result.entries.last.official_winner

    assert_equal 1, served.sample_count
    assert_equal 1, served.completed_count
    assert_equal 1, served.official_wins
    assert_equal BigDecimal("90"), served.judge_average_score
    assert_equal 1, served.judge_score_sample_count
    assert_equal BigDecimal("0.01"), served.total_known_cost
    assert_equal 1, served.cost_sample_count

    assert_equal 1, unknown.sample_count
    assert_equal 1, unknown.completed_count
    assert_equal 0, unknown.official_wins
    assert_equal BigDecimal("60"), unknown.judge_average_score
    assert_nil unknown.total_known_cost
    assert_equal 0, unknown.cost_sample_count
  end
end
