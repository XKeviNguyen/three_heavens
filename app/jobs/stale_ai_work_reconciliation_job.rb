class StaleAiWorkReconciliationJob < ApplicationJob
  queue_as :operations

  def perform
    result = Ai::StaleExecutionReconciler.call
    Operations::EventLogger.emit(
      "stale_reconciliation_completed",
      active_job_id: job_id,
      outcome: "success",
      count: result.total
    )
    result
  end
end
