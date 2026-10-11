module Ai
  class RunScheduler
    ERROR_CODE = "enqueue_failed"
    ERROR_MESSAGE = "Work could not be queued. The owner may retry it explicitly."

    Schedule = Data.define(:job, :run_class, :run_id, :job_id)

    # billing is the Ai::BillingPolicy::Authorization this work runs under.
    # It is stamped here, the only path into pending, and never re-resolved
    # from the owner's later preferences.
    def self.prepare(run:, job_class:, billing:, now: Time.current)
      raise ArgumentError, "billing authorization is required" unless billing.is_a?(BillingPolicy::Authorization)

      job = job_class.new(run.id)
      run.update!(
        status: :pending,
        scheduled_job_id: job.job_id,
        claimed_job_execution: 0,
        pending_since: now,
        last_claimed_at: nil,
        **billing.attributes
      )

      Schedule.new(
        job: job,
        run_class: run.class,
        run_id: run.id,
        job_id: job.job_id
      )
    end

    # Whether one job was enqueued. Inside a transaction the job is enqueued
    # by the outermost commit callback, so the outcome reads as accepted until
    # that callback reports; read after the commit, it is the actual result.
    # With no open transaction, Rails runs the callback at once.
    EnqueueOutcome = Struct.new(:accepted) do
      alias_method :accepted?, :accepted
    end

    def self.enqueue_all(schedules)
      enqueue_outcomes(schedules).count(&:accepted?)
    end

    def self.enqueue_outcomes(schedules)
      schedules.map do |schedule|
        outcome = EnqueueOutcome.new(true)
        ActiveRecord.after_all_transactions_commit { outcome.accepted = enqueue_now(schedule) }
        outcome
      end
    end

    def self.enqueue(schedule)
      enqueue_outcomes([ schedule ]).first.accepted?
    end

    def self.enqueue_now(schedule)
      if schedule.job.enqueue
        run = schedule.run_class.find_by(id: schedule.run_id)
        OperationalEvents.emit("ai_run_scheduled", run, status: "pending") if run
        return true
      end

      fail_pending(schedule)
      false
    rescue SolidQueue::Job::EnqueueError
      fail_pending(schedule)
      false
    end
    private_class_method :enqueue_now

    def self.fail_running(run_class:, run_id:, attempt:)
      run = run_class.find_by(id: run_id)
      return false unless run && attempt

      changed = run.with_lock do
        next false unless run.running? && run.execution_attempt == attempt

        run.update!(failure_attributes)
        true
      end
      RunParentReconciler.call(run) if changed
      changed
    end

    def self.fail_pending(schedule)
      run = schedule.run_class.find_by(id: schedule.run_id)
      return false unless run

      changed = run.with_lock do
        next false unless run.pending? && run.scheduled_job_id == schedule.job_id

        run.update!(failure_attributes)
        true
      end
      RunParentReconciler.call(run) if changed
      changed
    end
    private_class_method :fail_pending

    def self.failure_attributes
      {
        status: :failed,
        pending_since: nil,
        completed_at: Time.current,
        error_code: ERROR_CODE,
        error_message: ERROR_MESSAGE
      }
    end
    private_class_method :failure_attributes
  end
end
