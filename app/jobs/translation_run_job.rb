class TranslationRunJob < ApplicationJob
  queue_as :default

  class_attribute :client_factory,
                  instance_writer: false,
                  default: -> { Ai::OpenRouterClient.new }

  retry_on Ai::OpenRouterClient::RetryableError,
           wait: :polynomially_longer,
           attempts: 5 do |job, error|
    job.send(:persist_failure_by_id, error)
  end

  def perform(translation_run_id)
    translation_run = TranslationRun.find(translation_run_id)
    return unless claim(translation_run)

    result = client_for(translation_run.llm_model).chat_completion(
      model_identifier: translation_run.llm_model.model_identifier,
      instruction_prompt: translation_run.experiment.instruction_prompt,
      source_text: translation_run.experiment.document.source_text
    )

    persist_success(translation_run, result)
  rescue Ai::OpenRouterClient::RetryableError
    raise
  rescue Ai::OpenRouterClient::PermanentError => error
    persist_failure(translation_run, error) if translation_run
  end

  private

  def claim(translation_run)
    translation_run.with_lock do
      return false if translation_run.terminal?
      return false if translation_run.running? && executions <= 1

      translation_run.update!(
        status: :running,
        started_at: translation_run.started_at || Time.current,
        completed_at: nil,
        error_code: nil,
        error_message: nil
      )
    end

    true
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

  def persist_success(translation_run, result)
    translation_run.with_lock do
      return if translation_run.terminal?

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
        completed_at: Time.current,
        error_code: nil,
        error_message: nil
      )
    end

    update_experiment_status(translation_run.experiment)
  end

  def persist_failure_by_id(error)
    translation_run_id = arguments.first
    translation_run = TranslationRun.find_by(id: translation_run_id)
    persist_failure(translation_run, error) if translation_run
  end

  def persist_failure(translation_run, error)
    translation_run.with_lock do
      return if translation_run.completed?

      translation_run.update!(
        status: :failed,
        completed_at: Time.current,
        error_code: error.code.to_s.first(255),
        error_message: Ai::ErrorSanitizer.call(error.message)
      )
    end

    update_experiment_status(translation_run.experiment)
  end

  def update_experiment_status(experiment)
    experiment.with_lock do
      translation_runs = experiment.translation_runs.reload
      return if translation_runs.empty? || translation_runs.any? { |run| !run.terminal? }

      status = translation_runs.any?(&:failed?) ? :failed : :completed
      experiment.update!(status: status)
    end
  end
end
