class JudgeRunJob < ApplicationJob
  queue_as :default
  self.enqueue_after_transaction_commit = true

  class_attribute :client_factory,
                  instance_writer: false,
                  default: -> { Ai::OpenRouterClient.new }

  retry_on Ai::OpenRouterClient::RetryableError,
           wait: :polynomially_longer,
           attempts: 5 do |job, error|
    job.send(:persist_failure_by_id, error)
  end

  def perform(judge_run_id)
    judge_run = JudgeRun.find(judge_run_id)
    claim_result = claim(judge_run)

    if claim_result == :terminal
      Judging::ReconcileRound.call(judge_run.judge_round)
      return
    end
    return if claim_result == :duplicate_running

    prompt = Judging::Prompt.build(judge_run)
    result = client_for(judge_run.judge_llm_model).judge_completion(
      model_identifier: judge_run.judge_llm_model.model_identifier,
      **prompt
    )
    evaluation = Judging::ResponseValidator.call(
      content: result.content,
      expected_labels: judge_run.judge_evaluations.pluck(:anonymous_label)
    )

    persist_success(judge_run, result, evaluation)
  rescue Ai::OpenRouterClient::RetryableError
    raise
  rescue Ai::OpenRouterClient::PermanentError => error
    persist_failure(judge_run, error) if judge_run
  end

  private

  def claim(judge_run)
    judge_run.with_lock do
      return :terminal if judge_run.terminal?
      return :duplicate_running if judge_run.running? && executions <= 1

      judge_run.update!(
        status: :running,
        started_at: judge_run.started_at || Time.current,
        completed_at: nil,
        error_code: nil,
        error_message: nil
      )
    end

    :claimed
  end

  def client_for(llm_model)
    unless llm_model.gateway == "openrouter"
      raise Ai::OpenRouterClient::PermanentError.new(
        "Unsupported AI gateway: #{llm_model.gateway}",
        code: "unsupported_gateway"
      )
    end

    client_factory.call
  end

  def persist_success(judge_run, result, evaluation)
    JudgeRun.transaction do
      judge_run.lock!
      return if judge_run.terminal?

      stored_by_label = judge_run.judge_evaluations.lock.index_by(&:anonymous_label)
      evaluation.fetch("rankings").each do |ranking|
        label = ranking.fetch("candidate_label")
        stored_by_label.fetch(label).update!(ranking.except("candidate_label"))
      end
      winner = stored_by_label.fetch(evaluation.fetch("winner_label"))
      judge_run.update!(
        status: :completed,
        winner_translation_run_id: winner.translation_run_id,
        winner_rationale: evaluation.fetch("winner_rationale"),
        confidence_score: evaluation.fetch("confidence_score"),
        provider_response_id: result.provider_response_id,
        resolved_model_identifier: result.resolved_model_identifier,
        prompt_tokens: result.prompt_tokens,
        completion_tokens: result.completion_tokens,
        total_tokens: result.total_tokens,
        cached_tokens: result.cached_tokens,
        reasoning_tokens: result.reasoning_tokens,
        cost: result.cost,
        completed_at: Time.current,
        error_code: nil,
        error_message: nil
      )
    end

    Judging::ReconcileRound.call(judge_run.judge_round)
  end

  def persist_failure_by_id(error)
    judge_run = JudgeRun.find_by(id: arguments.first)
    persist_failure(judge_run, error) if judge_run
  end

  def persist_failure(judge_run, error)
    judge_run.with_lock do
      return if judge_run.completed?

      judge_run.update!(
        status: :failed,
        completed_at: Time.current,
        error_code: error.code.to_s.first(255),
        error_message: Ai::ErrorSanitizer.call(error.message)
      )
    end

    Judging::ReconcileRound.call(judge_run.judge_round)
  end
end
