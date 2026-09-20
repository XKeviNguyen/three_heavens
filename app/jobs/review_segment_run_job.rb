class ReviewSegmentRunJob < ApplicationJob
  include Ai::RetryEnqueueGuard

  queue_as :default
  self.enqueue_after_transaction_commit = true
  self.ai_run_class = ReviewSegmentRun

  class_attribute :client_factory,
                  instance_writer: false,
                  default: -> { Ai::OpenRouterClient.new }

  retry_on Ai::OpenRouterClient::RetryableError,
           wait: :polynomially_longer,
           attempts: Ai::ProviderRetryPolicy::MAX_ATTEMPTS_PER_AUTHORIZATION do |job, error|
    job.send(:persist_failure_by_id, error, job.send(:claimed_attempt))
  end

  def perform(segment_run_id)
    segment_run = ReviewSegmentRun.find(segment_run_id)
    claim = Ai::ExecutionClaim.call(segment_run, active_job_id: job_id, active_job_execution: executions)
    if claim.state == :terminal
      ReviewSegments::ReconcileRun.call(segment_run.review_run)
      return
    end
    return unless claim.state == :claimed

    @claimed_attempt = claim.attempt
    review_run = segment_run.review_run
    prompt = BlindReviews::Prompt.build(review_run, experiment_segment: segment_run.experiment_segment)
    Ai::RunContextBudget.call(
      run: segment_run,
      model: review_run.reviewer_llm_model,
      prompt: prompt,
      stage: :review,
      source_character_count: review_run.review_round.experiment.document.source_text.length
    )
    result = client_for(review_run.reviewer_llm_model).review_completion(
      model_identifier: review_run.reviewer_llm_model.model_identifier,
      **prompt,
      max_tokens: segment_run.reserved_output_tokens
    )
    evaluations = BlindReviews::ResponseValidator.call(
      content: result.content,
      expected_labels: review_run.review_evaluations.pluck(:anonymous_label),
      max_suggestion_length: TranslationSegmentRun::MAX_OUTPUT_CHARACTERS
    )
    persist_success(segment_run, result, evaluations, @claimed_attempt)
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

  def persist_success(segment_run, result, evaluations, attempt)
    segment_run.with_lock do
      return unless segment_run.running? && segment_run.execution_attempt == attempt

      segment_run.update!(
        status: :completed,
        evaluations: evaluations,
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
    ReviewSegments::ReconcileRun.call(segment_run.review_run)
  end

  def persist_failure_by_id(error, attempt)
    segment_run = ReviewSegmentRun.find_by(id: arguments.first)
    persist_failure(segment_run, error, attempt) if segment_run
  end

  def persist_failure(segment_run, error, attempt)
    persisted = Ai::RunResult.persist_failure(segment_run, error: error, attempt: attempt)
    ReviewSegments::ReconcileRun.call(segment_run.review_run) if persisted
  end
end
