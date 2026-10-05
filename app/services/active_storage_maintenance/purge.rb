module ActiveStorageMaintenance
  # Keep the discoverable blob until its objects have been removed. Deleting
  # the database row first loses the only retry identity on outage or death.
  class Purge
    def self.call(blob:)
      ActiveStorage::Blob.transaction(requires_new: true) do
        current = ActiveStorage::Blob.lock.find_by(id: blob.id)
        next false unless current && ActiveRecord::Base.uncached { current.attachments.none? }

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
