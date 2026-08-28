module Ai
  class StaleExecutionReconciler
    ERROR_CODE = "stale_execution"
    ERROR_MESSAGE = "Execution stopped before completion. The owner may retry it explicitly."
    PENDING_ERROR_CODE = "stale_pending"
    PENDING_ERROR_MESSAGE = "Queued work did not begin in time. The owner may retry it explicitly."
    DEFAULT_BATCH_SIZE = 500
    RUN_CLASSES = [ TranslationRun, ReviewRun, JudgeRun, FinalizationRun ].freeze

    Result = Data.define(:running_failed_counts, :pending_failed_counts) do
      def failed_counts
        running_failed_counts.to_h do |type, running_count|
          [ type, running_count + pending_failed_counts.fetch(type, 0) ]
        end
      end

      def total
        failed_counts.values.sum
      end
    end

    def self.call(now: Time.current, batch_size: DEFAULT_BATCH_SIZE)
      cutoff = StaleExecutionPolicy.cutoff(now: now)
      running_counts = RUN_CLASSES.to_h { |run_class| [ run_class.name, 0 ] }
      pending_counts = RUN_CLASSES.to_h { |run_class| [ run_class.name, 0 ] }

      RUN_CLASSES.each do |run_class|
        stale_running_ids(run_class, cutoff, batch_size).each do |id|
          run = run_class.find_by(id: id)
          next unless run && fail_running_if_still_stale(run, cutoff, now)

          running_counts[run_class.name] += 1
          RunParentReconciler.call(run)
        end

        stale_pending_ids(run_class, cutoff, batch_size).each do |id|
          run = run_class.find_by(id: id)
          next unless run && fail_pending_if_still_stale(run, cutoff, now)

          pending_counts[run_class.name] += 1
          RunParentReconciler.call(run)
        end
      end

      Result.new(
        running_failed_counts: running_counts.freeze,
        pending_failed_counts: pending_counts.freeze
      )
    end

    def self.stale_running_ids(run_class, cutoff, batch_size)
      run_class.running.where(last_claimed_at: ..cutoff).order(:last_claimed_at, :id).limit(batch_size).pluck(:id)
    end
    private_class_method :stale_running_ids

    def self.stale_pending_ids(run_class, cutoff, batch_size)
      run_class.pending.where(pending_since: ..cutoff).order(:pending_since, :id).limit(batch_size).pluck(:id)
    end
    private_class_method :stale_pending_ids

    def self.fail_running_if_still_stale(run, cutoff, now)
      run.with_lock do
        return false unless run.running? && run.last_claimed_at && run.last_claimed_at <= cutoff

        run.update!(
          status: :failed,
          completed_at: now,
          error_code: ERROR_CODE,
          error_message: ERROR_MESSAGE
        )
      end
      true
    end
    private_class_method :fail_running_if_still_stale

    def self.fail_pending_if_still_stale(run, cutoff, now)
      run.with_lock do
        return false unless run.pending? && run.pending_since && run.pending_since <= cutoff

        run.update!(
          status: :failed,
          pending_since: nil,
          completed_at: now,
          error_code: PENDING_ERROR_CODE,
          error_message: PENDING_ERROR_MESSAGE
        )
      end
      true
    end
    private_class_method :fail_pending_if_still_stale
  end
end
