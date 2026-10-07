module ActiveStorageMaintenance
  # Keep the discoverable blob until its objects have been removed. Deleting
  # the database row first loses the only retry identity on outage or death.
  class Purge
    def self.call(blob:, cutoff: nil, skip_locked: false)
      ActiveStorage::Blob.transaction(requires_new: true) do
        current = ActiveStorage::Blob.lock(skip_locked ? "FOR UPDATE SKIP LOCKED" : true).find_by(id: blob.id)
        next false unless current && ActiveRecord::Base.uncached { current.attachments.none? }
        next false if cutoff && current.created_at > cutoff

        begin
          current.service
        rescue KeyError
          Rails.logger.error("active_storage_purge_failed blob_id=#{current.id} error=UnavailableService")
          next false
        end

        # Attachment inserts also need the blob's FK lock: they cannot attach
        # between this check and deletion, including from another process.
        current.delete
        current.destroy!
        true
      end
    rescue IOError, SystemCallError => error
      Rails.logger.error("active_storage_purge_failed blob_id=#{blob.id} error=#{error.class}")
      false
    end
  end
end
