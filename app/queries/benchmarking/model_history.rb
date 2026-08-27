module Benchmarking
  class ModelHistory
    DEFAULT_LIMIT = 25
    UNKNOWN_RESOLVED_MODEL = "[unknown]".freeze
    RESOLVED_MODEL_SQL = <<~SQL.squish.freeze
      COALESCE(NULLIF(BTRIM(translation_runs.resolved_model_identifier), ''),
               '#{UNKNOWN_RESOLVED_MODEL}')
    SQL

    Entry = Data.define(
      :translation_run,
      :review_average_score,
      :review_score_sample_count,
      :judge_average_score,
      :judge_score_sample_count,
      :official_winner
    ) do
      def latency_seconds
        run = translation_run
        return unless run.completed? && run.started_at && run.completed_at
        return if run.completed_at < run.started_at

        run.completed_at - run.started_at
      end
    end

    ResolvedModelStats = Data.define(
      :resolved_model_identifier,
      :sample_count,
      :completed_count,
      :official_wins,
      :judge_average_score,
      :judge_score_sample_count,
      :total_known_cost,
      :cost_sample_count
    )

    Result = Data.define(:entries, :resolved_models)

    def initialize(model:, experiment_scope:, limit: DEFAULT_LIMIT)
      @model = model
      @experiment_scope = experiment_scope
      @limit = limit
    end

    def call
      Result.new(entries: history_entries, resolved_models: resolved_model_stats)
    end

    private

    attr_reader :experiment_scope, :model, :limit

    def recent_runs
      @recent_runs ||= model.translation_runs
        .where(experiment_id: experiment_scope.select(:id))
        .order(created_at: :desc, id: :desc)
        .limit(limit)
        .to_a
    end

    def history_entries
      run_ids = recent_runs.map(&:id)
      reviews = score_aggregates(ReviewEvaluation, :review_run, run_ids)
      judges = score_aggregates(JudgeEvaluation, :judge_run, run_ids)
      winning_run_ids = JudgeRound.completed
        .where(winner_translation_run_id: run_ids)
        .pluck(:winner_translation_run_id)
        .to_set

      recent_runs.map do |run|
        review = reviews[run.id] || {}
        judge = judges[run.id] || {}
        Entry.new(
          translation_run: run,
          review_average_score: decimal(review["average_score"]),
          review_score_sample_count: review.fetch("sample_count", 0).to_i,
          judge_average_score: decimal(judge["average_score"]),
          judge_score_sample_count: judge.fetch("sample_count", 0).to_i,
          official_winner: winning_run_ids.include?(run.id)
        )
      end
    end

    def score_aggregates(evaluation_class, run_association, run_ids)
      return {} if run_ids.empty?

      run_table = evaluation_class.reflect_on_association(run_association).klass.table_name
      evaluation_class.joins(run_association)
        .where(translation_run_id: run_ids, run_table => { status: "completed" })
        .group(:translation_run_id)
        .pluck(
          :translation_run_id,
          Arel.sql("COUNT(#{evaluation_class.table_name}.overall_score)"),
          Arel.sql("AVG(#{evaluation_class.table_name}.overall_score)")
        ).to_h do |translation_run_id, count, average|
          [ translation_run_id, { "sample_count" => count, "average_score" => average } ]
        end
    end

    def resolved_model_stats
      translations = resolved_translation_aggregates
      judge_scores = resolved_judge_aggregates
      wins = resolved_win_aggregates

      translations.map do |identifier, values|
        judge = judge_scores[identifier] || {}
        ResolvedModelStats.new(
          resolved_model_identifier: display_identifier(identifier),
          sample_count: values.fetch("sample_count").to_i,
          completed_count: values.fetch("completed_count").to_i,
          official_wins: wins.fetch(identifier, 0).to_i,
          judge_average_score: decimal(judge["average_score"]),
          judge_score_sample_count: judge.fetch("sample_count", 0).to_i,
          total_known_cost: decimal(values["total_known_cost"]),
          cost_sample_count: values.fetch("cost_sample_count").to_i
        )
      end.sort_by do |stats|
        [ -stats.sample_count, stats.resolved_model_identifier.to_s ]
      end
    end

    def resolved_translation_aggregates
      model.translation_runs
        .where(experiment_id: experiment_scope.select(:id))
        .group(Arel.sql(RESOLVED_MODEL_SQL))
        .pluck(
          Arel.sql(RESOLVED_MODEL_SQL),
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(*) FILTER (WHERE translation_runs.status = 'completed')"),
          Arel.sql("SUM(translation_runs.cost) FILTER (WHERE translation_runs.status = 'completed')"),
          Arel.sql("COUNT(translation_runs.cost) FILTER (WHERE translation_runs.status = 'completed')")
        ).to_h do |identifier, sample_count, completed_count, cost, cost_count|
          [
            identifier,
            {
              "sample_count" => sample_count,
              "completed_count" => completed_count,
              "total_known_cost" => cost,
              "cost_sample_count" => cost_count
            }
          ]
        end
    end

    def resolved_judge_aggregates
      JudgeEvaluation.joins(:judge_run, :translation_run)
        .where(
          judge_runs: { status: "completed" },
          translation_runs: {
            llm_model_id: model.id,
            experiment_id: experiment_scope.select(:id)
          }
        )
        .group(Arel.sql(RESOLVED_MODEL_SQL))
        .pluck(
          Arel.sql(RESOLVED_MODEL_SQL),
          Arel.sql("COUNT(judge_evaluations.overall_score)"),
          Arel.sql("AVG(judge_evaluations.overall_score)")
        ).to_h do |identifier, count, average|
          [ identifier, { "sample_count" => count, "average_score" => average } ]
        end
    end

    def resolved_win_aggregates
      JudgeRound.completed.joins(:winner_translation_run)
        .where(
          translation_runs: {
            llm_model_id: model.id,
            experiment_id: experiment_scope.select(:id)
          }
        )
        .group(Arel.sql(RESOLVED_MODEL_SQL))
        .pluck(Arel.sql(RESOLVED_MODEL_SQL), Arel.sql("COUNT(DISTINCT judge_rounds.id)"))
        .to_h
    end

    def display_identifier(identifier)
      identifier == UNKNOWN_RESOLVED_MODEL ? nil : identifier
    end

    def decimal(value)
      BigDecimal(value.to_s) unless value.nil?
    end
  end
end
