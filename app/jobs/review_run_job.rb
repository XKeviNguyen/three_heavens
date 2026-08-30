class ReviewRunJob < ApplicationJob
  include Ai::RetryEnqueueGuard

  queue_as :default
  self.enqueue_after_transaction_commit = true
  self.ai_run_class = ReviewRun

  class_attribute :client_factory,
                  instance_writer: false,
                  default: -> { Ai::OpenRouterClient.new }

  retry_on Ai::OpenRouterClient::RetryableError,
           wait: :polynomially_longer,
           attempts: 5 do |job, error|
    job.send(:persist_failure_by_id, error, job.send(:claimed_attempt))
  end

  def perform(review_run_id)
    review_run = ReviewRun.find(review_run_id)
    claim_result = Ai::ExecutionClaim.call(
      review_run,
      active_job_id: job_id,
      active_job_execution: executions
    )

    if claim_result.state == :terminal
      BlindReviews::ReconcileRound.call(review_run.review_round)
      return
    end
    return unless claim_result.state == :claimed

    @claimed_attempt = claim_result.attempt

    prompt = BlindReviews::Prompt.build(review_run)
    budget = Ai::RunContextBudget.call(
      run: review_run,
      model: review_run.reviewer_llm_model,
      prompt: prompt,
      stage: :review,
      source_character_count: review_run.review_round.experiment.document.source_text.length
    )
    result = client_for(review_run.reviewer_llm_model).review_completion(
      model_identifier: review_run.reviewer_llm_model.model_identifier,
      **prompt,
      max_tokens: budget.reserved_output_tokens
    )
    evaluations = BlindReviews::ResponseValidator.call(
      content: result.content,
      expected_labels: review_run.review_evaluations.pluck(:anonymous_label)
    )

    persist_success(review_run, result, evaluations, @claimed_attempt)
  rescue Ai::OpenRouterClient::RetryableError
    raise
  rescue Ai::OpenRouterClient::PermanentError => error
    persist_failure(review_run, error, @claimed_attempt) if review_run
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

  def persist_success(review_run, result, evaluations, attempt)
    ReviewRun.transaction do
      review_run.lock!
      return unless review_run.running? && review_run.execution_attempt == attempt

      stored_by_label = review_run.review_evaluations.lock.index_by(&:anonymous_label)
      evaluations.each do |evaluation|
        label = evaluation.fetch("candidate_label")
        stored_by_label.fetch(label).update!(evaluation.except("candidate_label"))
      end

      review_run.update!(
        status: :completed,
        provider_response_id: result.provider_response_id,
        resolved_model_identifier: result.resolved_model_identifier,
        prompt_tokens: result.prompt_tokens,
        completion_tokens: result.completion_tokens,
        total_tokens: result.total_tokens,
        cached_tokens: result.cached_tokens,
        reasoning_tokens: result.reasoning_tokens,
        cost: result.cost,
        telemetry_complete: Ai::SegmentAggregation.telemetry_complete?([ result ]),
        completed_at: Time.current,
        error_code: nil,
        error_message: nil
      )
    end

    Ai::OperationalEvents.emit("ai_run_completed", review_run, active_job_id: job_id, status: "completed")
    BlindReviews::ReconcileRound.call(review_run.review_round)
  end

  def persist_failure_by_id(error, attempt)
    review_run = ReviewRun.find_by(id: arguments.first)
    persist_failure(review_run, error, attempt) if review_run
  end

  def persist_failure(review_run, error, attempt)
    persisted = Ai::RunResult.persist_failure(review_run, error: error, attempt: attempt)
    BlindReviews::ReconcileRound.call(review_run.review_round) if persisted
  end
end
