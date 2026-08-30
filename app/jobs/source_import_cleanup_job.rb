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
    result
  end
end
