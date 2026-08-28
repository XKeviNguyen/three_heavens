module SourceImports
  class Cleanup
    Result = Data.define(:purged_count)

    def self.call(cutoff: Time.current, batch_size: Limits::CLEANUP_BATCH_SIZE)
      new(cutoff:, batch_size:).call
    end

    def initialize(cutoff:, batch_size:)
      @cutoff = cutoff
      @batch_size = [ Integer(batch_size), Limits::CLEANUP_BATCH_SIZE ].min
    end

    def call
      purged_count = 0
      candidate_ids.each do |source_import_id|
        SourceImport.transaction do
          source_import = SourceImport.lock.find_by(id: source_import_id)
          next unless source_import&.status.in?(%w[pending ready failed])
          next unless source_import.expires_at <= cutoff

          source_import.destroy!
          purged_count += 1
        end
      end
      Result.new(purged_count:)
    end

    private

    attr_reader :cutoff, :batch_size

    def candidate_ids
      SourceImport.expired_abandoned(cutoff).order(:expires_at, :id).limit(batch_size).pluck(:id)
    end
  end
end
