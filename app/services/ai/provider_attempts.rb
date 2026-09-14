module Ai
  class ProviderAttempts
    RUN_DETAILS = {
      "TranslationRun" => [ "translation", :llm_model ],
      "TranslationSegmentRun" => [ "translation", :translation_run, :llm_model ],
      "ReviewRun" => [ "review", :reviewer_llm_model ],
      "ReviewSegmentRun" => [ "review", :review_run, :reviewer_llm_model ],
      "JudgeRun" => [ "judge", :judge_llm_model ],
      "JudgeSegmentRun" => [ "judge", :judge_run, :judge_llm_model ],
      "FinalizationRun" => [ "finalization", :finalizer_llm_model ],
      "FinalizationSegmentRun" => [ "finalization", :finalization_run, :finalizer_llm_model ]
    }.freeze

    def self.start!(run:, attempt:)
      stage, model = stage_and_model(run)
      AiProviderAttempt.create!(
        provider_run: run,
        attempt_number: attempt,
        stage: stage,
        status: :running,
        gateway_snapshot: model.gateway,
        provider_snapshot: model.provider,
        model_identifier_snapshot: model.model_identifier,
        display_name_snapshot: model.display_name,
        started_at: run.last_claimed_at || Time.current
      )
    end

    def self.fail_retryable!(run:, attempt:, error:, at: Time.current)
      record = find_running(run, attempt)
      return unless record

      record.update!(
        status: :failed,
        completed_at: [ at, record.started_at ].max,
        error_code: safe_error_code(error.respond_to?(:code) ? error.code : nil)
      )
    end

    def self.sync_terminal!(run)
      return unless run.execution_attempt.to_i.positive? && run.terminal?

      record = find_running(run, run.execution_attempt)
      return unless record

      attributes = AiProviderAttempt::TOKEN_FIELDS.index_with { |field| run.public_send(field) }
      attributes.merge!(
        status: run.status,
        completed_at: [ run.completed_at || Time.current, record.started_at ].max,
        error_code: run.failed? ? safe_error_code(run.error_code) : nil,
        cost: run.cost
      )
      record.update!(attributes)
    end

    def self.safe_error_code(value)
      code = value.to_s
      safe = Operations::EventLogger::SAFE_ERROR_CODES.include?(code) || code.match?(/\A(?:http_)?[45][0-9]{2}\z/)
      safe ? code : "provider_failure"
    end

    def self.find_running(run, attempt)
      AiProviderAttempt.running.find_by(provider_run: run, attempt_number: attempt)
    end
    private_class_method :find_running

    def self.stage_and_model(run)
      stage, *path = RUN_DETAILS.fetch(run.class.name)
      model = path.reduce(run) { |record, association| record.public_send(association) }
      [ stage, model ]
    end
    private_class_method :stage_and_model
  end
end
