class JudgeRunJob < ApplicationJob
  include Ai::RetryEnqueueGuard

  queue_as :default
  self.enqueue_after_transaction_commit = true
  self.ai_run_class = JudgeRun

  class_attribute :client_factory,
                  instance_writer: false,
                  default: -> { Ai::OpenRouterClient.new }

  retry_on Ai::OpenRouterClient::RetryableError,
           wait: :polynomially_longer,
           attempts: 5 do |job, error|
    job.send(:persist_failure_by_id, error, job.send(:claimed_attempt))
  end

  def perform(judge_run_id)
    judge_run = JudgeRun.find(judge_run_id)
    claim_result = Ai::ExecutionClaim.call(
      judge_run,
      active_job_id: job_id,
      active_job_execution: executions
    )

    if claim_result.state == :terminal
      Judging::ReconcileRound.call(judge_run.judge_round)
      return
    end
    return unless claim_result.state == :claimed

    @claimed_attempt = claim_result.attempt

    prompt = Judging::Prompt.build(judge_run)
    budget = Ai::RunContextBudget.call(
      run: judge_run,
      model: judge_run.judge_llm_model,
      prompt: prompt,
      stage: :judge,
      source_character_count: judge_run.judge_round.experiment.document.source_text.length
    )
    result = client_for(judge_run.judge_llm_model).judge_completion(
      model_identifier: judge_run.judge_llm_model.model_identifier,
      **prompt,
      max_tokens: budget.reserved_output_tokens
    )
    evaluation = Judging::ResponseValidator.call(
      content: result.content,
      expected_labels: judge_run.judge_evaluations.pluck(:anonymous_label)
    )

    persist_success(judge_run, result, evaluation, @claimed_attempt)
  rescue Ai::OpenRouterClient::RetryableError
    raise
  rescue Ai::OpenRouterClient::PermanentError => error
    persist_failure(judge_run, error, @claimed_attempt) if judge_run
  end

  private

  def claimed_attempt
    @claimed_attempt
  end

  def client_for(llm_model)
    unless llm_model.active? && llm_model.gateway == "openrouter"
      raise Ai::OpenRouterClient::PermanentError.new(
        "The historical model is inactive or unsupported",
        code: "model_unavailable"
      )
    end

    client_factory.call
  end

  def persist_success(judge_run, result, evaluation, attempt)
    JudgeRun.transaction do
      judge_run.lock!
      return unless judge_run.running? && judge_run.execution_attempt == attempt

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
        cost_complete: !result.cost.nil?,
        telemetry_complete: Ai::SegmentAggregation.telemetry_complete?([ result ]),
        completed_at: Time.current,
        error_code: nil,
        error_message: nil
      )
    end

    Ai::OperationalEvents.emit("ai_run_completed", judge_run, active_job_id: job_id, status: "completed")
    Judging::ReconcileRound.call(judge_run.judge_round)
  end

  def persist_failure_by_id(error, attempt)
    judge_run = JudgeRun.find_by(id: arguments.first)
    persist_failure(judge_run, error, attempt) if judge_run
  end

  def persist_failure(judge_run, error, attempt)
    persisted = Ai::RunResult.persist_failure(judge_run, error: error, attempt: attempt)
    Judging::ReconcileRound.call(judge_run.judge_round) if persisted
  end
end
