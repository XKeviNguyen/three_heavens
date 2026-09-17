require "test_helper"
require_relative "../support/judging_test_helper"

class JudgeSelectionFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include JudgingTestHelper

  setup do
    sign_in_as users(:normal)
    @review_round = create_completed_review_round
    @judge = create_judge_model
  end

  test "completed blind review offers judges and starts browser workflow" do
    inactive = create_judge_model(active: false)
    direct = create_judge_model(gateway: "direct")

    get review_round_path(@review_round)

    assert_response :success
    assert_select "h2", "Start judge selection"
    assert_select "form[action='#{review_round_judge_rounds_path(@review_round)}']"
    assert_select "input[type='checkbox'][value='#{@judge.id}']", count: 1
    assert_select "input[type='checkbox'][value='#{inactive.id}']", count: 0
    assert_select "input[type='checkbox'][value='#{direct.id}']", count: 0

    assert_enqueued_jobs 1, only: JudgeRunJob do
      post review_round_judge_rounds_path(@review_round),
           params: { judge_round: { judge_ids: [ @judge.id ] } }
    end
    round = @review_round.reload.judge_round
    assert_redirected_to judge_round_path(round)
  end

  test "incomplete blind review hides the start form" do
    mutate_historical_fixture { @review_round.update_column(:status, "running") }
    get review_round_path(@review_round)

    assert_response :success
    assert_select "h2", text: "Start judge selection", count: 0
  end

  test "tampered and missing judge IDs reject the entire request" do
    inactive = create_judge_model(active: false)
    direct = create_judge_model(gateway: "direct")
    [ [], [ "bad" ], [ 99_999_999 ], [ inactive.id ], [ direct.id ],
      [ @judge.id, inactive.id ] ].each do |ids|
      assert_no_difference -> { JudgeRound.count } do
        post review_round_judge_rounds_path(@review_round),
             params: { judge_round: { judge_ids: ids } }
      end
      assert_response :unprocessable_content
      assert_select "[role='alert']", text: /judge|active OpenRouter/i
    end
  end

  test "pending page refreshes and identifies selected judges to the human" do
    round = start_round
    get judge_round_path(round)

    assert_response :success
    assert_select "meta[http-equiv='refresh'][content='5']", count: 1
    assert_select "[role='status']", text: /refreshes automatically every 5 seconds/
    assert_select "article", text: /#{Regexp.escape(@judge.display_name)}/
    assert_select "article", text: /queued and waiting to start/
  end

  test "completed page displays individual ranking mapping telemetry and aggregate winner" do
    round = start_round
    run = round.judge_runs.first
    complete_judge_run(run)
    mutate_historical_fixture do
      run.update!(
        prompt_tokens: 200,
        completion_tokens: 100,
        total_tokens: 300,
        cost: BigDecimal("0.003456789")
      )
    end
    Judging::ReconcileRound.call(round)

    get judge_round_path(round)

    assert_response :success
    assert_select "meta[http-equiv='refresh']", count: 0
    assert_select "h2", text: /#{Regexp.escape(round.winner_translation_run.llm_model.display_name)}/
    assert_select "article", text: /Judge winner:/
    assert_select "article", text: /#1 · Candidate/
    assert_select "article", text: /90\/100/
    assert_select "article", text: /Human-only mapping:/
    assert_select "article", text: /Rationale for Candidate/
    assert_select "article", text: /Prompt tokens.*200/m
    assert_select "article", text: /Cost.*\$0\.003456789/m
    assert_includes response.body, "Borda points"
  end

  test "failed judge is sanitized escaped and yields no official winner" do
    round = start_round
    run = round.judge_runs.first
    run.update!(
      status: :failed,
      completed_at: Time.current,
      error_code: "PRIVATE_PROVIDER_ERROR_CODE",
      error_message: "Bearer provider-secret <script>alert('unsafe')</script>"
    )
    Judging::ReconcileRound.call(round)

    get judge_round_path(round)

    assert_response :success
    assert_select "h2", "No official aggregate winner"
    assert_select "article", text: /Judge failed/
    assert_includes response.body, "AI work failed."
    assert_not_includes response.body, "PRIVATE_PROVIDER_ERROR_CODE"
    assert_not_includes response.body, "&lt;script&gt;alert"
    assert_not_includes response.body, "provider-secret"
    assert_not_includes response.body, "<script>alert('unsafe')</script>"
  end

  test "AI ranking and translation text are HTML escaped" do
    round = start_round
    run = round.judge_runs.first
    run.judge_evaluations.order(:anonymous_label).each_with_index do |evaluation, index|
      evaluation.update!(
        rank: index + 1,
        overall_score: 90 - index,
        rationale: "<script>rationale()</script>",
        strengths: "<img src=x onerror=strength()>",
        risks: "<b>risk</b>"
      )
    end
    winner = run.judge_evaluations.find_by!(rank: 1)
    mutate_historical_fixture do
      winner.translation_run.update!(translated_text: "<script>candidate()</script>")
    end
    run.update!(
      status: :completed,
      winner_translation_run: winner.translation_run,
      winner_rationale: "<script>winner()</script>",
      confidence_score: 90,
      completed_at: Time.current
    )
    Judging::ReconcileRound.call(round)

    get judge_round_path(round)

    assert_includes response.body, "&lt;script&gt;rationale()&lt;/script&gt;"
    assert_includes response.body, "&lt;script&gt;candidate()&lt;/script&gt;"
    assert_includes response.body, "&lt;script&gt;winner()&lt;/script&gt;"
    assert_not_includes response.body, "<script>rationale()</script>"
    assert_not_includes response.body, "<img src=x onerror=strength()>"
  end

  private

  def start_round
    Judging::Start.call(review_round: @review_round, judge_ids: [ @judge.id ])
  end
end
