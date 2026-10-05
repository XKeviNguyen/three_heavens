module SourceImports
  class Cleanup
    Result = Data.define(:purged_count, :retirements_purged_count, :cursor, :more_imports)

    def self.call(cutoff: Time.current, batch_size: Limits::CLEANUP_BATCH_SIZE, after: nil)
      new(cutoff:, batch_size:, after:).call
    end

    def initialize(cutoff:, batch_size:, after:)
      @cutoff = cutoff
      @after = after
      @batch_size = [ Integer(batch_size), Limits::CLEANUP_BATCH_SIZE ].min
      raise ArgumentError, "batch size must be positive" unless @batch_size.positive?
    end

    def call
      purged_count = 0
      candidates = candidate_rows
      candidates.each do |source_import_id, _|
        source_import = SourceImport.find_by(id: source_import_id)
        next unless source_import

        purged_count += 1 if Retire.call(source_import:, cutoff:)
      rescue ActiveRecord::RecordNotFound, RequestLock::Unavailable
        # Another action removed it, or a live creator still owns it. A later
        # bounded cleanup batch can retry without deleting live content.
        next
      end
      retirements_purged_count = SourceImportRetirement.purge_expired(at: cutoff, batch_size:)
      last = candidates.last
      Result.new(purged_count:, retirements_purged_count:, cursor: last ? [ last[1].iso8601(6), last[0] ] : after,
        more_imports: candidates.size == batch_size)
    end

    private

    attr_reader :cutoff, :batch_size, :after

    def candidate_rows
      scope = SourceImport.expired_abandoned(cutoff)
      scope = scope.where("(expires_at, id) > (?, ?)", *after) if after
      scope.order(:expires_at, :id).limit(batch_size).pluck(:id, :expires_at)
    end
  end
end
