module Projects
  class SummaryQuery
    SUMMARY_SELECT = <<~SQL.squish.freeze
      projects.*,
      (SELECT COUNT(*) FROM documents WHERE documents.project_id = projects.id) AS documents_count,
      (
        SELECT COUNT(*)
        FROM experiments
        INNER JOIN documents ON documents.id = experiments.document_id
        WHERE documents.project_id = projects.id
      ) AS experiments_count,
      (
        SELECT MAX(project_activity.activity_at)
        FROM (
          SELECT projects.updated_at AS activity_at
          UNION ALL
          SELECT documents.updated_at FROM documents WHERE documents.project_id = projects.id
          UNION ALL
          SELECT experiments.updated_at
          FROM experiments INNER JOIN documents ON documents.id = experiments.document_id
          WHERE documents.project_id = projects.id
          UNION ALL
          SELECT translation_runs.updated_at
          FROM translation_runs
          INNER JOIN experiments ON experiments.id = translation_runs.experiment_id
          INNER JOIN documents ON documents.id = experiments.document_id
          WHERE documents.project_id = projects.id
          UNION ALL
          SELECT pipeline_runs.updated_at
          FROM pipeline_runs
          INNER JOIN experiments ON experiments.id = pipeline_runs.experiment_id
          INNER JOIN documents ON documents.id = experiments.document_id
          WHERE documents.project_id = projects.id
          UNION ALL
          SELECT review_rounds.updated_at
          FROM review_rounds
          INNER JOIN experiments ON experiments.id = review_rounds.experiment_id
          INNER JOIN documents ON documents.id = experiments.document_id
          WHERE documents.project_id = projects.id
          UNION ALL
          SELECT review_runs.updated_at
          FROM review_runs
          INNER JOIN review_rounds ON review_rounds.id = review_runs.review_round_id
          INNER JOIN experiments ON experiments.id = review_rounds.experiment_id
          INNER JOIN documents ON documents.id = experiments.document_id
          WHERE documents.project_id = projects.id
          UNION ALL
          SELECT judge_rounds.updated_at
          FROM judge_rounds
          INNER JOIN review_rounds ON review_rounds.id = judge_rounds.review_round_id
          INNER JOIN experiments ON experiments.id = review_rounds.experiment_id
          INNER JOIN documents ON documents.id = experiments.document_id
          WHERE documents.project_id = projects.id
          UNION ALL
          SELECT judge_runs.updated_at
          FROM judge_runs
          INNER JOIN judge_rounds ON judge_rounds.id = judge_runs.judge_round_id
          INNER JOIN review_rounds ON review_rounds.id = judge_rounds.review_round_id
          INNER JOIN experiments ON experiments.id = review_rounds.experiment_id
          INNER JOIN documents ON documents.id = experiments.document_id
          WHERE documents.project_id = projects.id
          UNION ALL
          SELECT final_translations.updated_at
          FROM final_translations
          INNER JOIN experiments ON experiments.id = final_translations.experiment_id
          INNER JOIN documents ON documents.id = experiments.document_id
          WHERE documents.project_id = projects.id
          UNION ALL
          SELECT final_translation_versions.updated_at
          FROM final_translation_versions
          INNER JOIN final_translations ON final_translations.id = final_translation_versions.final_translation_id
          INNER JOIN experiments ON experiments.id = final_translations.experiment_id
          INNER JOIN documents ON documents.id = experiments.document_id
          WHERE documents.project_id = projects.id
          UNION ALL
          SELECT finalization_runs.updated_at
          FROM finalization_runs
          INNER JOIN finalization_rounds ON finalization_rounds.id = finalization_runs.finalization_round_id
          INNER JOIN final_translations ON final_translations.id = finalization_rounds.final_translation_id
          INNER JOIN experiments ON experiments.id = final_translations.experiment_id
          INNER JOIN documents ON documents.id = experiments.document_id
          WHERE documents.project_id = projects.id
          UNION ALL
          SELECT finalization_rounds.updated_at
          FROM finalization_rounds
          INNER JOIN final_translations ON final_translations.id = finalization_rounds.final_translation_id
          INNER JOIN experiments ON experiments.id = final_translations.experiment_id
          INNER JOIN documents ON documents.id = experiments.document_id
          WHERE documents.project_id = projects.id
        ) project_activity
      ) AS latest_activity_at
    SQL

    def initialize(project_scope:)
      @project_scope = project_scope
    end

    def call(offset:, limit:)
      project_scope
        .select(SUMMARY_SELECT)
        .order(Arel.sql("latest_activity_at DESC"), id: :desc)
        .offset(offset)
        .limit(limit)
    end

    private

    attr_reader :project_scope
  end
end
