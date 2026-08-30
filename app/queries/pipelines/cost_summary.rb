module Pipelines
  class CostSummary
    Result = Data.define(:known_cost, :known_count, :record_count) do
      def complete?
        record_count.positive? && known_count == record_count
      end

      def incomplete?
        record_count.positive? && !complete?
      end
    end

    def self.call(experiment:)
      rows = [
        TranslationRun.where(experiment_id: experiment.id),
        ReviewRun.joins(:review_round).where(review_rounds: { experiment_id: experiment.id }),
        JudgeRun.joins(judge_round: :review_round).where(review_rounds: { experiment_id: experiment.id }),
        FinalizationRun.joins(finalization_round: :final_translation).where(final_translations: { experiment_id: experiment.id })
      ].map do |scope|
        scope.pick(
          Arel.sql("SUM(cost)"),
          Arel.sql("COUNT(*) FILTER (WHERE cost IS NOT NULL AND telemetry_complete)"),
          Arel.sql("COUNT(*)")
        )
      end

      known_count = rows.sum { |row| row[1] }
      Result.new(
        known_cost: known_count.positive? ? rows.sum { |row| row[0] ? BigDecimal(row[0].to_s) : BigDecimal("0") } : nil,
        known_count: known_count,
        record_count: rows.sum { |row| row[2] }
      )
    end
  end
end
