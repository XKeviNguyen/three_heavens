module Benchmarking
  class JudgeDiagnostics
    Result = Data.define(:model_id, :eligible_run_count, :agreement_count) do
      def agreement_rate
        return if eligible_run_count.zero?

        BigDecimal(agreement_count.to_s) / eligible_run_count
      end
    end

    def self.call
      new.call
    end

    def call
      rows.index_by(&:model_id)
    end

    private

    def rows
      JudgeRun.joins(:judge_round)
        .where(status: "completed", judge_rounds: { status: "completed" })
        .group(:judge_llm_model_id)
        .pluck(
          :judge_llm_model_id,
          Arel.sql("COUNT(*)"),
          Arel.sql(<<~SQL.squish)
            COUNT(*) FILTER (
              WHERE judge_runs.winner_translation_run_id = judge_rounds.winner_translation_run_id
            )
          SQL
        ).map do |model_id, eligible_count, agreement_count|
          Result.new(
            model_id: model_id,
            eligible_run_count: eligible_count,
            agreement_count: agreement_count
          )
        end
    end
  end
end
