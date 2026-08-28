class FinalizationRunJob < ApplicationJob
  include Ai::RetryEnqueueGuard

  queue_as :default
  self.enqueue_after_transaction_commit = true
  self.ai_run_class = FinalizationRun

  class_attribute :client_factory,
                  instance_writer: false,
                  default: -> { Ai::OpenRouterClient.new }

  retry_on Ai::OpenRouterClient::RetryableError,
           wait: :polynomially_longer,
           attempts: 5 do |job, error|
    job.send(:persist_failure_by_id, error, job.send(:claimed_attempt))
  end

  def perform(finalization_run_id)
    finalization_run = FinalizationRun.find(finalization_run_id)
    claim_result = Ai::ExecutionClaim.call(
      finalization_run,
      active_job_id: job_id,
      active_job_execution: executions
    )

    if claim_result.state == :terminal
      Finalizations::ReconcileRound.call(finalization_run.finalization_round)
      return
    end
    return unless claim_result.state == :claimed

    @claimed_attempt = claim_result.attempt

    prompt = Finalizations::Prompt.build(finalization_run)
    result = client_for(finalization_run.finalizer_llm_model).finalization_completion(
      model_identifier: finalization_run.finalizer_llm_model.model_identifier,
      **prompt
    )
    proposal = Finalizations::ResponseValidator.call(content: result.content)
    persist_success(finalization_run, result, proposal, @claimed_attempt)
  rescue Ai::OpenRouterClient::RetryableError
    raise
  rescue Ai::OpenRouterClient::PermanentError => error
    persist_failure(finalization_run, error, @claimed_attempt) if finalization_run
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

  def persist_success(finalization_run, result, proposal, attempt)
    finalization_run.with_lock do
      return unless finalization_run.running? && finalization_run.execution_attempt == attempt

      finalization_run.update!(
        status: :completed,
        proposed_translation: proposal.fetch("proposed_translation"),
        change_summary: proposal.fetch("change_summary"),
        terminology_notes: proposal.fetch("terminology_notes"),
        warnings: proposal.fetch("warnings"),
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
    Finalizations::ReconcileRound.call(finalization_run.finalization_round)
  end

  def persist_failure_by_id(error, attempt)
    finalization_run = FinalizationRun.find_by(id: arguments.first)
    persist_failure(finalization_run, error, attempt) if finalization_run
  end

  def persist_failure(finalization_run, error, attempt)
    persisted = Ai::RunResult.persist_failure(finalization_run, error: error, attempt: attempt)
    Finalizations::ReconcileRound.call(finalization_run.finalization_round) if persisted
  end
end
