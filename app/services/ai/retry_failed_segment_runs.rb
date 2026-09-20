module Ai
  class RetryFailedSegmentRuns
    def self.call(parent:, logical_runs_association:, child_runs_association:, model_association:, job_class:,
                  prepare_parent:, prepare_logical:, prepare_child:, lock_before: nil)
      logical_runs = []
      child_runs = []
      schedules = []

      parent.class.transaction do
        lock_before&.lock!
        parent.lock!
        logical_runs = parent.public_send(logical_runs_association).lock.select(&:failed?)
        child_runs = logical_runs.flat_map do |logical_run|
          logical_run.public_send(child_runs_association).lock.select(&:failed?)
        end
        next if child_runs.empty?

        RetryFailedRuns.send(:validate_models!, logical_runs, model_association)
        prepare_parent.call(parent, logical_runs)
        logical_runs.each do |logical_run|
          prepare_logical.call(logical_run)
          logical_run.update!(RetryFailedRuns.retry_attributes(logical_run).merge(status: :running))
        end
        child_runs.each do |child_run|
          prepare_child.call(child_run)
          child_run.update!(RetryFailedRuns.retry_attributes(child_run))
          schedules << RunScheduler.prepare(run: child_run, job_class: job_class)
        end
      end

      enqueued_count = RunScheduler.enqueue_all(schedules)
      RetryFailedRuns::Result.new(retried_count: child_runs.size, enqueued_count: enqueued_count)
    end
  end
end
