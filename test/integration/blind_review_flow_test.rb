require "test_helper"

class BlindReviewFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    project = Project.create!(
      name: "Browser blind review",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(
      title: "Sermon",
      source_text: "Source theological text"
    )
    @experiment = document.experiments.create!(
      name: "Translation comparison",
      instruction_prompt: "Translate faithfully.",
      status: :completed
    )
    @first_model = llm_models(:openrouter_claude)
    @second_model = llm_models(:openrouter_gpt)
    @experiment.translation_runs.create!(
      llm_model: @first_model,
      status: :completed,
      translated_text: "First candidate"
    )
    @experiment.translation_runs.create!(
      llm_model: @second_model,
      status: :completed,
      translated_text: "Second candidate"
    )
  end

  test "completed experiment offers active OpenRouter reviewers and starts a round" do
    inactive = LlmModel.create!(
      gateway: "openrouter",
      provider: "inactive",
      model_identifier: "inactive/browser-reviewer",
      display_name: "Inactive browser reviewer",
      active: false
    )
    direct = LlmModel.create!(
      gateway: "direct",
      provider: "direct",
      model_identifier: "direct/browser-reviewer",
      display_name: "Direct browser reviewer"
    )

    get experiment_path(@experiment)

    assert_response :success
    assert_select "h2", "Start blind cross-review"
    assert_select "form[action='#{experiment_review_rounds_path(@experiment)}']"
    assert_select "input[type='checkbox'][value='#{@first_model.id}']", count: 1
    assert_select "input[type='checkbox'][value='#{@second_model.id}']", count: 1
    assert_select "input[type='checkbox'][value='#{inactive.id}']", count: 0
    assert_select "input[type='checkbox'][value='#{direct.id}']", count: 0

    assert_enqueued_jobs 2, only: ReviewRunJob do
      post experiment_review_rounds_path(@experiment),
           params: {
             review_round: { reviewer_ids: [ @first_model.id, @second_model.id ] }
           }
    end

    round = @experiment.reload.review_round
    assert_redirected_to review_round_path(round)
    assert_equal [ @first_model.id, @second_model.id ].sort,
                 round.review_runs.pluck(:reviewer_llm_model_id).sort
  end

  test "browser rejects malformed inactive unsupported nonexistent and mixed reviewer IDs" do
    inactive = LlmModel.create!(
      gateway: "openrouter",
      provider: "inactive",
      model_identifier: "inactive/tampered-reviewer",
      display_name: "Inactive reviewer",
      active: false
    )
    direct = LlmModel.create!(
      gateway: "direct",
      provider: "direct",
      model_identifier: "direct/tampered-reviewer",
      display_name: "Direct reviewer"
    )

    [ "bad-id", inactive.id, direct.id, 99_999_999,
      [ @first_model.id, inactive.id ] ].each do |tampered|
      ids = Array(tampered)
      assert_no_difference -> { ReviewRound.count } do
        post experiment_review_rounds_path(@experiment),
             params: { review_round: { reviewer_ids: ids } }
      end

      assert_response :unprocessable_content
      assert_select "[role='alert']", text: /valid reviewer|active OpenRouter/
    end
  end

  test "browser rejects missing selection without creating review state" do
    assert_no_difference -> { ReviewRound.count } do
      post experiment_review_rounds_path(@experiment),
           params: {}
    end

    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /Select at least one valid reviewer/
  end

  test "pending round page refreshes automatically and identifies reviewers to the human" do
    round = start_round

    get review_round_path(round)

    assert_response :success
    assert_select "h1", @experiment.name
    assert_select "meta[http-equiv='refresh'][content='5']", count: 1
    assert_select "[role='status']", text: /refreshes automatically every 5 seconds/
    assert_select "article", text: /#{Regexp.escape(@first_model.display_name)}/
    assert_select "article", text: /queued and waiting to start/
  end

  test "completed result page shows scores feedback candidate translation and human mapping" do
    round = start_round
    run = round.review_runs.first
    evaluation = run.review_evaluations.find_by!(anonymous_label: "Candidate A")
    evaluation.update!(
      faithfulness_score: 9,
      naturalness_score: 8,
      terminology_score: 9,
      instruction_adherence_score: 8,
      overall_score: 9,
      strengths: "Strong meaning",
      issues: "Minor style issue",
      recommended_corrections: "Improve the phrase",
      suggested_translation: "Suggested revision"
    )
    other = run.review_evaluations.find_by!(anonymous_label: "Candidate B")
    other.update!(
      faithfulness_score: 7,
      naturalness_score: 7,
      terminology_score: 7,
      instruction_adherence_score: 7,
      overall_score: 7,
      strengths: "Readable",
      issues: "Terminology",
      recommended_corrections: "Use consistent terms"
    )
    run.update!(
      status: :completed,
      prompt_tokens: 200,
      completion_tokens: 100,
      total_tokens: 300,
      cost: BigDecimal("0.0023456789"),
      completed_at: Time.current
    )
    round.update!(status: :completed)

    get review_round_path(round)

    assert_response :success
    assert_select "meta[http-equiv='refresh']", count: 0
    assert_select "article", text: /Candidate A/
    assert_select "article", text: /9\/10 overall/
    assert_select "article", text: /Strong meaning/
    assert_select "article", text: /Minor style issue/
    assert_select "article", text: /Improve the phrase/
    assert_select "article", text: /#{Regexp.escape(evaluation.translation_run.translated_text)}/
    assert_select "article", text: /Human-only mapping:.*#{Regexp.escape(evaluation.translation_run.llm_model.display_name)}/m
    assert_select "article", text: /Suggested revision/
    assert_select "article", text: /Prompt tokens.*200/m
    assert_select "article", text: /Cost.*\$0\.0023456789/m
  end

  test "failed reviewer display escapes output and redacts provider secrets" do
    round = start_round
    run = round.review_runs.first
    run.update!(
      status: :failed,
      error_code: "provider_error",
      error_message: "Bearer provider-secret <script>alert('unsafe')</script>",
      completed_at: Time.current
    )
    round.update!(status: :failed)

    get review_round_path(round)

    assert_response :success
    assert_select "article", text: /Reviewer failed/
    assert_select "article", text: /provider_error/
    assert_includes response.body, "[FILTERED]"
    assert_includes response.body, "&lt;script&gt;alert"
    assert_not_includes response.body, "provider-secret"
    assert_not_includes response.body, "<script>alert('unsafe')</script>"
  end

  test "AI candidate and feedback content is HTML escaped" do
    round = start_round
    run = round.review_runs.first
    run.review_evaluations.each do |evaluation|
      evaluation.update!(
        faithfulness_score: 8,
        naturalness_score: 8,
        terminology_score: 8,
        instruction_adherence_score: 8,
        overall_score: 8,
        strengths: "<script>strength()</script>",
        issues: "<img src=x onerror=issue()>",
        recommended_corrections: "<b>correction</b>"
      )
    end
    run.review_evaluations.first.translation_run.update!(
      translated_text: "<script>candidate()</script>"
    )
    run.update!(status: :completed, completed_at: Time.current)
    round.update!(status: :completed)

    get review_round_path(round)

    assert_response :success
    assert_includes response.body, "&lt;script&gt;strength()&lt;/script&gt;"
    assert_includes response.body, "&lt;script&gt;candidate()&lt;/script&gt;"
    assert_not_includes response.body, "<script>strength()</script>"
    assert_not_includes response.body, "<script>candidate()</script>"
    assert_not_includes response.body, "<img src=x onerror=issue()>"
  end

  test "ineligible experiments do not show the start form" do
    @experiment.update!(status: :running)
    get experiment_path(@experiment)
    assert_select "h2", text: "Start blind cross-review", count: 0

    @experiment.update!(status: :completed)
    @experiment.translation_runs.second.update!(translated_text: "")
    get experiment_path(@experiment)
    assert_select "h2", text: "Start blind cross-review", count: 0
  end

  private

  def start_round
    BlindReviews::Start.call(
      experiment: @experiment,
      reviewer_ids: [ @first_model.id ]
    )
  end
end
