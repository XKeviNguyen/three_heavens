module Ai
  class ExecutionClaim
    # credential is the in-memory key for this claimed execution only; it is
    # never persisted or passed to another job.
    Result = Data.define(:state, :attempt, :credential) do
      def initialize(state:, attempt: nil, credential: nil)
        super
      end
    end

    # Each execution (first run and every provider retry) re-resolves the
    # run's stamped payment authorization while holding the owner's row lock,
    # which key and preference changes also take. A key revoked or replaced
    # before this point fails the run closed; a request already sent with the
    # previous key completes and is kept, since its owner already paid for it.
    def self.call(run, active_job_id:, active_job_execution:)
      user = ManagedAccess.user_for(run)
      credential = nil
      result = user.with_lock do
        run.with_lock do
          return Result.new(state: :terminal) if run.terminal?
          return Result.new(state: :obsolete) unless run.scheduled_job_id == active_job_id
          return Result.new(state: :obsolete) unless run.pending? || run.running?

          if run.pending?
            return Result.new(state: :obsolete) unless active_job_execution == 1
          elsif active_job_execution <= run.claimed_job_execution
            return Result.new(state: :duplicate_running)
          end

          begin
            credential = BillingPolicy.credential_for!(run, user)
          rescue BillingPolicy::Denied => denial
            run.update!(
              status: :failed,
              completed_at: Time.current,
              error_code: denial.code,
              error_message: denial.message
            )
            next Result.new(state: :denied)
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
          Result.new(state: :claimed, attempt: attempt, credential: credential)
        end
      end
      if result.state == :denied
        OperationalEvents.emit("ai_run_failed", run, status: "failed", error_code: run.error_code)
        return Result.new(state: :terminal)
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
