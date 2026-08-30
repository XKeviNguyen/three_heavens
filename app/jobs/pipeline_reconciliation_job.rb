class PipelineReconciliationJob < ApplicationJob
  queue_as :operations

  def perform(batch_size = Pipelines::Reconcile::DEFAULT_BATCH_SIZE)
    result = Pipelines::Reconcile.call(batch_size: batch_size)
    Operations::EventLogger.emit(
      "pipeline_reconciliation_completed",
      active_job_id: job_id,
      outcome: "success",
      count: result.advanced_count
    )
    result
  end
end
