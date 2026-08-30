class JudgeSegmentRunJob < ApplicationJob
  include Ai::RetryEnqueueGuard

  queue_as :default
  self.enqueue_after_transaction_commit = true
  self.ai_run_class = JudgeSegmentRun

  class_attribute :client_factory,
                  instance_writer: false,
                  default: -> { Ai::OpenRouterClient.new }

  retry_on Ai::OpenRouterClient::RetryableError,
           wait: :polynomially_longer,
           attempts: 5 do |job, error|
    job.send(:persist_failure_by_id, error, job.send(:claimed_attempt))
  end

  def perform(segment_run_id)
    segment_run = JudgeSegmentRun.find(segment_run_id)
    claim = Ai::ExecutionClaim.call(segment_run, active_job_id: job_id, active_job_execution: executions)
    if claim.state == :terminal
      JudgeSegments::ReconcileRun.call(segment_run.judge_run)
      return
    end
    return unless claim.state == :claimed

    @claimed_attempt = claim.attempt
    judge_run = segment_run.judge_run
    prompt = Judging::Prompt.build(judge_run, experiment_segment: segment_run.experiment_segment)
    Ai::RunContextBudget.call(
      run: segment_run,
      model: judge_run.judge_llm_model,
      prompt: prompt,
      stage: :judge,
      source_character_count: judge_run.judge_round.experiment.document.source_text.length
    )
    result = client_for(judge_run.judge_llm_model).judge_completion(
      model_identifier: judge_run.judge_llm_model.model_identifier,
      **prompt,
      max_tokens: segment_run.reserved_output_tokens
    )
    judgment = Judging::ResponseValidator.call(
      content: result.content,
      expected_labels: judge_run.judge_evaluations.pluck(:anonymous_label)
    )
    persist_success(segment_run, result, judgment, @claimed_attempt)
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

  def persist_success(segment_run, result, judgment, attempt)
    segment_run.with_lock do
      return unless segment_run.running? && segment_run.execution_attempt == attempt

      segment_run.update!(
        status: :completed,
        judgment: judgment,
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
    JudgeSegments::ReconcileRun.call(segment_run.judge_run)
  end

  def persist_failure_by_id(error, attempt)
    segment_run = JudgeSegmentRun.find_by(id: arguments.first)
    persist_failure(segment_run, error, attempt) if segment_run
  end

  def persist_failure(segment_run, error, attempt)
    persisted = Ai::RunResult.persist_failure(segment_run, error: error, attempt: attempt)
    JudgeSegments::ReconcileRun.call(segment_run.judge_run) if persisted
  end
end
