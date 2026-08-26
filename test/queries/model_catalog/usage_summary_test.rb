require "test_helper"
require_relative "../../support/analytics_test_helper"

module ModelCatalog
  class UsageSummaryTest < ActiveSupport::TestCase
    include AnalyticsTestHelper

    test "counts each historical role and completed official wins" do
      candidate = create_analytics_model(name: "Catalog candidate")
      opponent = create_analytics_model(name: "Catalog opponent")
      experiment, runs = create_analytics_experiment(
        name: "Catalog usage",
        models: [ candidate, opponent ]
      )
      review_round = create_review_round_with_runs(
        experiment: experiment,
        specs: [
          {
            reviewer: candidate,
            scores: { runs[candidate] => 9, runs[opponent] => 7 }
          }
        ]
      )
      create_judge_round_with_runs(
        review_round: review_round,
        specs: [
          {
            judge: candidate,
            scores: { runs[candidate] => 90, runs[opponent] => 70 }
          }
        ],
        winner: runs[candidate]
      )

      usage = UsageSummary.call(model_ids: [ candidate.id, opponent.id ])

      assert_equal 1, usage.fetch(candidate.id).translation_run_count
      assert_equal 1, usage.fetch(candidate.id).review_run_count
      assert_equal 1, usage.fetch(candidate.id).judge_run_count
      assert_equal 1, usage.fetch(candidate.id).official_win_count
      assert_equal 1, usage.fetch(opponent.id).translation_run_count
      assert_equal 0, usage.fetch(opponent.id).review_run_count
      assert_equal 0, usage.fetch(opponent.id).judge_run_count
      assert_equal 0, usage.fetch(opponent.id).official_win_count
    end

    test "returns an empty hash without querying aggregates for an empty catalog" do
      assert_equal({}, UsageSummary.call(model_ids: []))
    end
  end
end
