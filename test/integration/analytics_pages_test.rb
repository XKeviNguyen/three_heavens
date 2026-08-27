require "test_helper"
require_relative "../support/analytics_test_helper"

class AnalyticsPagesTest < ActionDispatch::IntegrationTest
  include AnalyticsTestHelper

  setup do
    @candidate = create_analytics_model(name: "<script>Candidate model</script>")
    @other = create_analytics_model(name: "Page opponent")
    @reviewer = @candidate
    @judge = @candidate
    @experiment, @runs = create_analytics_experiment(
      name: "<img src=x onerror=history()>",
      models: [ @candidate, @other ],
      run_attributes: {
        @candidate => {
          resolved_model_identifier: "served/page-model",
          cost: BigDecimal("0.01"),
          total_tokens: 120,
          started_at: Time.utc(2026, 1, 1, 12),
          completed_at: Time.utc(2026, 1, 1, 12, 0, 3)
        },
        @other => { cost: nil }
      }
    )
    @review_round = create_review_round_with_runs(
      experiment: @experiment,
      specs: [
        {
          reviewer: @reviewer,
          scores: { @runs[@candidate] => 9, @runs[@other] => 6 },
          cost: BigDecimal("0.02")
        }
      ]
    )
    @judge_round = create_judge_round_with_runs(
      review_round: @review_round,
      specs: [
        {
          judge: @judge,
          scores: { @runs[@candidate] => 90, @runs[@other] => 70 },
          cost: BigDecimal("0.03")
        }
      ],
      winner: @runs[@candidate]
    )
    @candidate.update!(active: false)
  end

  test "history renders statuses winner honest cost links pagination and escaped names" do
    get history_path(page: "1; DROP TABLE experiments")

    assert_response :success
    assert_select "h1", "Experiment history"
    assert_select "header", text: /each translation, review, judge, and finalization run once/
    assert_select "article", text: /Completed.*Completed.*Completed/m
    assert_select "article", text: /Official winner.*Candidate model/m
    assert_select "article", text: /Known total · incomplete telemetry \(3\/4 runs\)/
    assert_select "a[href='#{experiment_path(@experiment)}']", "Experiment"
    assert_select "a[href='#{review_round_path(@review_round)}']", "Blind review"
    assert_select "a[href='#{judge_round_path(@judge_round)}']", "Judge results"
    assert_includes response.body, "&lt;img src=x onerror=history()&gt;"
    assert_includes response.body, "&lt;script&gt;Candidate model&lt;/script&gt;"
    assert_not_includes response.body, "<script>Candidate model</script>"
  end

  test "leaderboard renders inactive historical models metrics diagnostics and safe sorting" do
    get benchmarks_path(sort: "wins; DROP TABLE llm_models")

    assert_response :success
    assert_select "h1", "Model benchmark leaderboard"
    assert_select "article[data-model-id='#{@candidate.id}']", text: /Inactive/
    assert_select "article[data-model-id='#{@candidate.id}']", text: /Official wins.*1/m
    assert_select "article[data-model-id='#{@candidate.id}']", text: /Blind-review score.*9/m
    assert_select "article[data-model-id='#{@candidate.id}']", text: /Judge score.*90/m
    assert_select "section", text: /Reviewer and judge diagnostics/
    assert_select "table", text: /Aggregate agreement/
    assert_includes response.body, "&lt;script&gt;Candidate model&lt;/script&gt;"
    assert LlmModel.exists?(@candidate.id)
  end

  test "model detail renders summary recent history resolved model role metrics and links" do
    get benchmark_model_path(@candidate)

    assert_response :success
    assert_select "h1", text: /Candidate model/
    assert_select "h2", "Summary"
    assert_select "h2", "Role diagnostics"
    assert_select "h2", "Resolved-model history"
    assert_select "table", text: /served\/page-model/
    assert_select "article", text: /Official winner/
    assert_select "article", text: /Blind-review score.*9 \(n=1\)/m
    assert_select "article", text: /Judge score.*90 \(n=1\)/m
    assert_select "article", text: /Latency.*3 s/m
    assert_select "a[href='#{experiment_path(@experiment)}']", "Experiment"
    assert_select "a[href='#{review_round_path(@review_round)}']", "Blind review"
    assert_select "a[href='#{judge_round_path(@judge_round)}']", "Judge results"
    assert_select "article", text: /Difference.*3/m
    assert_select "article", text: /100%.*1 agreements across 1 eligible/m
    assert_includes response.body, "&lt;img src=x onerror=history()&gt;"
  end

  test "unknown model detail returns not found" do
    get benchmark_model_path(99_999_999)

    assert_response :not_found
  end
end
