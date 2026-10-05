module TranslationWorkspaceSubmissions
  class Cleanup
    Result = Data.define(:purged_count)

    def self.call(cutoff: Time.current, batch_size: TranslationWorkspaceSubmission::CLEANUP_BATCH_SIZE)
      limit = [ Integer(batch_size), TranslationWorkspaceSubmission::CLEANUP_BATCH_SIZE ].min
      raise ArgumentError, "batch size must be positive" unless limit.positive?

      purged_count = 0
      TranslationWorkspaceSubmission.transaction do
        ids = TranslationWorkspaceSubmission.expired_available(cutoff).order(:expires_at, :id).limit(limit)
          .lock("FOR UPDATE SKIP LOCKED").pluck(:id)
        purged_count = TranslationWorkspaceSubmission.where(id: ids, status: "available").delete_all
      end
      Result.new(purged_count: purged_count)
    end
  end
end
