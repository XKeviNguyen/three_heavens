class SourceImportCleanupJob < ApplicationJob
  queue_as :operations

  def perform
    result = SourceImports::Cleanup.call
    Operations::EventLogger.emit(
      "source_import_cleanup_completed",
      active_job_id: job_id,
      outcome: "success",
      count: result.purged_count
    )
    Operations::EventLogger.emit("source_import_retirement_cleanup_completed", active_job_id: job_id,
      outcome: "success", count: result.retirements_purged_count)
    # Partial progress can include a candidate skipped for a live action lock.
    self.class.perform_later if result.purged_count.positive? || result.retirements_purged_count == SourceImports::Limits::CLEANUP_BATCH_SIZE
    result
  end
end
