class TranslationSegmentRunJob < ApplicationJob
  include Ai::RetryEnqueueGuard

  queue_as :default
  self.enqueue_after_transaction_commit = true
  self.ai_run_class = TranslationSegmentRun

  class_attribute :client_factory,
                  instance_writer: false,
                  default: -> { Ai::OpenRouterClient.new }

  retry_on Ai::OpenRouterClient::RetryableError,
           wait: :polynomially_longer,
           attempts: Ai::ProviderRetryPolicy::MAX_ATTEMPTS_PER_AUTHORIZATION do |job, error|
    job.send(:persist_failure_by_id, error, job.send(:claimed_attempt))
  end

  def perform(segment_run_id)
    segment_run = TranslationSegmentRun.find(segment_run_id)
    claim = Ai::ExecutionClaim.call(segment_run, active_job_id: job_id, active_job_execution: executions)
    if claim.state == :terminal
      TranslationSegments::ReconcileRun.call(segment_run.translation_run)
      return
    end
    return unless claim.state == :claimed

    @claimed_attempt = claim.attempt
    translation_run = segment_run.translation_run
    prompt = TranslationSegments::Prompt.build(
      experiment: translation_run.experiment,
      source_text: segment_run.experiment_segment.source_text
    )
    Ai::RunContextBudget.call(
      run: segment_run,
      model: translation_run.llm_model,
      prompt: prompt,
      stage: :translation,
      source_character_count: translation_run.experiment.document.source_text.length
    )
    result = client_for(translation_run.llm_model).chat_completion(
      model_identifier: translation_run.llm_model.model_identifier,
      instruction_prompt: prompt.fetch(:system_prompt),
      source_text: prompt.fetch(:user_prompt),
      max_tokens: segment_run.reserved_output_tokens
    )
    validate_output!(result.content)
    persist_success(segment_run, result, @claimed_attempt)
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

  def validate_output!(content)
    return if content.is_a?(String) && content.present? && content.length <= TranslationSegmentRun::MAX_OUTPUT_CHARACTERS

    raise Ai::OpenRouterClient::PermanentError.new(
      "Translated segment exceeded the safe length",
      code: "translated_segment_too_large"
    )
  end

  def persist_success(segment_run, result, attempt)
    segment_run.with_lock do
      return unless segment_run.running? && segment_run.execution_attempt == attempt

      segment_run.update!(
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
        completed_at: Time.current,
        error_code: nil,
        error_message: nil
      )
    end
    Ai::OperationalEvents.emit("ai_run_completed", segment_run, active_job_id: job_id, status: "completed")
    TranslationSegments::ReconcileRun.call(segment_run.translation_run)
  end

  def persist_failure_by_id(error, attempt)
    segment_run = TranslationSegmentRun.find_by(id: arguments.first)
    persist_failure(segment_run, error, attempt) if segment_run
  end

  def persist_failure(segment_run, error, attempt)
    persisted = Ai::RunResult.persist_failure(segment_run, error: error, attempt: attempt)
    TranslationSegments::ReconcileRun.call(segment_run.translation_run) if persisted
  end
end
