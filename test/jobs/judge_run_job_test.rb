require "test_helper"
require_relative "../support/judging_test_helper"

class JudgeRunJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper
  include JudgingTestHelper

  setup do
    @review_round = create_completed_review_round
    @judge = create_judge_model
    @judge_round = Judging::Start.call(
      review_round: @review_round,
      judge_ids: [ @judge.id ]
    )
    clear_enqueued_jobs
    @judge_run = @judge_round.judge_runs.first
  end

  test "is commit-aware and atomically persists ranking winner telemetry and aggregate" do
    assert JudgeRunJob.enqueue_after_transaction_commit

    with_client(client_returning(valid_content)) do
      JudgeRunJob.perform_now(@judge_run.id)
    end

    @judge_run.reload
    @judge_round.reload
    assert @judge_run.completed?
    assert @judge_round.completed?
    assert_equal @judge_run.judge_evaluations.find_by!(rank: 1).translation_run,
                 @judge_run.winner_translation_run
    assert_equal @judge_run.winner_translation_run,
                 @judge_round.winner_translation_run
    assert_equal "judge-response-123", @judge_run.provider_response_id
    assert_equal "judge/resolved", @judge_run.resolved_model_identifier
    assert_equal 300, @judge_run.total_tokens
    assert_equal BigDecimal("0.003456789"), @judge_run.cost
    assert_equal [ 1, 2 ], @judge_run.judge_evaluations.order(:rank).pluck(:rank)
    assert_equal [ 1, 2 ], @judge_round.aggregate_rankings.map { |item| item["aggregate_rank"] }
  end

  test "sends a blind structured request with no candidate metadata" do
    captured = nil
    client = Object.new
    result = build_result(valid_content)
    client.define_singleton_method(:judge_completion) do |**arguments|
      captured = arguments
      result
    end

    with_client(client) { JudgeRunJob.perform_now(@judge_run.id) }

    assert_equal @judge.model_identifier, captured.fetch(:model_identifier)
    messages = captured.values_at(:system_prompt, :user_prompt).join("\n")
    @review_round.experiment.translation_runs.each do |translation_run|
      model = translation_run.llm_model
      assert_not_includes messages, model.provider
      assert_not_includes messages, model.model_identifier
      assert_not_includes messages, model.display_name
      assert_not_includes messages, translation_run.provider_response_id.to_s if translation_run.provider_response_id
    end
    assert_includes messages, "Candidate A"
    assert_includes messages, "Reviewer A"
    assert_equal false, captured.dig(:response_schema, :additionalProperties)
  end

  test "invalid successful output retries without partial ranking persistence" do
    partial = JSON.generate(
      rankings: [ valid_ranking("Candidate A", 1, 90) ],
      winner_label: "Candidate A",
      winner_rationale: "Best",
      confidence_score: 90
    )

    assert_enqueued_with(job: JudgeRunJob, args: [ @judge_run.id ]) do
      with_client(client_returning(partial)) do
        JudgeRunJob.perform_now(@judge_run.id)
      end
    end

    assert @judge_run.reload.running?
    assert_empty @judge_run.judge_evaluations.where.not(rank: nil)
    assert_nil @judge_run.winner_translation_run
    assert @judge_round.reload.running?
  end

  test "retries transient failures and sanitizes permanent failures" do
    retrying = Object.new
    retrying.define_singleton_method(:judge_completion) do |**|
      raise Ai::OpenRouterClient::RetryableError.new("Busy", code: "busy")
    end
    assert_enqueued_with(job: JudgeRunJob, args: [ @judge_run.id ]) do
      with_client(retrying) { JudgeRunJob.perform_now(@judge_run.id) }
    end
    assert @judge_run.reload.running?

    @judge_run.update_column(:status, "pending")
    failing = Object.new
    failing.define_singleton_method(:judge_completion) do |**|
      raise Ai::OpenRouterClient::PermanentError.new(
        "Bearer judge-secret <script>bad</script>",
        code: "rejected"
      )
    end
    with_client(failing) { JudgeRunJob.perform_now(@judge_run.id) }

    assert @judge_run.reload.failed?
    assert @judge_round.reload.failed?
    assert_equal "rejected", @judge_run.error_code
    assert_includes @judge_run.error_message, "[FILTERED]"
    assert_not_includes @judge_run.error_message, "judge-secret"
    assert_nil @judge_round.winner_translation_run
  end

  test "retry exhaustion persists a sanitized failure and stops scheduling retries" do
    exhausted_client = Object.new
    exhausted_client.define_singleton_method(:judge_completion) do |**|
      raise Ai::OpenRouterClient::RetryableError.new(
        "Bearer exhausted-retry-secret <script>unsafe</script>",
        code: "provider_busy"
      )
    end

    assert_performed_jobs 5, only: JudgeRunJob do
      with_client(exhausted_client) do
        JudgeRunJob.perform_later(@judge_run.id)
      end
    end

    @judge_run.reload
    @judge_round.reload
    assert @judge_run.failed?
    assert_not_nil @judge_run.completed_at
    assert_equal "provider_busy", @judge_run.error_code
    assert_includes @judge_run.error_message, "[FILTERED]"
    assert_not_includes @judge_run.error_message, "exhausted-retry-secret"
    assert @judge_round.failed?
    assert_nil @judge_round.winner_translation_run
    assert_empty @judge_round.aggregate_rankings
    assert_no_enqueued_jobs only: JudgeRunJob
  end

  test "skips duplicate running delivery" do
    @judge_run.update!(status: :running, started_at: Time.current)
    client, calls = counting_client

    with_client(client) { JudgeRunJob.perform_now(@judge_run.id) }

    assert_equal 0, calls.call
    assert @judge_run.reload.running?
  end

  test "terminal redelivery repairs stale aggregate without a provider call" do
    complete_judge_run(@judge_run)
    @judge_round.update_column(:status, "running")
    client, calls = counting_client

    with_client(client) { JudgeRunJob.perform_now(@judge_run.id) }

    assert_equal 0, calls.call
    assert @judge_round.reload.completed?
    assert_equal @judge_run.winner_translation_run,
                 @judge_round.winner_translation_run
  end

  test "mixed successful and failed judges preserve success but have no official winner" do
    second_judge = create_judge_model
    second_run = @judge_round.judge_runs.create!(judge_llm_model: second_judge)
    @judge_run.judge_evaluations.each do |evaluation|
      second_run.judge_evaluations.create!(
        translation_run: evaluation.translation_run,
        anonymous_label: evaluation.anonymous_label
      )
    end
    complete_judge_run(@judge_run)
    second_run.update!(
      status: :failed,
      completed_at: Time.current,
      error_code: "failed",
      error_message: "Judge failed"
    )
    @judge_round.update_column(:status, "running")
    client, calls = counting_client

    with_client(client) { JudgeRunJob.perform_now(@judge_run.id) }

    assert_equal 0, calls.call
    assert @judge_run.reload.completed?
    assert second_run.reload.failed?
    assert @judge_round.reload.failed?
    assert_nil @judge_round.winner_translation_run
    assert_empty @judge_round.aggregate_rankings
  end

  test "unexpected errors propagate" do
    client = Object.new
    client.define_singleton_method(:judge_completion) do |**|
      raise ActiveRecord::StatementInvalid, "SQL failed"
    end
    error = assert_raises ActiveRecord::StatementInvalid do
      with_client(client) { JudgeRunJob.perform_now(@judge_run.id) }
    end

    assert_equal "SQL failed", error.message
    assert @judge_run.reload.running?
  end

  private

  def with_client(client)
    original = JudgeRunJob.client_factory
    JudgeRunJob.client_factory = -> { client }
    yield
  ensure
    JudgeRunJob.client_factory = original
  end

  def client_returning(content)
    result = build_result(content)
    Object.new.tap do |client|
      client.define_singleton_method(:judge_completion) { |**| result }
    end
  end

  def build_result(content)
    Ai::OpenRouterClient::Result.new(
      content: content,
      provider_response_id: "judge-response-123",
      resolved_model_identifier: "judge/resolved",
      prompt_tokens: 200,
      completion_tokens: 100,
      total_tokens: 300,
      cached_tokens: 20,
      reasoning_tokens: 4,
      cost: BigDecimal("0.003456789")
    )
  end

  def valid_content
    labels = @judge_run.judge_evaluations.order(:anonymous_label).pluck(:anonymous_label)
    JSON.generate(
      rankings: labels.each_with_index.map do |label, index|
        valid_ranking(label, index + 1, 90 - (index * 10))
      end,
      winner_label: labels.first,
      winner_rationale: "Best overall translation.",
      confidence_score: 91
    )
  end

  def valid_ranking(label, rank, score)
    {
      candidate_label: label,
      rank: rank,
      overall_score: score,
      rationale: "Concise rationale",
      strengths: "Clear strengths",
      risks: "Limited risks"
    }
  end

  def counting_client
    calls = 0
    client = Object.new
    client.define_singleton_method(:judge_completion) do |**|
      calls += 1
      raise "Provider must not be called"
    end
    [ client, -> { calls } ]
  end
end
