require "test_helper"
require_relative "../support/final_translation_test_helper"

class FinalizationRunJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper

  setup do
    @final_translation = create_final_translation_workspace
    @finalizer = create_finalizer
    @round = Finalizations::Start.call(
      final_translation: @final_translation,
      finalizer_ids: [ @finalizer.id ]
    )
    clear_enqueued_jobs
    @run = @round.finalization_runs.first
  end

  test "is commit-aware and atomically persists a proposal telemetry and completed round" do
    assert FinalizationRunJob.enqueue_after_transaction_commit

    with_client(client_returning(valid_content)) do
      FinalizationRunJob.perform_now(@run.id)
    end

    @run.reload
    assert @run.completed?
    assert @round.reload.completed?
    assert_equal "Refined complete translation", @run.proposed_translation
    assert_equal [ "Improved clarity" ], @run.change_summary
    assert_equal [ "Preserved term" ], @run.terminology_notes
    assert_equal [ "Verify one ambiguity" ], @run.warnings
    assert_equal "finalization-response-123", @run.provider_response_id
    assert_equal "finalizer/resolved", @run.resolved_model_identifier
    assert_equal 300, @run.total_tokens
    assert_equal BigDecimal("0.00456789"), @run.cost
    assert_equal 1, @final_translation.reload.versions.count
  end

  test "sends blind structured evidence without human-only identities" do
    captured = nil
    client = Object.new
    result = build_result(valid_content)
    client.define_singleton_method(:finalization_completion) do |**arguments|
      captured = arguments
      result
    end

    with_client(client) { FinalizationRunJob.perform_now(@run.id) }

    assert_equal @finalizer.model_identifier, captured.fetch(:model_identifier)
    messages = captured.values_at(:system_prompt, :user_prompt).join("\n")
    @final_translation.experiment.translation_runs.each do |candidate|
      assert_not_includes messages, candidate.llm_model.display_name
      assert_not_includes messages, candidate.llm_model.model_identifier
      assert_not_includes messages, candidate.llm_model.provider
    end
    assert_includes messages, @round.base_version.content
    assert_equal false, captured.dig(:response_schema, :additionalProperties)
  end

  test "malformed successful output retries with no partial proposal persistence" do
    invalid = JSON.generate(
      proposed_translation: "Partial",
      change_summary: [ "Changed" ],
      terminology_notes: []
    )
    assert_enqueued_with(job: FinalizationRunJob, args: [ @run.id ]) do
      with_client(client_returning(invalid)) do
        FinalizationRunJob.perform_now(@run.id)
      end
    end

    assert @run.reload.running?
    assert_nil @run.proposed_translation
    assert_empty @run.change_summary
    assert @round.reload.running?
  end

  test "retries transient failures and sanitizes permanent failures" do
    retrying = Object.new
    retrying.define_singleton_method(:finalization_completion) do |**|
      raise Ai::OpenRouterClient::RetryableError.new("Busy", code: "busy")
    end
    assert_enqueued_with(job: FinalizationRunJob, args: [ @run.id ]) do
      with_client(retrying) { FinalizationRunJob.perform_now(@run.id) }
    end
    assert @run.reload.running?

    @run.update_column(:status, "pending")
    failing = Object.new
    failing.define_singleton_method(:finalization_completion) do |**|
      raise Ai::OpenRouterClient::PermanentError.new(
        "Bearer finalizer-secret <script>bad</script>",
        code: "rejected"
      )
    end
    with_client(failing) { FinalizationRunJob.perform_now(@run.id) }

    assert @run.reload.failed?
    assert @round.reload.failed?
    assert_equal "rejected", @run.error_code
    assert_includes @run.error_message, "[FILTERED]"
    assert_not_includes @run.error_message, "finalizer-secret"
  end

  test "retry exhaustion persists failure once" do
    client = Object.new
    client.define_singleton_method(:finalization_completion) do |**|
      raise Ai::OpenRouterClient::RetryableError.new(
        "Bearer exhausted-secret",
        code: "provider_busy"
      )
    end

    assert_performed_jobs 5, only: FinalizationRunJob do
      with_client(client) { FinalizationRunJob.perform_later(@run.id) }
    end

    assert @run.reload.failed?
    assert @round.reload.failed?
    assert_equal "provider_busy", @run.error_code
    assert_not_includes @run.error_message, "exhausted-secret"
    assert_no_enqueued_jobs only: FinalizationRunJob
  end

  test "skips duplicate running delivery" do
    @run.update!(status: :running, started_at: Time.current)
    client, calls = counting_client
    with_client(client) { FinalizationRunJob.perform_now(@run.id) }

    assert_equal 0, calls.call
    assert @run.reload.running?
  end

  test "terminal redelivery reconciles stale parent with zero provider calls" do
    complete_finalization_run(@run)
    @round.update_column(:status, "running")
    client, calls = counting_client
    with_client(client) { FinalizationRunJob.perform_now(@run.id) }

    assert_equal 0, calls.call
    assert @round.reload.completed?
  end

  test "mixed sibling outcomes preserve success and fail only the parent" do
    second = @round.finalization_runs.create!(finalizer_llm_model: create_finalizer)
    complete_finalization_run(@run)
    second.update!(
      status: :failed,
      completed_at: Time.current,
      error_code: "failed",
      error_message: "Finalizer failed"
    )
    @round.update_column(:status, "running")
    client, calls = counting_client
    with_client(client) { FinalizationRunJob.perform_now(@run.id) }

    assert_equal 0, calls.call
    assert @run.reload.completed?
    assert second.reload.failed?
    assert @round.reload.failed?
    assert_equal "Polished final translation", @run.proposed_translation
  end

  test "unexpected programming and database errors propagate" do
    client = Object.new
    client.define_singleton_method(:finalization_completion) do |**|
      raise ActiveRecord::StatementInvalid, "SQL failed"
    end
    error = assert_raises ActiveRecord::StatementInvalid do
      with_client(client) { FinalizationRunJob.perform_now(@run.id) }
    end
    assert_equal "SQL failed", error.message
    assert @run.reload.running?
  end

  private

  def with_client(client)
    original = FinalizationRunJob.client_factory
    FinalizationRunJob.client_factory = -> { client }
    yield
  ensure
    FinalizationRunJob.client_factory = original
  end

  def client_returning(content)
    result = build_result(content)
    Object.new.tap do |client|
      client.define_singleton_method(:finalization_completion) { |**| result }
    end
  end

  def build_result(content)
    Ai::OpenRouterClient::Result.new(
      content: content,
      provider_response_id: "finalization-response-123",
      resolved_model_identifier: "finalizer/resolved",
      prompt_tokens: 210,
      completion_tokens: 90,
      total_tokens: 300,
      cached_tokens: 15,
      reasoning_tokens: 3,
      cost: BigDecimal("0.00456789")
    )
  end

  def valid_content
    JSON.generate(
      proposed_translation: "Refined complete translation",
      change_summary: [ "Improved clarity" ],
      terminology_notes: [ "Preserved term" ],
      warnings: [ "Verify one ambiguity" ]
    )
  end

  def counting_client
    calls = 0
    client = Object.new
    client.define_singleton_method(:finalization_completion) do |**|
      calls += 1
      raise "Provider must not be called"
    end
    [ client, -> { calls } ]
  end
end
