require "test_helper"
require_relative "../support/authorized_ai_job_helper"
require_relative "../support/truncated_open_router_client_helper"

class ReviewRunJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper
  include AuthorizedAiJobHelper
  include TruncatedOpenRouterClientHelper

  setup do
    project = Project.create!(
      user: users(:normal),
      name: "Review job tests",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Source", source_text: "Source text")
    @experiment = document.experiments.create!(
      instruction_prompt: "Translate faithfully.",
      status: :completed
    )
    @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      status: :completed,
      translated_text: "First translation"
    )
    @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_gpt),
      status: :completed,
      translated_text: "Second translation"
    )
    @review_round = BlindReviews::Start.call(
      experiment: @experiment,
      reviewer_ids: [ llm_models(:openrouter_claude).id ]
    )
    clear_enqueued_jobs
    @review_run = @review_round.review_runs.first
  end

  test "defers enqueueing until the surrounding transaction commits" do
    assert ReviewRunJob.enqueue_after_transaction_commit
  end

  test "completes a run maps labels to true translations and persists telemetry" do
    expected_mapping = @review_run.review_evaluations.index_by(&:anonymous_label)
    client = successful_client

    with_client(client) { perform_authorized_ai_job(ReviewRunJob, @review_run) }

    @review_run.reload
    assert @review_run.completed?
    assert @review_round.reload.completed?
    assert_equal "review-generation-123", @review_run.provider_response_id
    assert_equal "anthropic/reviewer-resolved", @review_run.resolved_model_identifier
    assert_equal 200, @review_run.prompt_tokens
    assert_equal 100, @review_run.completion_tokens
    assert_equal 300, @review_run.total_tokens
    assert_equal 25, @review_run.cached_tokens
    assert_equal 5, @review_run.reasoning_tokens
    assert_equal BigDecimal("0.0023456789"), @review_run.cost
    assert_not_nil @review_run.started_at
    assert_not_nil @review_run.completed_at

    @review_run.review_evaluations.each do |evaluation|
      expected = expected_mapping.fetch(evaluation.anonymous_label)
      assert_equal expected.translation_run_id, evaluation.translation_run_id
      assert_equal 9, evaluation.faithfulness_score
      assert_equal 8, evaluation.naturalness_score
      assert_equal 9, evaluation.terminology_score
      assert_equal 8, evaluation.instruction_adherence_score
      assert_equal 9, evaluation.overall_score
      assert_equal "Faithful and clear.", evaluation.strengths
      assert_nil evaluation.suggested_translation
    end
  end

  test "sends a blind structured provider request" do
    captured = nil
    client = Object.new
    client.define_singleton_method(:review_completion) do |**arguments|
      captured = arguments
      successful_result
    end
    client.define_singleton_method(:successful_result) { build_result(valid_content) }
    client.define_singleton_method(:build_result) do |content|
      Ai::OpenRouterClient::Result.new(
        content: content,
        provider_response_id: nil,
        resolved_model_identifier: nil,
        prompt_tokens: nil,
        completion_tokens: nil,
        total_tokens: nil,
        cached_tokens: nil,
        reasoning_tokens: nil,
        cost: nil
      )
    end
    client.define_singleton_method(:valid_content) do
      labels = [ "Candidate A", "Candidate B" ]
      JSON.generate(evaluations: labels.map do |label|
        {
          candidate_label: label,
          faithfulness_score: 9,
          naturalness_score: 8,
          terminology_score: 9,
          instruction_adherence_score: 8,
          overall_score: 9,
          strengths: "Good",
          issues: "Minor issue",
          recommended_corrections: "Fix it",
          suggested_translation: nil
        }
      end)
    end

    with_client(client) { perform_authorized_ai_job(ReviewRunJob, @review_run) }

    assert_equal @review_run.reviewer_llm_model.model_identifier,
                 captured[:model_identifier]
    provider_messages = captured.values_at(:system_prompt, :user_prompt).join("\n")
    candidate_models = @experiment.translation_runs.map(&:llm_model)
    candidate_models.each do |model|
      assert_not_includes captured[:user_prompt], model.provider
      assert_not_includes captured[:user_prompt], model.model_identifier
      assert_not_includes captured[:user_prompt], model.display_name
    end
    assert_includes provider_messages, "Candidate A"
    assert_includes provider_messages, "Candidate B"
    assert_equal false, captured.dig(:response_schema, :additionalProperties)
  end

  test "malformed successful output retries without persisting partial evaluations" do
    client = client_returning("not-json")

    assert_enqueued_with(job: ReviewRunJob, args: [ @review_run.id ]) do
      with_client(client) { perform_authorized_ai_job(ReviewRunJob, @review_run) }
    end

    assert @review_run.reload.running?
    assert @review_run.review_evaluations.all? { |evaluation| evaluation.overall_score.nil? }
    assert @review_round.reload.running?
  end

  test "structurally invalid output retries without persisting any evaluations" do
    partial = JSON.generate(evaluations: [ valid_evaluation("Candidate A") ])

    assert_enqueued_with(job: ReviewRunJob, args: [ @review_run.id ]) do
      with_client(client_returning(partial)) do
        perform_authorized_ai_job(ReviewRunJob, @review_run)
      end
    end

    assert @review_run.reload.running?
    assert_empty @review_run.review_evaluations.where.not(overall_score: nil)
  end

  test "marks permanent failures and sanitizes provider secrets" do
    client = Object.new
    client.define_singleton_method(:review_completion) do |**|
      raise Ai::OpenRouterClient::PermanentError.new(
        "Bearer review-secret <script>unsafe</script>",
        code: "invalid_request"
      )
    end

    with_client(client) { perform_authorized_ai_job(ReviewRunJob, @review_run) }

    assert @review_run.reload.failed?
    assert @review_round.reload.failed?
    assert_equal "invalid_request", @review_run.error_code
    assert_includes @review_run.error_message, "[FILTERED]"
    assert_not_includes @review_run.error_message, "review-secret"
  end

  test "does not persist valid-looking truncated review output" do
    with_client(truncated_open_router_client(valid_content)) do
      perform_authorized_ai_job(ReviewRunJob, @review_run)
    end

    assert @review_run.reload.failed?
    assert_equal "incomplete_response", @review_run.error_code
    assert @review_run.review_evaluations.all? { |evaluation| evaluation.overall_score.nil? }
  end

  test "retries transient provider failures with a bounded job policy" do
    client = Object.new
    client.define_singleton_method(:review_completion) do |**|
      raise Ai::OpenRouterClient::RetryableError.new(
        "Provider busy",
        code: "provider_busy"
      )
    end

    assert_enqueued_with(job: ReviewRunJob, args: [ @review_run.id ]) do
      with_client(client) { perform_authorized_ai_job(ReviewRunJob, @review_run) }
    end

    assert @review_run.reload.running?
    assert_nil @review_run.completed_at
    retry_configuration = ReviewRunJob.rescue_handlers.assoc("Ai::OpenRouterClient::RetryableError")
    assert retry_configuration
  end

  test "does not execute duplicate delivery for a genuinely running run" do
    @review_run.update!(status: :running, started_at: Time.current)
    client, provider_calls = counting_client

    with_client(client) { perform_authorized_ai_job(ReviewRunJob, @review_run) }

    assert @review_run.reload.running?
    assert_equal 0, provider_calls.call
  end

  test "terminal redelivery reconciles a stale round to completed without calling provider" do
    complete_without_reconciliation(@review_run)
    @review_round.update_column(:status, "running")
    client, provider_calls = counting_client

    with_client(client) { perform_authorized_ai_job(ReviewRunJob, @review_run) }

    assert @review_run.reload.completed?
    assert @review_round.reload.completed?
    assert_equal 0, provider_calls.call
  end

  test "terminal redelivery reconciles mixed completed and failed children to failed without calling provider" do
    second_run = add_second_review_run
    complete_without_reconciliation(@review_run)
    fail_without_reconciliation(second_run)
    @review_round.update_column(:status, "running")
    client, provider_calls = counting_client

    with_client(client) { perform_authorized_ai_job(ReviewRunJob, @review_run) }

    assert @review_run.reload.completed?
    assert second_run.reload.failed?
    assert @review_round.reload.failed?
    assert_equal 0, provider_calls.call
  end

  test "terminal redelivery leaves round running while another child is pending or running without calling provider" do
    second_run = add_second_review_run
    complete_without_reconciliation(@review_run)
    client, provider_calls = counting_client

    %i[pending running].each do |status|
      second_run.update!(
        status: status,
        started_at: (Time.current if status == :running)
      )
      @review_round.update_column(:status, "running")

      with_client(client) { perform_authorized_ai_job(ReviewRunJob, @review_run) }

      assert second_run.reload.public_send("#{status}?")
      assert @review_round.reload.running?
    end

    assert @review_run.reload.completed?
    assert_equal 0, provider_calls.call
  end

  test "keeps round running until all runs terminate and preserves mixed outcomes" do
    second_run = @review_round.review_runs.create!(
      reviewer_llm_model: llm_models(:openrouter_gpt)
    )
    @review_run.review_evaluations.each do |evaluation|
      second_run.review_evaluations.create!(
        translation_run: evaluation.translation_run,
        anonymous_label: evaluation.anonymous_label
      )
    end

    with_client(successful_client) { perform_authorized_ai_job(ReviewRunJob, @review_run) }
    assert @review_round.reload.running?

    failing_client = Object.new
    failing_client.define_singleton_method(:review_completion) do |**|
      raise Ai::OpenRouterClient::PermanentError.new("Rejected", code: "rejected")
    end
    with_client(failing_client) { perform_authorized_ai_job(ReviewRunJob, second_run) }

    assert @review_run.reload.completed?
    assert second_run.reload.failed?
    assert @review_round.reload.failed?
    assert_equal 2, @review_run.review_evaluations.where(overall_score: 9).count
  end

  test "unexpected database and programming errors propagate" do
    client = Object.new
    client.define_singleton_method(:review_completion) do |**|
      raise ActiveRecord::StatementInvalid, "SQL failed"
    end

    error = assert_raises ActiveRecord::StatementInvalid do
      with_client(client) { perform_authorized_ai_job(ReviewRunJob, @review_run) }
    end

    assert_equal "SQL failed", error.message
    assert @review_run.reload.running?
  end

  private

  def with_client(client)
    original_factory = ReviewRunJob.client_factory
    ReviewRunJob.client_factory = -> { client }
    yield
  ensure
    ReviewRunJob.client_factory = original_factory
  end

  def successful_client
    client_returning(valid_content)
  end

  def client_returning(content)
    result = build_result(content)
    Object.new.tap do |client|
      client.define_singleton_method(:review_completion) { |**| result }
    end
  end

  def build_result(content)
    Ai::OpenRouterClient::Result.new(
      content: content,
      provider_response_id: "review-generation-123",
      resolved_model_identifier: "anthropic/reviewer-resolved",
      prompt_tokens: 200,
      completion_tokens: 100,
      total_tokens: 300,
      cached_tokens: 25,
      reasoning_tokens: 5,
      cost: BigDecimal("0.0023456789")
    )
  end

  def valid_content
    labels = @review_run.review_evaluations.order(:anonymous_label).pluck(:anonymous_label)
    JSON.generate(evaluations: labels.map { |label| valid_evaluation(label) })
  end

  def valid_evaluation(label)
    {
      candidate_label: label,
      faithfulness_score: 9,
      naturalness_score: 8,
      terminology_score: 9,
      instruction_adherence_score: 8,
      overall_score: 9,
      strengths: "Faithful and clear.",
      issues: "One phrase is awkward.",
      recommended_corrections: "Revise that phrase.",
      suggested_translation: nil
    }
  end

  def add_second_review_run
    second_run = @review_round.review_runs.create!(
      reviewer_llm_model: llm_models(:openrouter_gpt)
    )
    @review_run.review_evaluations.each do |evaluation|
      second_run.review_evaluations.create!(
        translation_run: evaluation.translation_run,
        anonymous_label: evaluation.anonymous_label
      )
    end
    second_run
  end

  def complete_without_reconciliation(review_run)
    review_run.review_evaluations.each do |evaluation|
      evaluation.update!(valid_evaluation(evaluation.anonymous_label).except(:candidate_label))
    end
    review_run.update!(status: :completed, completed_at: Time.current)
  end

  def fail_without_reconciliation(review_run)
    review_run.update!(
      status: :failed,
      completed_at: Time.current,
      error_code: "test_failure",
      error_message: "Reviewer failed"
    )
  end

  def counting_client
    call_count = 0
    client = Object.new
    client.define_singleton_method(:review_completion) do |**|
      call_count += 1
      raise "Provider must not be called during reconciliation"
    end
    [ client, -> { call_count } ]
  end
end
