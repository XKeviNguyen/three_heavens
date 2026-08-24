require "test_helper"

class TranslationRunJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  setup do
    project = Project.create!(
      name: "Vietnamese to Japanese Sermons",
      source_language: "vi",
      target_language: "ja"
    )
    document = project.documents.create!(
      title: "The Sabbath",
      source_text: "Source theological text"
    )
    @experiment = document.experiments.create!(
      instruction_prompt: "Translate faithfully into Japanese.",
      status: :running
    )
    @llm_model = llm_models(:openrouter_claude)
  end

  test "completes a run and persists translation telemetry" do
    run = @experiment.translation_runs.create!(llm_model: @llm_model)
    client = successful_client

    with_client(client) do
      TranslationRunJob.perform_now(run.id)
    end

    run.reload
    assert run.completed?
    assert_equal "Translated text", run.translated_text
    assert_equal "generation-123", run.provider_response_id
    assert_equal "anthropic/claude-resolved", run.resolved_model_identifier
    assert_equal 120, run.prompt_tokens
    assert_equal 45, run.completion_tokens
    assert_equal 165, run.total_tokens
    assert_equal 20, run.cached_tokens
    assert_equal 8, run.reasoning_tokens
    assert_equal BigDecimal("0.0012345678"), run.cost
    assert_not_nil run.started_at
    assert_not_nil run.completed_at
    assert_nil run.error_code
    assert_nil run.error_message
    assert @experiment.reload.completed?
  end

  test "uses the persisted instruction prompt and document source text" do
    run = @experiment.translation_runs.create!(llm_model: @llm_model)
    captured_arguments = nil
    client = Object.new
    client.define_singleton_method(:chat_completion) do |**arguments|
      captured_arguments = arguments
      successful_result
    end
    client.define_singleton_method(:successful_result) do
      Ai::OpenRouterClient::Result.new(
        content: "Translated text",
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

    with_client(client) do
      TranslationRunJob.perform_now(run.id)
    end

    assert_equal @llm_model.model_identifier,
                 captured_arguments[:model_identifier]
    assert_equal @experiment.instruction_prompt,
                 captured_arguments[:instruction_prompt]
    assert_equal @experiment.document.source_text,
                 captured_arguments[:source_text]
  end

  test "marks permanent failures and sanitizes their messages" do
    run = @experiment.translation_runs.create!(llm_model: @llm_model)
    client = Object.new
    client.define_singleton_method(:chat_completion) do |**|
      raise Ai::OpenRouterClient::PermanentError.new(
        "Bearer secret-token #{"x" * 1_200}",
        code: "invalid_request"
      )
    end

    with_client(client) do
      TranslationRunJob.perform_now(run.id)
    end

    run.reload
    assert run.failed?
    assert_equal "invalid_request", run.error_code
    assert_includes run.error_message, "[FILTERED]"
    assert_not_includes run.error_message, "secret-token"
    assert_operator run.error_message.length, :<=, 1_000
    assert_not_nil run.completed_at
    assert @experiment.reload.failed?
  end

  test "retries retryable failures and leaves the run running" do
    run = @experiment.translation_runs.create!(llm_model: @llm_model)
    client = Object.new
    client.define_singleton_method(:chat_completion) do |**|
      raise Ai::OpenRouterClient::RetryableError.new(
        "Provider busy",
        code: "provider_busy"
      )
    end

    assert_enqueued_with(job: TranslationRunJob, args: [ run.id ]) do
      with_client(client) do
        TranslationRunJob.perform_now(run.id)
      end
    end

    assert run.reload.running?
    assert_nil run.completed_at
    assert @experiment.reload.running?
  end

  test "does not execute a duplicate delivery for a running run" do
    run = @experiment.translation_runs.create!(
      llm_model: @llm_model,
      status: :running,
      started_at: Time.current
    )
    client = Object.new
    client.define_singleton_method(:chat_completion) do |**|
      raise "Client should not be called"
    end

    with_client(client) do
      TranslationRunJob.perform_now(run.id)
    end

    assert run.reload.running?
  end

  test "waits for every run before completing the experiment" do
    first_run = @experiment.translation_runs.create!(llm_model: @llm_model)
    second_run = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_gpt)
    )
    client = successful_client

    with_client(client) do
      TranslationRunJob.perform_now(first_run.id)
      assert @experiment.reload.running?

      TranslationRunJob.perform_now(second_run.id)
    end

    assert @experiment.reload.completed?
  end

  private

  def with_client(client)
    original_factory = TranslationRunJob.client_factory
    TranslationRunJob.client_factory = -> { client }
    yield
  ensure
    TranslationRunJob.client_factory = original_factory
  end

  def successful_client
    result = Ai::OpenRouterClient::Result.new(
      content: "Translated text",
      provider_response_id: "generation-123",
      resolved_model_identifier: "anthropic/claude-resolved",
      prompt_tokens: 120,
      completion_tokens: 45,
      total_tokens: 165,
      cached_tokens: 20,
      reasoning_tokens: 8,
      cost: BigDecimal("0.0012345678")
    )
    client = Object.new
    client.define_singleton_method(:chat_completion) { |**| result }
    client
  end
end
