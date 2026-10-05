module SourceImports
  class Cleanup
    Result = Data.define(:purged_count, :retirements_purged_count)

    def self.call(cutoff: Time.current, batch_size: Limits::CLEANUP_BATCH_SIZE)
      new(cutoff:, batch_size:).call
    end

    def initialize(cutoff:, batch_size:)
      @cutoff = cutoff
      @batch_size = [ Integer(batch_size), Limits::CLEANUP_BATCH_SIZE ].min
      raise ArgumentError, "batch size must be positive" unless @batch_size.positive?
    end

    def call
      purged_count = 0
      candidate_ids.each do |source_import_id|
        source_import = SourceImport.find_by(id: source_import_id)
        next unless source_import

        purged_count += 1 if Retire.call(source_import:, cutoff:)
      rescue ActiveRecord::RecordNotFound, RequestLock::Unavailable
        # Another action removed it, or a live creator still owns it. A later
        # bounded cleanup batch can retry without deleting live content.
        next
      end
      retirements_purged_count = SourceImportRetirement.purge_expired(at: cutoff, batch_size:)
      Result.new(purged_count:, retirements_purged_count:)
    end

    private

    attr_reader :cutoff, :batch_size

    def candidate_ids
      SourceImport.expired_abandoned(cutoff).order(:expires_at, :id).limit(batch_size).pluck(:id)
    end
  end
end
