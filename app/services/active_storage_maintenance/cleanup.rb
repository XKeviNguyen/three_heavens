module ActiveStorageMaintenance
  class Cleanup
    DEFAULT_AGE = 7.days
    MAX_BATCH_SIZE = 100
    Result = Data.define(:candidate_count, :purged_count)

    def self.call(cutoff: Time.current - DEFAULT_AGE, batch_size: MAX_BATCH_SIZE, execute: false)
      new(cutoff:, batch_size:, execute:).call
    end

    def initialize(cutoff:, batch_size:, execute:)
      @cutoff = cutoff
      @batch_size = [ Integer(batch_size), MAX_BATCH_SIZE ].min
      @execute = execute == true
      raise ArgumentError, "batch size must be positive" unless @batch_size.positive?
    end

    def call
      ids = candidate_ids
      return Result.new(candidate_count: ids.size, purged_count: 0) unless execute

      purged_count = ids.count { |blob_id| purge_if_still_abandoned(blob_id) }
      Result.new(candidate_count: ids.size, purged_count: purged_count)
    end

    private

    attr_reader :batch_size, :cutoff, :execute

    def candidate_ids
      ActiveStorage::Blob.unattached
        .where(created_at: ..cutoff)
        .order(:created_at, :id)
        .limit(batch_size)
        .pluck(:id)
    end

    def purge_if_still_abandoned(blob_id)
      blob = ActiveStorage::Blob.transaction do
        blob = ActiveStorage::Blob.lock.find_by(id: blob_id)
        next unless blob && blob.created_at <= cutoff && blob.attachments.none?

        blob
      end
      return false unless blob

      # Active Storage rechecks attachments while destroying the blob. Keep the
      # potentially remote service deletion outside the database transaction.
      blob.purge
      !blob.persisted?
    end
  end
end
