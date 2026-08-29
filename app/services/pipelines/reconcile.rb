module Pipelines
  class Reconcile
    DEFAULT_BATCH_SIZE = 100
    MAX_BATCH_SIZE = 500

    Result = Data.define(:examined_count, :advanced_count)

    def self.call(batch_size: DEFAULT_BATCH_SIZE)
      limit = [ Integer(batch_size), MAX_BATCH_SIZE ].min
      raise ArgumentError, "batch size must be positive" unless limit.positive?

      ids = PipelineRun.reconcilable.limit(limit).pluck(:id)
      advanced = ids.count do |id|
        pipeline_run = PipelineRun.find_by(id: id)
        next false unless pipeline_run

        before = pipeline_run.updated_at
        Advance.call(pipeline_run: pipeline_run)
        pipeline_run.reload.updated_at != before
      end
      Result.new(examined_count: ids.size, advanced_count: advanced)
    end
  end
end
