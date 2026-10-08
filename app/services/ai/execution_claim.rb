module Ai
  class ExecutionClaim
    Result = Data.define(:state, :attempt)

    def self.call(run, active_job_id:, active_job_execution:)
      user = ManagedAccess.user_for(run)
      result = user.with_lock do
        run.with_lock do
          return Result.new(state: :terminal, attempt: nil) if run.terminal?
          return Result.new(state: :obsolete, attempt: nil) unless run.scheduled_job_id == active_job_id
          return Result.new(state: :obsolete, attempt: nil) unless run.pending? || run.running?

          if run.pending?
            return Result.new(state: :obsolete, attempt: nil) unless active_job_execution == 1
          elsif active_job_execution <= run.claimed_job_execution
            return Result.new(state: :duplicate_running, attempt: nil)
          end

          unless ManagedAccess.allowed?(user)
            run.update!(
              status: :failed,
              completed_at: Time.current,
              error_code: "managed_ai_access_revoked",
              error_message: ManagedAccess::DENIED_MESSAGE
            )
            return Result.new(state: :terminal, attempt: nil)
          end

          attempt = run.execution_attempt + 1
          run.update!(
            status: :running,
            execution_attempt: attempt,
            claimed_job_execution: active_job_execution,
            pending_since: nil,
            last_claimed_at: Time.current,
            started_at: run.started_at || Time.current,
            completed_at: nil,
            error_code: nil,
            error_message: nil
          )
          Ai::ProviderAttempts.start!(run: run, attempt: attempt)
          Result.new(state: :claimed, attempt: attempt)
        end
      end
      if result.state == :claimed
        OperationalEvents.emit(
          "ai_execution_claimed",
          run,
          active_job_id: active_job_id,
          status: "running"
        )
      end
      result
    end
  end
end
