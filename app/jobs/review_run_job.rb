class ReviewRunJob < ApplicationJob
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

  def perform(review_run_id)
    review_run = ReviewRun.find(review_run_id)
    claim_result = claim(review_run)

    if claim_result == :terminal
      BlindReviews::ReconcileRound.call(review_run.review_round)
      return
    end
    return if claim_result == :duplicate_running

    prompt = BlindReviews::Prompt.build(review_run)
    result = client_for(review_run.reviewer_llm_model).review_completion(
      model_identifier: review_run.reviewer_llm_model.model_identifier,
      **prompt
    )
    evaluations = BlindReviews::ResponseValidator.call(
      content: result.content,
      expected_labels: review_run.review_evaluations.pluck(:anonymous_label)
    )

    persist_success(review_run, result, evaluations)
  rescue Ai::OpenRouterClient::RetryableError
    raise
  rescue Ai::OpenRouterClient::PermanentError => error
    persist_failure(review_run, error) if review_run
  end

  private

  def claim(review_run)
    review_run.with_lock do
      return :terminal if review_run.terminal?
      return :duplicate_running if review_run.running? && executions <= 1

      review_run.update!(
        status: :running,
        started_at: review_run.started_at || Time.current,
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

  def persist_success(review_run, result, evaluations)
    ReviewRun.transaction do
      review_run.lock!
      return if review_run.terminal?

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
        completed_at: Time.current,
        error_code: nil,
        error_message: nil
      )
    end

    BlindReviews::ReconcileRound.call(review_run.review_round)
  end

  def persist_failure_by_id(error)
    review_run = ReviewRun.find_by(id: arguments.first)
    persist_failure(review_run, error) if review_run
  end

  def persist_failure(review_run, error)
    review_run.with_lock do
      return if review_run.completed?

      review_run.update!(
        status: :failed,
        completed_at: Time.current,
        error_code: error.code.to_s.first(255),
        error_message: Ai::ErrorSanitizer.call(error.message)
      )
    end

    BlindReviews::ReconcileRound.call(review_run.review_round)
  end
end
