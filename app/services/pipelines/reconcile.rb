module Pipelines
  class Reconcile
    DEFAULT_BATCH_SIZE = 100
    MAX_BATCH_SIZE = 500

    Result = Data.define(:examined_count, :advanced_count)

    def self.call(batch_size: DEFAULT_BATCH_SIZE, clock: -> { Time.current })
      limit = [ Integer(batch_size), MAX_BATCH_SIZE ].min
      raise ArgumentError, "batch size must be positive" unless limit.positive?

      examined_ids = []
      advanced_count = 0
      limit.times do
        result = reconcile_one(excluding: examined_ids, at: clock.call)
        break unless result

        examined_ids << result.fetch(:id)
        advanced_count += 1 if result.fetch(:advanced)
      end
      Result.new(examined_count: examined_ids.size, advanced_count: advanced_count)
    end

    def self.reconcile_one(excluding:, at:)
      PipelineRun.transaction do
        pipeline_run = PipelineRun.reconcilable
                                  .where.not(id: excluding)
                                  .order(Arel.sql("last_reconciled_at ASC NULLS FIRST"), :id)
                                  .lock("FOR UPDATE SKIP LOCKED")
                                  .first
        return unless pipeline_run

        before = pipeline_run.updated_at
        Advance.call(pipeline_run: pipeline_run)
        advanced = pipeline_run.reload.updated_at != before
        pipeline_run.update_columns(last_reconciled_at: at)
        { id: pipeline_run.id, advanced: advanced }
      end
    end
    private_class_method :reconcile_one
  end
end
