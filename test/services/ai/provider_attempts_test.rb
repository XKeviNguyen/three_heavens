require "test_helper"

class Ai::ProviderAttemptsTest < ActiveSupport::TestCase
  setup do
    project = users(:normal).projects.create!(
      name: "Attempt lineage",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Source", source_text: "Source text")
    experiment = document.experiments.create!(instruction_prompt: "Translate.", status: :running)
    @run = experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      scheduled_job_id: "authorized-job",
      pending_since: Time.current,
      context_window_tokens_snapshot: 16_384,
      max_output_tokens_snapshot: 4_096,
      estimated_input_tokens: 100,
      reserved_output_tokens: 4_096,
      context_safety_margin_tokens: 1_024,
      budget_policy_version: Ai::ContextBudget::POLICY_VERSION
    )
  end

  test "preserves retry failures and successful telemetry as immutable physical attempts" do
    first = claim(execution: 1)
    attempt_one = @run.provider_attempts.find_by!(attempt_number: 1)
    assert attempt_one.running?
    assert_equal "translation", attempt_one.stage
    assert_equal @run.llm_model.model_identifier, attempt_one.model_identifier_snapshot

    error = Ai::OpenRouterClient::RetryableError.new("private provider detail", code: "network_error")
    Ai::ProviderAttempts.fail_retryable!(run: @run, attempt: first.attempt, error: error)
    assert attempt_one.reload.failed?
    assert_equal "network_error", attempt_one.error_code
    assert_not_includes attempt_one.attributes.to_s, "private provider detail"

    second = claim(execution: 2)
    @run.update!(
      status: :completed,
      translated_text: "Translation",
      completed_at: Time.current,
      prompt_tokens: 10,
      completion_tokens: 20,
      total_tokens: 30,
      cached_tokens: 0,
      reasoning_tokens: 0,
      cost: BigDecimal("0.001")
    )

    attempt_two = @run.provider_attempts.find_by!(attempt_number: second.attempt)
    assert attempt_two.completed?
    assert_equal 30, attempt_two.total_tokens
    assert_equal BigDecimal("0.001"), attempt_two.cost
    assert_not attempt_one.update(display_name_snapshot: "Rewritten history")
    assert_not attempt_one.destroy
  end

  private

  def claim(execution:)
    Ai::ExecutionClaim.call(
      @run,
      active_job_id: "authorized-job",
      active_job_execution: execution
    )
  end
end
