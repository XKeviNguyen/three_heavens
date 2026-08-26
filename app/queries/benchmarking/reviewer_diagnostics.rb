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

    def self.call
      new.call
    end

    def call
      rows.index_by(&:model_id)
    end

    private

    def rows
      ApplicationRecord.connection.select_all(<<~SQL.squish).map do |row|
        SELECT review_runs.reviewer_llm_model_id AS model_id,
               COUNT(review_evaluations.overall_score) FILTER (
                 WHERE translation_runs.llm_model_id = review_runs.reviewer_llm_model_id
               ) AS self_sample_count,
               AVG(review_evaluations.overall_score) FILTER (
                 WHERE translation_runs.llm_model_id = review_runs.reviewer_llm_model_id
               ) AS self_average_score,
               COUNT(review_evaluations.overall_score) FILTER (
                 WHERE translation_runs.llm_model_id <> review_runs.reviewer_llm_model_id
               ) AS other_sample_count,
               AVG(review_evaluations.overall_score) FILTER (
                 WHERE translation_runs.llm_model_id <> review_runs.reviewer_llm_model_id
               ) AS other_average_score
          FROM review_runs
          JOIN review_evaluations ON review_evaluations.review_run_id = review_runs.id
          JOIN translation_runs ON translation_runs.id = review_evaluations.translation_run_id
         WHERE review_runs.status = 'completed'
         GROUP BY review_runs.reviewer_llm_model_id
      SQL

        Result.new(
          model_id: row.fetch("model_id").to_i,
          self_sample_count: row.fetch("self_sample_count").to_i,
          self_average_score: decimal(row["self_average_score"]),
          other_sample_count: row.fetch("other_sample_count").to_i,
          other_average_score: decimal(row["other_average_score"])
        )
      end
    end

    def decimal(value)
      BigDecimal(value.to_s) unless value.nil?
    end
  end
end
