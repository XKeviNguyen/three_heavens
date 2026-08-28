module Ai
  class RunResult
    def self.persist_failure(run, error:, attempt:)
      return false unless attempt

      run.with_lock do
        return false unless current_execution?(run, attempt)

        run.update!(
          status: :failed,
          completed_at: Time.current,
          error_code: error.code.to_s.first(255),
          error_message: ErrorSanitizer.call(error.message)
        )
      end
      true
    end

    def self.current_execution?(run, attempt)
      run.running? && run.execution_attempt == attempt
    end
    private_class_method :current_execution?
  end
end
