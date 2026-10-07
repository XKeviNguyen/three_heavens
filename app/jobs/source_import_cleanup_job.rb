class SourceImportCleanupJob < ApplicationJob
  queue_as :operations

  def perform(after: nil, cutoff: Time.current.iso8601(6))
    result = SourceImports::Cleanup.call(after:, cutoff: Time.iso8601(cutoff))
    Operations::EventLogger.emit(
      "source_import_cleanup_completed",
      active_job_id: job_id,
      outcome: "success",
      count: result.purged_count
    )
    Operations::EventLogger.emit("source_import_retirement_cleanup_completed", active_job_id: job_id,
      outcome: "success", count: result.retirements_purged_count)
    # Move past even a completely locked batch; never restart this sweep.
    if result.more_imports || result.retirements_purged_count == SourceImports::Limits::CLEANUP_BATCH_SIZE
      self.class.perform_later(after: result.cursor, cutoff:)
    end
    result
  end
end
