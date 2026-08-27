require "test_helper"
require_relative "../../support/analytics_test_helper"

class Benchmarking::OwnershipScopeTest < ActiveSupport::TestCase
  include AnalyticsTestHelper

  setup do
    @candidate = create_analytics_model(name: "Scoped candidate")
    @opponent = create_analytics_model(name: "Scoped opponent")
    @own_experiment, own_runs = create_analytics_experiment(
      name: "Owned benchmark",
      models: [ @candidate, @opponent ],
      user: users(:normal),
      run_attributes: { @candidate => { cost: BigDecimal("0.01") } }
    )
    own_review = create_review_round_with_runs(
      experiment: @own_experiment,
      specs: [
        {
          reviewer: @candidate,
          scores: { own_runs[@candidate] => 9, own_runs[@opponent] => 7 }
        }
      ]
    )
    create_judge_round_with_runs(
      review_round: own_review,
      specs: [
        {
          judge: @candidate,
          scores: { own_runs[@candidate] => 90, own_runs[@opponent] => 70 }
        }
      ],
      winner: own_runs[@candidate]
    )

    @foreign_experiment, foreign_runs = create_analytics_experiment(
      name: "Foreign benchmark metadata",
      models: [ @candidate, @opponent ],
      user: users(:other),
      run_attributes: { @candidate => { cost: BigDecimal("0.99") } }
    )
    foreign_review = create_review_round_with_runs(
      experiment: @foreign_experiment,
      specs: [
        {
          reviewer: @candidate,
          scores: { foreign_runs[@candidate] => 1, foreign_runs[@opponent] => 10 }
        }
      ]
    )
    create_judge_round_with_runs(
      review_round: foreign_review,
      specs: [
        {
          judge: @candidate,
          scores: { foreign_runs[@candidate] => 10, foreign_runs[@opponent] => 95 }
        }
      ],
      winner: foreign_runs[@opponent]
    )
  end

  test "normal-user aggregates exclude every other user's experiment" do
    stats = stats_for(users(:normal).experiments)

    assert_equal 1, stats.completed_translation_count
    assert_equal 1, stats.review_score_sample_count
    assert_equal BigDecimal("9"), stats.review_average_score
    assert_equal 1, stats.judge_score_sample_count
    assert_equal BigDecimal("90"), stats.judge_average_score
    assert_equal 1, stats.completed_judged_experiment_count
    assert_equal 1, stats.official_wins
    assert_equal BigDecimal("0.01"), stats.total_translation_cost
    assert_equal 1, stats.reviewer_diagnostics.self_sample_count
    assert_equal 1, stats.judge_diagnostics.eligible_run_count
  end

  test "admin global scope includes eligible experiments across users without multiplying joins" do
    stats = stats_for(Experiment.all)

    assert_equal 2, stats.completed_translation_count
    assert_equal 2, stats.review_score_sample_count
    assert_equal 2, stats.judge_score_sample_count
    assert_equal 2, stats.completed_judged_experiment_count
    assert_equal 1, stats.official_wins
    assert_equal BigDecimal("1.00"), stats.total_translation_cost
    assert_equal 2, stats.cost_sample_count
    assert_equal 2, stats.reviewer_diagnostics.self_sample_count
    assert_equal 2, stats.judge_diagnostics.eligible_run_count
  end

  private

  def stats_for(scope)
    Benchmarking::ModelLeaderboard.new(experiment_scope: scope).call.find do |stats|
      stats.model == @candidate
    end
  end
end
