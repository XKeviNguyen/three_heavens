require "test_helper"
require_relative "../../support/analytics_test_helper"

class Benchmarking::ModelLeaderboardTest < ActiveSupport::TestCase
  include AnalyticsTestHelper

  setup do
    @candidate = create_analytics_model(name: "Inactive benchmark candidate", active: false)
    @other = create_analytics_model(name: "Benchmark comparison")
    @reviewers = 3.times.map { |index| create_analytics_model(name: "Benchmark reviewer #{index}") }
    @judges = 2.times.map { |index| create_analytics_model(name: "Benchmark judge #{index}") }
    @experiment, @runs = create_analytics_experiment(
      name: "Join multiplication regression",
      models: [ @candidate, @other ],
      run_attributes: {
        @candidate => {
          cost: BigDecimal("0.01"),
          total_tokens: 100,
          started_at: Time.utc(2026, 1, 1, 12),
          completed_at: Time.utc(2026, 1, 1, 12, 0, 2),
          resolved_model_identifier: "served/candidate-v2"
        },
        @other => { cost: nil, total_tokens: nil }
      }
    )
    review_round = create_review_round_with_runs(
      experiment: @experiment,
      specs: @reviewers.each_with_index.map do |reviewer, index|
        { reviewer: reviewer, scores: { @runs[@candidate] => 7 + index, @runs[@other] => 6 } }
      end
    )
    create_judge_round_with_runs(
      review_round: review_round,
      specs: @judges.each_with_index.map do |judge, index|
        { judge: judge, scores: { @runs[@candidate] => 80 + (index * 10), @runs[@other] => 70 } }
      end,
      winner: @runs[@candidate]
    )
  end

  test "isolated aggregates prevent join multiplication and preserve null semantics" do
    stats = stats_for(@candidate)

    assert_not @candidate.active?
    assert_equal 1, stats.translation_participation_count
    assert_equal 1, stats.completed_translation_count
    assert_equal 0, stats.failed_translation_count
    assert_equal BigDecimal("0"), stats.translation_failure_rate
    assert_equal 1, stats.reviewed_candidate_count
    assert_equal 3, stats.review_score_sample_count
    assert_equal BigDecimal("8"), stats.review_average_score
    assert_equal 1, stats.judged_candidate_count
    assert_equal 2, stats.judge_score_sample_count
    assert_equal BigDecimal("85"), stats.judge_average_score
    assert_equal 1, stats.completed_judged_experiment_count
    assert_equal 1, stats.official_wins
    assert_equal BigDecimal("1"), stats.official_win_rate
    assert_equal BigDecimal("0.01"), stats.total_translation_cost
    assert_equal BigDecimal("0.01"), stats.average_translation_cost
    assert_equal 1, stats.cost_sample_count
    assert_equal BigDecimal("2"), stats.average_latency_seconds
    assert_equal 1, stats.latency_sample_count
    assert_equal BigDecimal("100"), stats.average_total_tokens
    assert_equal 1, stats.token_sample_count
    assert_equal 1, stats.cost_quality_sample_count
    assert_in_delta BigDecimal("0.01") / 85, stats.average_cost_per_judge_score_point, 0.000000000001
  end

  test "uses completed translations and valid telemetry samples only" do
    missing_experiment, = create_analytics_experiment(
      name: "Missing telemetry",
      models: [ @candidate ],
      run_attributes: { @candidate => { cost: nil, total_tokens: nil, started_at: nil, completed_at: nil } }
    )
    bad_experiment, bad_runs = create_analytics_experiment(
      name: "Bad duration",
      models: [ @candidate ],
      run_attributes: {
        @candidate => {
          cost: BigDecimal("0.03"),
          total_tokens: 300,
          started_at: Time.utc(2026, 1, 1, 12, 0, 5),
          completed_at: Time.utc(2026, 1, 1, 12, 0, 4)
        }
      }
    )
    mutate_historical_fixture do
      missing_experiment.translation_runs.first.update_columns(status: "failed", cost: BigDecimal("9"), total_tokens: 9_999)
      bad_runs[@candidate].update_columns(completed_at: Time.utc(2026, 1, 1, 12, 0, 4))
    end

    stats = stats_for(@candidate)

    assert_equal 3, stats.translation_participation_count
    assert_equal 2, stats.completed_translation_count
    assert_equal 1, stats.failed_translation_count
    assert_equal BigDecimal("1") / 3, stats.translation_failure_rate
    assert_equal BigDecimal("0.04"), stats.total_translation_cost
    assert_equal BigDecimal("0.02"), stats.average_translation_cost
    assert_equal 2, stats.cost_sample_count
    assert_equal BigDecimal("200"), stats.average_total_tokens
    assert_equal 2, stats.token_sample_count
    assert_equal BigDecimal("2"), stats.average_latency_seconds
    assert_equal 1, stats.latency_sample_count
  end

  test "excludes failed and incomplete judge rounds from win denominator" do
    failed_experiment, failed_runs = create_analytics_experiment(name: "Failed round", models: [ @candidate ])
    failed_review = create_review_round_with_runs(
      experiment: failed_experiment,
      specs: [ { reviewer: @reviewers.first, scores: { failed_runs[@candidate] => 8 } } ]
    )
    create_judge_round_with_runs(
      review_round: failed_review,
      specs: [ { judge: @judges.first, status: :failed } ],
      status: :failed
    )

    running_experiment, running_runs = create_analytics_experiment(name: "Incomplete round", models: [ @candidate ])
    running_review = create_review_round_with_runs(
      experiment: running_experiment,
      specs: [ { reviewer: @reviewers.first, scores: { running_runs[@candidate] => 8 } } ]
    )
    create_judge_round_with_runs(
      review_round: running_review,
      specs: [ { judge: @judges.first, scores: { running_runs[@candidate] => 88 } } ],
      status: :running
    )

    stats = stats_for(@candidate)

    assert_equal 1, stats.completed_judged_experiment_count
    assert_equal 1, stats.official_wins
    assert_equal BigDecimal("1"), stats.official_win_rate
    assert_equal 3, stats.judge_score_sample_count
  end

  test "zero cost and missing judge scores are excluded from efficiency" do
    zero_experiment, zero_runs = create_analytics_experiment(
      name: "Free judged run",
      models: [ @candidate ],
      run_attributes: { @candidate => { cost: 0 } }
    )
    zero_review = create_review_round_with_runs(
      experiment: zero_experiment,
      specs: [ { reviewer: @reviewers.first, scores: { zero_runs[@candidate] => 8 } } ]
    )
    create_judge_round_with_runs(
      review_round: zero_review,
      specs: [ { judge: @judges.first, scores: { zero_runs[@candidate] => 90 } } ],
      winner: zero_runs[@candidate]
    )
    create_analytics_experiment(
      name: "Paid unjudged run",
      models: [ @candidate ],
      run_attributes: { @candidate => { cost: BigDecimal("0.50") } }
    )

    stats = stats_for(@candidate)

    assert_equal 1, stats.cost_quality_sample_count
    assert_in_delta BigDecimal("0.01") / 85, stats.average_cost_per_judge_score_point, 0.000000000001
  end

  test "null quality scores are missing rather than zero" do
    mutate_historical_fixture do
      ReviewEvaluation.joins(:review_run)
        .where(translation_run: @runs[@candidate], review_runs: { status: "completed" })
        .order(:id)
        .first
        .update_column(:overall_score, nil)
      JudgeEvaluation.joins(:judge_run)
        .where(translation_run: @runs[@candidate], judge_runs: { status: "completed" })
        .order(:id)
        .first
        .update_column(:overall_score, nil)
    end

    stats = stats_for(@candidate)

    assert_equal 2, stats.review_score_sample_count
    assert_equal BigDecimal("8.5"), stats.review_average_score
    assert_equal 1, stats.judge_score_sample_count
    assert_equal BigDecimal("90"), stats.judge_average_score
  end

  test "includes inactive models with translation history and omits models without it" do
    no_history = create_analytics_model(name: "No translation history")
    model_ids = Benchmarking::ModelLeaderboard.new(experiment_scope: Experiment.all).call.map { |stats| stats.model.id }

    assert_includes model_ids, @candidate.id
    assert_not_includes model_ids, no_history.id
  end

  test "all sort options are whitelisted ordered and deterministic" do
    Benchmarking::ModelLeaderboard::SORTS.each do |sort|
      leaderboard = Benchmarking::ModelLeaderboard.new(experiment_scope: Experiment.all, sort: sort)
      first = leaderboard.call
      second = leaderboard.call

      assert_equal sort, leaderboard.sort
      assert_equal first.map { |stats| stats.model.id }, second.map { |stats| stats.model.id }
      assert_sorted(first, sort)
    end

    malicious = Benchmarking::ModelLeaderboard.new(experiment_scope: Experiment.all, sort: "wins; DROP TABLE llm_models")
    assert_equal Benchmarking::ModelLeaderboard::DEFAULT_SORT, malicious.sort
    assert LlmModel.exists?(@candidate.id)
  end

  private

  def stats_for(model)
    Benchmarking::ModelLeaderboard.new(experiment_scope: Experiment.all).call.find { |stats| stats.model.id == model.id }
  end

  def assert_sorted(stats, sort)
    values = stats.filter_map { |row| sort_value(row, sort) }
    expected = %w[translation_cost latency].include?(sort) ? values.sort : values.sort.reverse
    assert_equal expected, values
  end

  def sort_value(stats, sort)
    {
      "judged_samples" => stats.judge_score_sample_count,
      "wins" => stats.official_wins,
      "win_rate" => stats.official_win_rate,
      "review_score" => stats.review_average_score,
      "judge_score" => stats.judge_average_score,
      "translation_cost" => stats.average_translation_cost,
      "latency" => stats.average_latency_seconds
    }.fetch(sort)
  end
end
