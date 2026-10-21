module Ai
  class RunResult
    def self.persist_failure(run, error:, attempt:)
      return false unless attempt

      persisted = run.with_lock do
        return false unless current_execution?(run, attempt)

        run.update!(
          status: :failed,
          completed_at: Time.current,
          error_code: error.code.to_s.first(255),
          error_message: ErrorSanitizer.call(error.message),
          **failure_usage(error)
        )
      end
      OperationalEvents.emit(
        "ai_run_failed",
        run,
        status: "failed",
        error_code: safe_error_code(run.error_code)
      ) if persisted
      true
    end

    # Tokens and cost of this attempt only: a billed but incomplete response
    # keeps its usage, and any other failure clears what an earlier attempt
    # left, so the attempt ledger never counts one request twice.
    def self.failure_usage(error)
      usage = error.respond_to?(:usage) ? error.usage : nil
      Ai::OpenRouterClient::Usage.members.index_with { |field| usage&.public_send(field) }
    end
    private_class_method :failure_usage

    def self.current_execution?(run, attempt)
      run.running? && run.execution_attempt == attempt
    end
    private_class_method :current_execution?

    def self.safe_error_code(value)
      code = value.to_s
      safe = Operations::EventLogger::SAFE_ERROR_CODES.include?(code) || code.match?(/\A(?:http_)?[45][0-9]{2}\z/)
      safe ? code : "provider_failure"
    end
  end
end
