module Benchmarking
  class ModelLeaderboard
    SORTS = %w[
      judged_samples
      wins
      win_rate
      review_score
      judge_score
      translation_cost
      latency
    ].freeze
    DEFAULT_SORT = "judged_samples"

    attr_reader :sort

    def initialize(experiment_scope:, sort: nil)
      @experiment_scope = experiment_scope
      @sort = SORTS.include?(sort.to_s) ? sort.to_s : DEFAULT_SORT
    end

    def call
      models = LlmModel.where(
        id: TranslationRun.where(experiment_id: experiment_scope.select(:id)).select(:llm_model_id)
      ).to_a
      aggregates = aggregate_sets
      stats = models.map { |model| build_stats(model, aggregates) }

      sort_stats(stats)
    end

    private

    attr_reader :experiment_scope

    def aggregate_sets
      {
        translations: translation_aggregates,
        reviews: review_aggregates,
        judges: judge_aggregates,
        participation: participation_aggregates,
        wins: win_aggregates,
        efficiency: efficiency_aggregates,
        reviewers: ReviewerDiagnostics.call(experiment_scope: experiment_scope),
        judging: JudgeDiagnostics.call(experiment_scope: experiment_scope)
      }
    end

    def translation_aggregates
      rows_by_model(<<~SQL)
        SELECT llm_model_id AS model_id,
               COUNT(*) AS completed_translation_count,
               COUNT(cost) AS cost_sample_count,
               SUM(cost) AS total_translation_cost,
               AVG(cost) AS average_translation_cost,
               COUNT(total_tokens) AS token_sample_count,
               AVG(total_tokens) AS average_total_tokens,
               COUNT(*) FILTER (
                 WHERE started_at IS NOT NULL
                   AND completed_at IS NOT NULL
                   AND completed_at >= started_at
               ) AS latency_sample_count,
               AVG(EXTRACT(EPOCH FROM (completed_at - started_at))) FILTER (
                 WHERE started_at IS NOT NULL
                   AND completed_at IS NOT NULL
                   AND completed_at >= started_at
               ) AS average_latency_seconds
          FROM translation_runs
         WHERE status = 'completed'
           AND experiment_id IN (#{experiment_ids_sql})
         GROUP BY llm_model_id
      SQL
    end

    def review_aggregates
      rows_by_model(<<~SQL)
        SELECT translation_runs.llm_model_id AS model_id,
               COUNT(DISTINCT translation_runs.id) AS reviewed_candidate_count,
               COUNT(review_evaluations.overall_score) AS review_score_sample_count,
               AVG(review_evaluations.overall_score) AS review_average_score
          FROM review_evaluations
          JOIN review_runs ON review_runs.id = review_evaluations.review_run_id
          JOIN translation_runs ON translation_runs.id = review_evaluations.translation_run_id
         WHERE review_runs.status = 'completed'
           AND translation_runs.experiment_id IN (#{experiment_ids_sql})
         GROUP BY translation_runs.llm_model_id
      SQL
    end

    def judge_aggregates
      rows_by_model(<<~SQL)
        SELECT translation_runs.llm_model_id AS model_id,
               COUNT(DISTINCT translation_runs.id) AS judged_candidate_count,
               COUNT(judge_evaluations.overall_score) AS judge_score_sample_count,
               AVG(judge_evaluations.overall_score) AS judge_average_score
          FROM judge_evaluations
          JOIN judge_runs ON judge_runs.id = judge_evaluations.judge_run_id
          JOIN translation_runs ON translation_runs.id = judge_evaluations.translation_run_id
         WHERE judge_runs.status = 'completed'
           AND translation_runs.experiment_id IN (#{experiment_ids_sql})
         GROUP BY translation_runs.llm_model_id
      SQL
    end

    def participation_aggregates
      rows_by_model(<<~SQL)
        SELECT translation_runs.llm_model_id AS model_id,
               COUNT(DISTINCT judge_rounds.id) AS completed_judged_experiment_count
          FROM judge_rounds
          JOIN judge_runs ON judge_runs.judge_round_id = judge_rounds.id
          JOIN judge_evaluations ON judge_evaluations.judge_run_id = judge_runs.id
          JOIN translation_runs ON translation_runs.id = judge_evaluations.translation_run_id
          JOIN review_rounds ON review_rounds.id = judge_rounds.review_round_id
         WHERE judge_rounds.status = 'completed'
           AND judge_runs.status = 'completed'
           AND review_rounds.experiment_id IN (#{experiment_ids_sql})
         GROUP BY translation_runs.llm_model_id
      SQL
    end

    def win_aggregates
      rows_by_model(<<~SQL)
        SELECT translation_runs.llm_model_id AS model_id,
               COUNT(DISTINCT judge_rounds.id) AS official_wins
          FROM judge_rounds
          JOIN translation_runs ON translation_runs.id = judge_rounds.winner_translation_run_id
         WHERE judge_rounds.status = 'completed'
           AND translation_runs.experiment_id IN (#{experiment_ids_sql})
         GROUP BY translation_runs.llm_model_id
      SQL
    end

    def efficiency_aggregates
      rows_by_model(<<~SQL)
        SELECT scored_runs.model_id,
               COUNT(*) AS cost_quality_sample_count,
               AVG(scored_runs.cost / scored_runs.judge_score) AS average_cost_per_judge_score_point
          FROM (
            SELECT translation_runs.id,
                   translation_runs.llm_model_id AS model_id,
                   translation_runs.cost,
                   AVG(judge_evaluations.overall_score) AS judge_score
              FROM translation_runs
              JOIN judge_evaluations
                ON judge_evaluations.translation_run_id = translation_runs.id
              JOIN judge_runs ON judge_runs.id = judge_evaluations.judge_run_id
             WHERE translation_runs.status = 'completed'
               AND translation_runs.cost > 0
               AND translation_runs.experiment_id IN (#{experiment_ids_sql})
               AND judge_runs.status = 'completed'
               AND judge_evaluations.overall_score IS NOT NULL
             GROUP BY translation_runs.id
          ) scored_runs
         GROUP BY scored_runs.model_id
      SQL
    end

    def rows_by_model(sql)
      ApplicationRecord.connection.select_all(sql.squish).index_by do |row|
        row.fetch("model_id").to_i
      end
    end

    def experiment_ids_sql
      @experiment_ids_sql ||= experiment_scope.reselect(:id).to_sql
    end

    def build_stats(model, sets)
      translation = sets[:translations][model.id] || {}
      review = sets[:reviews][model.id] || {}
      judge = sets[:judges][model.id] || {}
      participation = sets[:participation][model.id] || {}
      wins = sets[:wins][model.id] || {}
      efficiency = sets[:efficiency][model.id] || {}

      ModelStats.new(
        model: model,
        completed_translation_count: integer(translation, "completed_translation_count"),
        reviewed_candidate_count: integer(review, "reviewed_candidate_count"),
        judged_candidate_count: integer(judge, "judged_candidate_count"),
        completed_judged_experiment_count: integer(participation, "completed_judged_experiment_count"),
        official_wins: integer(wins, "official_wins"),
        review_average_score: decimal(review, "review_average_score"),
        review_score_sample_count: integer(review, "review_score_sample_count"),
        judge_average_score: decimal(judge, "judge_average_score"),
        judge_score_sample_count: integer(judge, "judge_score_sample_count"),
        total_translation_cost: decimal(translation, "total_translation_cost"),
        average_translation_cost: decimal(translation, "average_translation_cost"),
        cost_sample_count: integer(translation, "cost_sample_count"),
        average_latency_seconds: decimal(translation, "average_latency_seconds"),
        latency_sample_count: integer(translation, "latency_sample_count"),
        average_total_tokens: decimal(translation, "average_total_tokens"),
        token_sample_count: integer(translation, "token_sample_count"),
        average_cost_per_judge_score_point: decimal(efficiency, "average_cost_per_judge_score_point"),
        cost_quality_sample_count: integer(efficiency, "cost_quality_sample_count"),
        reviewer_diagnostics: sets[:reviewers][model.id],
        judge_diagnostics: sets[:judging][model.id]
      )
    end

    def integer(row, key)
      row.fetch(key, 0).to_i
    end

    def decimal(row, key)
      value = row[key]
      BigDecimal(value.to_s) unless value.nil?
    end

    def sort_stats(stats)
      return stats.sort_by { |stat| default_sort_key(stat) } if sort == DEFAULT_SORT

      stats.sort_by do |stat|
        value, direction = sort_value(stat)
        [ value.nil? ? 1 : 0, sortable_value(value, direction), stat.model.id ]
      end
    end

    def default_sort_key(stat)
      [
        -stat.judge_score_sample_count,
        stat.official_win_rate.nil? ? 1 : 0,
        sortable_value(stat.official_win_rate, :descending),
        stat.model.id
      ]
    end

    def sort_value(stat)
      {
        "wins" => [ stat.official_wins, :descending ],
        "win_rate" => [ stat.official_win_rate, :descending ],
        "review_score" => [ stat.review_average_score, :descending ],
        "judge_score" => [ stat.judge_average_score, :descending ],
        "translation_cost" => [ stat.average_translation_cost, :ascending ],
        "latency" => [ stat.average_latency_seconds, :ascending ]
      }.fetch(sort)
    end

    def sortable_value(value, direction)
      return 0 if value.nil?

      direction == :descending ? -value : value
    end
  end
end
