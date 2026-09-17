module Ai
  class LegacyErrorRemediation
    RUN_CLASSES = [
      TranslationRun, TranslationSegmentRun, ReviewRun, ReviewSegmentRun,
      JudgeRun, JudgeSegmentRun, FinalizationRun, FinalizationSegmentRun
    ].freeze
    SAFE_MESSAGE = "AI provider work failed. Review the safe error code before retrying explicitly."
    MAX_BATCH_SIZE = 1_000
    Result = Data.define(:candidate_count, :remediated_count)

    def self.call(before:, batch_size: 100, execute: false)
      new(before:, batch_size:, execute:).call
    end

    def initialize(before:, batch_size:, execute:)
      @before = before
      @batch_size = [ Integer(batch_size), MAX_BATCH_SIZE ].min
      @execute = execute == true
      raise ArgumentError, "before is required" unless @before.respond_to?(:to_time)
      raise ArgumentError, "batch size must be positive" unless @batch_size.positive?
    end

    def call
      candidates = candidate_rows
      return Result.new(candidate_count: candidates.size, remediated_count: 0) unless execute

      remediated = candidates.sum do |run_class, ids|
        run_class.failed.where(id: ids).where.not(error_message: SAFE_MESSAGE)
          .update_all(error_message: SAFE_MESSAGE, updated_at: Time.current)
      end
      Result.new(candidate_count: candidates.sum { |_run_class, ids| ids.size }, remediated_count: remediated)
    end

    private

    attr_reader :batch_size, :before, :execute

    def candidate_rows
      remaining = batch_size
      RUN_CLASSES.each_with_object([]) do |run_class, rows|
        break rows unless remaining.positive?

        ids = run_class.failed
          .where(completed_at: ...before)
          .where.not(error_message: [ nil, "", SAFE_MESSAGE ])
          .order(:completed_at, :id)
          .limit(remaining)
          .pluck(:id)
        rows << [ run_class, ids ] if ids.any?
        remaining -= ids.size
      end
    end
  end
end
