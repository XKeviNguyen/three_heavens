class ActiveStorageCleanupJob < ApplicationJob
  queue_as :operations

  def perform
    result = ActiveStorageMaintenance::Cleanup.call(execute: true)
    self.class.perform_later if result.candidate_count == ActiveStorageMaintenance::Cleanup::MAX_BATCH_SIZE
    Operations::EventLogger.emit(
      "active_storage_cleanup_completed",
      active_job_id: job_id,
      outcome: "success",
      count: result.purged_count
    )
    result
  end
end
