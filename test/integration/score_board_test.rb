require "test_helper"
require_relative "../support/judging_test_helper"

# Review and judging pages open with average scores: a gauge for all
# candidates and a tile per candidate model, highest first.
class ScoreBoardTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include JudgingTestHelper

  setup do
    @current_test_user = users(:normal)
    sign_in_as @current_test_user
  end

  test "the review page shows the average of all models and of each model" do
    review_round = create_completed_review_round

    get review_round_path(review_round)

    assert_response :success
    assert_select "[data-testid='score-board'] h2", text: I18n.t("results_ui.scores.heading.review")
    assert_select "[data-testid='score-average']", text: /8\.5/
    assert_select "[data-testid='score-candidate']", count: 2 do |tiles|
      assert_match(/#{Regexp.escape(llm_models(:openrouter_claude).display_name)}.*9\.0.*0\.5/m, tiles.first.text)
      assert_match(/#{Regexp.escape(llm_models(:openrouter_gpt).display_name)}.*8\.0.*0\.5/m, tiles.last.text)
    end
    assert_select "[data-testid='score-candidate'] .text-emerald-700", count: 1
    assert_select "[data-testid='score-candidate'] .text-red-700", count: 1
  end

  test "the judging page averages the judges' scores, and shows nothing before a judge finishes" do
    review_round = create_completed_review_round
    judge_round = Judging::Start.call(review_round: review_round, judge_ids: [ create_judge_model.id, create_judge_model.id ])
    clear_enqueued_jobs

    get judge_round_path(judge_round)
    assert_select "[data-testid='score-board']", count: 0

    first, second = judge_round.judge_runs.order(:id).to_a
    complete_judge_run(first, **by_label(first, claude: 90, gpt: 70))
    get judge_round_path(judge_round)
    assert_select "[data-testid='score-board']", text: /1 of 2/
    assert_select "[data-testid='score-average']", text: /80\.0/

    complete_judge_run(second, **by_label(second, claude: 80, gpt: 60))
    Judging::ReconcileRound.call(judge_round)
    get judge_round_path(judge_round)
    assert_select "[data-testid='score-board'] h2", text: I18n.t("results_ui.scores.heading.judge")
    assert_select "[data-testid='score-average']", text: /75\.0/
    assert_select "[data-testid='score-candidate']", count: 2
    assert_select "[data-testid='score-candidate']", text: /85\.0/
    assert_select "[data-testid='score-candidate']", text: /65\.0/
  end

  private

  # Judges see candidates under shuffled labels; score them by model.
  def by_label(judge_run, claude:, gpt:)
    scores = judge_run.judge_evaluations.includes(:translation_run).to_h do |evaluation|
      [ evaluation.anonymous_label, evaluation.translation_run.llm_model == llm_models(:openrouter_claude) ? claude : gpt ]
    end
    { order: scores.sort_by { |_, score| -score }.map(&:first), scores: scores }
  end
end
