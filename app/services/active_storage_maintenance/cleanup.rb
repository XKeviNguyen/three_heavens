module ActiveStorageMaintenance
  class Cleanup
    DEFAULT_AGE = 7.days
    MAX_BATCH_SIZE = 100
    RETRY_DELAY = 1.hour
    ELIGIBILITY_SQL = "COALESCE(active_storage_blobs.cleanup_retry_at, active_storage_blobs.created_at + make_interval(days => 7))"
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
      ids = execute ? claim_candidates : candidate_scope.limit(batch_size).pluck(:id)
      return Result.new(candidate_count: ids.size, purged_count: 0) unless execute

      purged_count = ids.count { |blob_id| purge_if_still_abandoned(blob_id) }
      Result.new(candidate_count: ids.size, purged_count: purged_count)
    end

    private

    attr_reader :batch_size, :cutoff, :execute

    def candidate_scope
      ActiveStorage::Blob.unattached
        .where(created_at: ..cutoff)
        .where("#{ELIGIBILITY_SQL} <= ?", cutoff + DEFAULT_AGE)
        .where("cleanup_retry_at IS NULL OR cleanup_retry_at <= ?", Time.current)
        .order(Arel.sql(ELIGIBILITY_SQL), :id)
    end

    def claim_candidates
      ActiveStorage::Blob.transaction do
        ids = candidate_scope.limit(batch_size).lock("FOR UPDATE OF active_storage_blobs SKIP LOCKED").pluck(:id)
        # Commit a retry deadline before filesystem work. Failure or process
        # death remains discoverable, but cannot monopolize the oldest batch.
        ActiveStorage::Blob.where(id: ids).update_all(cleanup_retry_at: RETRY_DELAY.from_now)
        ids
      end
    end

    def purge_if_still_abandoned(blob_id)
      blob = ActiveStorage::Blob.find_by(id: blob_id)
      return false unless blob

      Purge.call(blob:, cutoff:, skip_locked: true)
    end
  end
end
