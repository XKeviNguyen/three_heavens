module Pipelines
  class AdvancementScheduler
    def self.enqueue_for(experiment)
      pipeline_run_id = experiment.pipeline_run&.id
      return false unless pipeline_run_id

      ActiveRecord.after_all_transactions_commit do
        begin
          PipelineAdvanceJob.perform_later(pipeline_run_id)
        rescue SolidQueue::Job::EnqueueError
          # The bounded recurring reconciler repairs this missed advancement.
        end
      end
      true
    end
  end
end
