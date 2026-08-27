module Benchmarking
  class ReviewerDiagnostics
    Result = Data.define(
      :model_id,
      :self_sample_count,
      :self_average_score,
      :other_sample_count,
      :other_average_score
    ) do
      def self_score_difference
        return if self_average_score.nil? || other_average_score.nil?

        self_average_score - other_average_score
      end
    end

    def self.call(experiment_scope:)
      new(experiment_scope: experiment_scope).call
    end

    def initialize(experiment_scope:)
      @experiment_scope = experiment_scope
    end

    def call
      rows.index_by(&:model_id)
    end

    private

    attr_reader :experiment_scope

    def rows
      ReviewRun.joins(review_evaluations: :translation_run)
        .where(
          status: "completed",
          translation_runs: { experiment_id: experiment_scope.select(:id) }
        )
        .group(:reviewer_llm_model_id)
        .pluck(
          :reviewer_llm_model_id,
          Arel.sql(<<~SQL.squish),
            COUNT(review_evaluations.overall_score) FILTER (
              WHERE translation_runs.llm_model_id = review_runs.reviewer_llm_model_id
            )
          SQL
          Arel.sql(<<~SQL.squish),
            AVG(review_evaluations.overall_score) FILTER (
              WHERE translation_runs.llm_model_id = review_runs.reviewer_llm_model_id
            )
          SQL
          Arel.sql(<<~SQL.squish),
            COUNT(review_evaluations.overall_score) FILTER (
              WHERE translation_runs.llm_model_id <> review_runs.reviewer_llm_model_id
            )
          SQL
          Arel.sql(<<~SQL.squish)
            AVG(review_evaluations.overall_score) FILTER (
              WHERE translation_runs.llm_model_id <> review_runs.reviewer_llm_model_id
            )
          SQL
        ).map do |model_id, self_count, self_average, other_count, other_average|
        Result.new(
          model_id: model_id,
          self_sample_count: self_count,
          self_average_score: decimal(self_average),
          other_sample_count: other_count,
          other_average_score: decimal(other_average)
        )
      end
    end

    def decimal(value)
      BigDecimal(value.to_s) unless value.nil?
    end
  end
end
