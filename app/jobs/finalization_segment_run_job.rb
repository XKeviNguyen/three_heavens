class FinalizationSegmentRunJob < ApplicationJob
  include Ai::RetryEnqueueGuard

  queue_as :default
  self.enqueue_after_transaction_commit = true
  self.ai_run_class = FinalizationSegmentRun

  class_attribute :client_factory,
                  instance_writer: false,
                  default: -> { Ai::OpenRouterClient.new }

  retry_on Ai::OpenRouterClient::RetryableError,
           wait: :polynomially_longer,
           attempts: Ai::ProviderRetryPolicy::MAX_ATTEMPTS_PER_AUTHORIZATION do |job, error|
    job.send(:persist_failure_by_id, error, job.send(:claimed_attempt))
  end

  def perform(segment_run_id)
    segment_run = FinalizationSegmentRun.find(segment_run_id)
    claim = Ai::ExecutionClaim.call(segment_run, active_job_id: job_id, active_job_execution: executions)
    if claim.state == :terminal
      FinalizationSegments::ReconcileRun.call(segment_run.finalization_run)
      return
    end
    return unless claim.state == :claimed

    @claimed_attempt = claim.attempt
    finalization_run = segment_run.finalization_run
    prompt = Finalizations::Prompt.build(finalization_run, experiment_segment: segment_run.experiment_segment)
    Ai::RunContextBudget.call(
      run: segment_run,
      model: finalization_run.finalizer_llm_model,
      prompt: prompt,
      stage: :finalization,
      source_character_count: finalization_run.finalization_round.final_translation.experiment.document.source_text.length
    )
    result = client_for(finalization_run.finalizer_llm_model).finalization_completion(
      model_identifier: finalization_run.finalizer_llm_model.model_identifier,
      **prompt,
      max_tokens: segment_run.reserved_output_tokens
    )
    proposal = Finalizations::ResponseValidator.call(
      content: result.content,
      max_translation_length: FinalizationSegmentRun::MAX_OUTPUT_CHARACTERS
    )
    persist_success(segment_run, result, proposal, @claimed_attempt)
  rescue Ai::OpenRouterClient::RetryableError
    raise
  rescue Ai::OpenRouterClient::PermanentError => error
    persist_failure(segment_run, error, @claimed_attempt) if segment_run
  end

  private

  def claimed_attempt
    @claimed_attempt
  end

  def client_for(model)
    unless model.active? && model.gateway == "openrouter"
      raise Ai::OpenRouterClient::PermanentError.new(
        "The historical model is inactive or unsupported",
        code: "model_unavailable"
      )
    end
    client_factory.call
  end

  def persist_success(segment_run, result, proposal, attempt)
    segment_run.with_lock do
      return unless segment_run.running? && segment_run.execution_attempt == attempt

      segment_run.update!(
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
    Ai::OperationalEvents.emit("ai_run_completed", segment_run, active_job_id: job_id, status: "completed")
    FinalizationSegments::ReconcileRun.call(segment_run.finalization_run)
  end

  def persist_failure_by_id(error, attempt)
    segment_run = FinalizationSegmentRun.find_by(id: arguments.first)
    persist_failure(segment_run, error, attempt) if segment_run
  end

  def persist_failure(segment_run, error, attempt)
    persisted = Ai::RunResult.persist_failure(segment_run, error: error, attempt: attempt)
    FinalizationSegments::ReconcileRun.call(segment_run.finalization_run) if persisted
  end
end
