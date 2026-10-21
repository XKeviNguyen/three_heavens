module Pipelines
  class CostSummary
    Result = Data.define(:known_cost, :known_count, :complete_count, :record_count) do
      def complete?
        record_count.positive? && complete_count == record_count
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
          Arel.sql("COUNT(*) FILTER (WHERE cost IS NOT NULL)"),
          Arel.sql("COUNT(*) FILTER (WHERE cost_complete)"),
          Arel.sql("COUNT(*)")
        )
      end

      # Retried attempts that were billed are no longer on their runs; they
      # add to the money, not to the count of tasks with a known cost.
      earlier_cost, earlier_count = EarlierAttemptCosts.call([ experiment.id ]).fetch(experiment.id, [ BigDecimal("0"), 0 ])
      known_count = rows.sum { |row| row[1] }
      any_known = known_count.positive? || earlier_count.positive?
      Result.new(
        known_cost: any_known ? rows.sum { |row| row[0] ? BigDecimal(row[0].to_s) : BigDecimal("0") } + earlier_cost : nil,
        known_count: known_count,
        complete_count: rows.sum { |row| row[2] },
        record_count: rows.sum { |row| row[3] }
      )
    end
  end
end
