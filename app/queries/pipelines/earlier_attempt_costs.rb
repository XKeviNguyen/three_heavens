module Pipelines
  # Billed cost of provider attempts that their run no longer shows. A run
  # stores only its latest attempt's cost, and an explicit retry clears it, so
  # a billed attempt that was retried (an answer cut off at the output limit)
  # is kept only in ai_provider_attempts. Cost totals add this to the runs'
  # costs, which counts every billed request once: the attempt whose cost the
  # run still shows through the run, every other billed attempt here.
  class EarlierAttemptCosts
    # Each run table with the experiment it belongs to.
    OWNERS = {
      "TranslationRun" => "FROM translation_runs runs",
      "TranslationSegmentRun" => "FROM translation_segment_runs runs " \
                                 "JOIN translation_runs parents ON parents.id = runs.translation_run_id",
      "ReviewRun" => "FROM review_runs runs JOIN review_rounds rounds ON rounds.id = runs.review_round_id",
      "ReviewSegmentRun" => "FROM review_segment_runs runs JOIN review_runs parents ON parents.id = runs.review_run_id " \
                            "JOIN review_rounds rounds ON rounds.id = parents.review_round_id",
      "JudgeRun" => "FROM judge_runs runs JOIN judge_rounds judge_rounds ON judge_rounds.id = runs.judge_round_id " \
                    "JOIN review_rounds rounds ON rounds.id = judge_rounds.review_round_id",
      "JudgeSegmentRun" => "FROM judge_segment_runs runs JOIN judge_runs parents ON parents.id = runs.judge_run_id " \
                           "JOIN judge_rounds judge_rounds ON judge_rounds.id = parents.judge_round_id " \
                           "JOIN review_rounds rounds ON rounds.id = judge_rounds.review_round_id",
      "FinalizationRun" => "FROM finalization_runs runs " \
                           "JOIN finalization_rounds finalization_rounds ON finalization_rounds.id = runs.finalization_round_id " \
                           "JOIN final_translations rounds ON rounds.id = finalization_rounds.final_translation_id",
      "FinalizationSegmentRun" => "FROM finalization_segment_runs runs " \
                                  "JOIN finalization_runs parents ON parents.id = runs.finalization_run_id " \
                                  "JOIN finalization_rounds finalization_rounds ON finalization_rounds.id = parents.finalization_round_id " \
                                  "JOIN final_translations rounds ON rounds.id = finalization_rounds.final_translation_id"
    }.freeze
    EXPERIMENT_COLUMN = Hash.new("rounds.experiment_id").merge(
      "TranslationRun" => "runs.experiment_id", "TranslationSegmentRun" => "parents.experiment_id"
    ).freeze

    # { experiment_id => [known cost, number of attempts] }
    def self.call(experiment_ids)
      ids = Array(experiment_ids).map { |id| Integer(id) }
      return {} if ids.empty?

      owners = OWNERS.map do |type, from|
        column = EXPERIMENT_COLUMN[type]
        "SELECT '#{type}' AS run_type, runs.id, runs.execution_attempt, runs.cost, #{column} AS experiment_id " \
          "#{from} WHERE #{column} IN (:ids)"
      end.join(" UNION ALL ")
      sql = ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, { ids: ids } ])
        SELECT owners.experiment_id, SUM(attempts.cost), COUNT(*)
        FROM ai_provider_attempts attempts
        JOIN (#{owners}) owners
          ON owners.run_type = attempts.provider_run_type AND owners.id = attempts.provider_run_id
        WHERE attempts.cost IS NOT NULL
          AND NOT (attempts.attempt_number = owners.execution_attempt AND owners.cost IS NOT NULL)
        GROUP BY owners.experiment_id
      SQL
      AiProviderAttempt.connection.select_rows(sql).to_h do |experiment_id, cost, count|
        [ Integer(experiment_id), [ BigDecimal(cost.to_s), Integer(count) ] ]
      end
    end
  end
end
