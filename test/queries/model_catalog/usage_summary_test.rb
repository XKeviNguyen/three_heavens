require "test_helper"
require_relative "../../support/analytics_test_helper"
require_relative "../../support/final_translation_test_helper"

module ModelCatalog
  class UsageSummaryTest < ActiveSupport::TestCase
    include AnalyticsTestHelper
    include ActiveJob::TestHelper
    include FinalTranslationTestHelper

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
      assert_equal 0, usage.fetch(candidate.id).finalization_run_count
      assert_equal 1, usage.fetch(candidate.id).official_win_count
      assert_equal 1, usage.fetch(opponent.id).translation_run_count
      assert_equal 0, usage.fetch(opponent.id).review_run_count
      assert_equal 0, usage.fetch(opponent.id).judge_run_count
      assert_equal 0, usage.fetch(opponent.id).finalization_run_count
      assert_equal 0, usage.fetch(opponent.id).official_win_count
    end

    test "counts inactive model usage from finalization runs without changing other roles" do
      final_translation = create_final_translation_workspace
      finalizer = create_finalizer

      2.times do |index|
        round = final_translation.finalization_rounds.create!(
          base_version: final_translation.current_version,
          selection_key: index.to_s.rjust(64, "0")
        )
        complete_finalization_run(
          round.finalization_runs.create!(finalizer_llm_model: finalizer),
          proposal: "Historical finalizer proposal #{index}"
        )
      end
      finalizer.update!(active: false)

      usage = UsageSummary.call(model_ids: [ finalizer.id ]).fetch(finalizer.id)

      assert_equal 0, usage.translation_run_count
      assert_equal 0, usage.review_run_count
      assert_equal 0, usage.judge_run_count
      assert_equal 2, usage.finalization_run_count
      assert_equal 0, usage.official_win_count
    end

    test "returns an empty hash without querying aggregates for an empty catalog" do
      assert_equal({}, UsageSummary.call(model_ids: []))
    end

    test "loads finalizer usage with one set-based aggregate query" do
      models = 3.times.map { |index| create_analytics_model(name: "Set finalizer #{index}") }
      UsageSummary.call(model_ids: models.map(&:id))
      finalization_queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload.fetch(:sql)
        finalization_queries << sql if sql.include?('FROM "finalization_runs"')
      end

      UsageSummary.call(model_ids: models.map(&:id))

      assert_equal 1, finalization_queries.size
      assert_includes finalization_queries.first, 'GROUP BY "finalization_runs"."finalizer_llm_model_id"'
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
