class TranslationReferenceCreationCleanupJob < ApplicationJob
  queue_as :operations

  def perform
    expired = TranslationReferenceCreation.expire_failures
    purged = TranslationReferenceCreation.purge_expired
    Operations::EventLogger.emit("reference_recovery_cleanup_completed", active_job_id: job_id,
      outcome: "success", count: expired)
    Operations::EventLogger.emit("reference_identity_cleanup_completed", active_job_id: job_id,
      outcome: "success", count: purged)
    # A partial purge may still have scanned a full batch with live actions.
    # Continue while making progress; stop rather than spin on held locks.
    self.class.perform_later if expired == 100 || purged.positive?
    { expired:, purged: }
  end
end
