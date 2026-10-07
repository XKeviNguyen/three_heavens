require "test_helper"
require_relative "../support/analytics_test_helper"

class AnalyticsPagesTest < ActionDispatch::IntegrationTest
  include AnalyticsTestHelper

  setup do
    sign_in_as users(:normal)
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
    assert_select "h1", "Translation history"
    assert_select "header", text: /counts each translation, review, judging, and\s+suggestion task once/
    assert_select "article", text: /Completed.*Completed.*Completed/m
    assert_select "article", text: /Winning translation.*Candidate model/m
    assert_select "article",
                  text: /Known cost so far · some tasks did not report cost \(3 of 4\s+tasks finished; 3 with known cost\)/
    assert_select "a[href='#{experiment_path(@experiment)}']", "Translation candidates"
    assert_select "a[href='#{review_round_path(@review_round)}']", "Blind review"
    assert_select "a[href='#{judge_round_path(@judge_round)}']", "Judging results"
    assert_includes response.body, "&lt;img src=x onerror=history()&gt;"
    assert_includes response.body, "&lt;script&gt;Candidate model&lt;/script&gt;"
    assert_not_includes response.body, "<script>Candidate model</script>"
  end

  test "leaderboard renders inactive historical models metrics diagnostics and safe sorting" do
    get benchmarks_path(sort: "wins; DROP TABLE llm_models")

    assert_response :success
    assert_select "h1", "Model benchmarks"
    assert_select "article[data-model-id='#{@candidate.id}']", text: /Inactive/
    assert_select "article[data-model-id='#{@candidate.id}']", text: /Wins.*1/m
    assert_select "article[data-model-id='#{@candidate.id}']", text: /Blind-review score.*9/m
    assert_select "article[data-model-id='#{@candidate.id}']", text: /Judge score.*90/m
    assert_select "section", text: /Reviewer and judge diagnostics/
    assert_select "table", text: /Agrees with overall winner/
    assert_includes response.body, "&lt;script&gt;Candidate model&lt;/script&gt;"
    assert LlmModel.exists?(@candidate.id)
  end

  test "model detail renders scoped aggregate history without project identities or workflow links" do
    get benchmark_model_path(@candidate)

    assert_response :success
    assert_select "h1", text: /Candidate model/
    assert_select "h2", "Summary"
    assert_select "h2", "Role diagnostics"
    assert_select "h2", "Models actually used"
    assert_select "table", text: /served\/page-model/
    assert_select "article", text: /Winner/
    assert_select "article", text: /Blind-review score.*9 \(n=1\)/m
    assert_select "article", text: /Judge score.*90 \(n=1\)/m
    assert_select "article", text: /Response time.*3 s/m
    assert_select "a[href='#{experiment_path(@experiment)}']", count: 0
    assert_select "a[href='#{review_round_path(@review_round)}']", count: 0
    assert_select "a[href='#{judge_round_path(@judge_round)}']", count: 0
    assert_select "article", text: /Difference.*3/m
    assert_select "article", text: /100%.*1 agreement\(s\) across 1 finished judgment/m
    assert_not_includes response.body, "&lt;img src=x onerror=history()&gt;"
  end

  test "unknown model detail returns not found" do
    get benchmark_model_path(99_999_999)

    assert_response :not_found
  end
end
