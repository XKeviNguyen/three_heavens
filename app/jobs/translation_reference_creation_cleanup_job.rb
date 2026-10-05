class TranslationReferenceCreationCleanupJob < ApplicationJob
  queue_as :operations

  def perform(after: nil, cutoff: Time.current.iso8601(6))
    expired = TranslationReferenceCreation.expire_failures
    batch = TranslationReferenceCreation.purge_batch(after:, at: Time.iso8601(cutoff))
    purged = batch.fetch(:purged)
    Operations::EventLogger.emit("reference_recovery_cleanup_completed", active_job_id: job_id,
      outcome: "success", count: expired)
    Operations::EventLogger.emit("reference_identity_cleanup_completed", active_job_id: job_id,
      outcome: "success", count: purged)
    # A partial purge may still have scanned a full batch with live actions.
    # Continue while making progress; stop rather than spin on held locks.
    self.class.perform_later(after: batch.fetch(:cursor), cutoff:) if expired == 100 || batch.fetch(:more)
    { expired:, purged: }
  end
end
