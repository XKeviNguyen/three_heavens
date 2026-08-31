class TranslationRunJob < ApplicationJob
  include Ai::RetryEnqueueGuard

  queue_as :default
  self.enqueue_after_transaction_commit = true
  self.ai_run_class = TranslationRun

  class_attribute :client_factory,
                  instance_writer: false,
                  default: -> { Ai::OpenRouterClient.new }

  retry_on Ai::OpenRouterClient::RetryableError,
           wait: :polynomially_longer,
           attempts: 5 do |job, error|
    job.send(:persist_failure_by_id, error, job.send(:claimed_attempt))
  end

  def perform(translation_run_id)
    translation_run = TranslationRun.find(translation_run_id)
    claim = Ai::ExecutionClaim.call(
      translation_run,
      active_job_id: job_id,
      active_job_execution: executions
    )
    if claim.state == :terminal
      TranslationExperiments::ReconcileExperiment.call(translation_run.experiment)
      return
    end
    return unless claim.state == :claimed

    @claimed_attempt = claim.attempt

    prompt = TranslationSegments::Prompt.build(
      experiment: translation_run.experiment,
      source_text: translation_run.experiment.document.source_text
    )
    budget = Ai::RunContextBudget.call(
      run: translation_run,
      model: translation_run.llm_model,
      prompt: prompt,
      stage: :translation,
      source_character_count: translation_run.experiment.document.source_text.length
    )

    result = client_for(translation_run.llm_model).chat_completion(
      model_identifier: translation_run.llm_model.model_identifier,
      instruction_prompt: prompt.fetch(:system_prompt),
      source_text: prompt.fetch(:user_prompt),
      max_tokens: budget.reserved_output_tokens
    )

    unless result.content.is_a?(String) && result.content.present? &&
           result.content.length <= Ai::UsageLimits::MAX_SOURCE_CHARACTERS
      raise Ai::OpenRouterClient::PermanentError.new(
        "Translation output exceeded the safe document length",
        code: "translated_document_too_large"
      )
    end

    persist_success(translation_run, result, @claimed_attempt)
  rescue Ai::OpenRouterClient::RetryableError
    raise
  rescue Ai::OpenRouterClient::PermanentError => error
    persist_failure(translation_run, error, @claimed_attempt) if translation_run
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

  def persist_success(translation_run, result, attempt)
    translation_run.with_lock do
      return unless translation_run.running? && translation_run.execution_attempt == attempt

      translation_run.update!(
        status: :completed,
        translated_text: result.content,
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

    Ai::OperationalEvents.emit("ai_run_completed", translation_run, active_job_id: job_id, status: "completed")
    TranslationExperiments::ReconcileExperiment.call(translation_run.experiment)
  end

  def persist_failure_by_id(error, attempt)
    translation_run_id = arguments.first
    translation_run = TranslationRun.find_by(id: translation_run_id)
    persist_failure(translation_run, error, attempt) if translation_run
  end

  def persist_failure(translation_run, error, attempt)
    persisted = Ai::RunResult.persist_failure(translation_run, error: error, attempt: attempt)
    TranslationExperiments::ReconcileExperiment.call(translation_run.experiment) if persisted
  end
end
