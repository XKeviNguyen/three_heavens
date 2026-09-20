class SealBackendIntegrity < ActiveRecord::Migration[8.1]
  IMMUTABLE_TABLES = %i[
    workflow_profile_revisions workflow_profile_model_selections
    document_execution_plans experiment_segments
    final_translation_versions final_translation_version_segments
    pipeline_events
  ].freeze

  PROVIDER_RUNS = {
    translation_runs: "TranslationRun",
    translation_segment_runs: "TranslationSegmentRun",
    review_runs: "ReviewRun",
    review_segment_runs: "ReviewSegmentRun",
    judge_runs: "JudgeRun",
    judge_segment_runs: "JudgeSegmentRun",
    finalization_runs: "FinalizationRun",
    finalization_segment_runs: "FinalizationSegmentRun"
  }.freeze

  COMPLETED_RECORD_TABLES = %i[review_rounds judge_rounds finalization_rounds].freeze

  def up
    verify_existing_integrity!
    add_final_version_origin_constraint
    add_provider_attempt_constraints
    create_immutability_functions
    create_provider_attempt_functions
    create_lineage_functions
    create_revision_sequence_function
    install_triggers
  end

  def down
    remove_check_constraint :final_translation_versions,
                            name: "final_translation_versions_source_origin_check"
    %w[
      ai_provider_attempts_gateway_snapshot_check
      ai_provider_attempts_provider_snapshot_check
      ai_provider_attempts_identifier_snapshot_check
      ai_provider_attempts_display_name_snapshot_check
      ai_provider_attempts_error_code_format_check
      ai_provider_attempts_token_consistency_check
    ].each { |name| remove_check_constraint :ai_provider_attempts, name: name }

    trigger_names.each do |table, name|
      execute "DROP TRIGGER IF EXISTS #{quote_column_name(name)} ON #{quote_table_name(table)}"
    end

    %w[
      enforce_revision_sequence
      enforce_final_version_sequence
      enforce_judge_winner_lineage
      enforce_final_version_lineage
      enforce_owned_workflow_lineage
      enforce_evaluation_lineage
      prevent_segment_parent_lineage_change
      enforce_segment_lineage
      restrict_provider_run_deletion
      enforce_provider_attempt_lineage
      prevent_terminal_evaluation_mutation
      prevent_provider_attempt_mutation
      prevent_completed_record_mutation
      prevent_immutable_row_mutation
    ].each do |function_name|
      execute "DROP FUNCTION IF EXISTS #{function_name}()"
    end
  end

  private

  def verify_existing_integrity!
    execute <<~SQL
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1
          FROM ai_provider_attempts attempts
          WHERE (attempts.provider_run_type = 'TranslationRun' AND
                 (attempts.stage <> 'translation' OR NOT EXISTS (SELECT 1 FROM translation_runs WHERE id = attempts.provider_run_id))) OR
                (attempts.provider_run_type = 'TranslationSegmentRun' AND
                 (attempts.stage <> 'translation' OR NOT EXISTS (SELECT 1 FROM translation_segment_runs WHERE id = attempts.provider_run_id))) OR
                (attempts.provider_run_type = 'ReviewRun' AND
                 (attempts.stage <> 'review' OR NOT EXISTS (SELECT 1 FROM review_runs WHERE id = attempts.provider_run_id))) OR
                (attempts.provider_run_type = 'ReviewSegmentRun' AND
                 (attempts.stage <> 'review' OR NOT EXISTS (SELECT 1 FROM review_segment_runs WHERE id = attempts.provider_run_id))) OR
                (attempts.provider_run_type = 'JudgeRun' AND
                 (attempts.stage <> 'judge' OR NOT EXISTS (SELECT 1 FROM judge_runs WHERE id = attempts.provider_run_id))) OR
                (attempts.provider_run_type = 'JudgeSegmentRun' AND
                 (attempts.stage <> 'judge' OR NOT EXISTS (SELECT 1 FROM judge_segment_runs WHERE id = attempts.provider_run_id))) OR
                (attempts.provider_run_type = 'FinalizationRun' AND
                 (attempts.stage <> 'finalization' OR NOT EXISTS (SELECT 1 FROM finalization_runs WHERE id = attempts.provider_run_id))) OR
                (attempts.provider_run_type = 'FinalizationSegmentRun' AND
                 (attempts.stage <> 'finalization' OR NOT EXISTS (SELECT 1 FROM finalization_segment_runs WHERE id = attempts.provider_run_id)))
        ) THEN
          RAISE EXCEPTION 'Existing provider attempts violate run lineage';
        END IF;

        IF EXISTS (
          SELECT 1 FROM final_translation_versions
          WHERE (origin = 'ai_applied') <> (source_finalization_run_id IS NOT NULL)
        ) THEN
          RAISE EXCEPTION 'Existing final translation versions violate source origin integrity';
        END IF;

        IF EXISTS (
          SELECT 1
          FROM final_translation_versions versions
          JOIN finalization_runs runs ON runs.id = versions.source_finalization_run_id
          JOIN finalization_rounds rounds ON rounds.id = runs.finalization_round_id
          WHERE rounds.final_translation_id <> versions.final_translation_id
        ) THEN
          RAISE EXCEPTION 'Existing final translation versions violate finalization lineage';
        END IF;

        IF EXISTS (
          SELECT 1 FROM pipeline_runs pipelines
          JOIN experiments ON experiments.id = pipelines.experiment_id
          JOIN documents ON documents.id = experiments.document_id
          JOIN projects ON projects.id = documents.project_id
          JOIN workflow_profile_revisions revisions ON revisions.id = pipelines.workflow_profile_revision_id
          JOIN workflow_profiles profiles ON profiles.id = revisions.workflow_profile_id
          WHERE projects.user_id <> profiles.user_id
        ) OR EXISTS (
          SELECT 1 FROM pipeline_runs pipelines
          JOIN finalization_rounds rounds ON rounds.id = pipelines.finalization_round_id
          JOIN final_translations translations ON translations.id = rounds.final_translation_id
          WHERE translations.experiment_id <> pipelines.experiment_id
        ) OR EXISTS (
          SELECT 1 FROM source_imports imports
          JOIN documents ON documents.id = imports.resulting_document_id
          JOIN projects ON projects.id = documents.project_id
          WHERE imports.user_id <> projects.user_id
        ) OR EXISTS (
          SELECT 1 FROM translation_workspace_submissions submissions
          JOIN experiments ON experiments.id = submissions.experiment_id
          JOIN documents ON documents.id = experiments.document_id
          JOIN projects ON projects.id = documents.project_id
          WHERE submissions.user_id <> projects.user_id
        ) THEN
          RAISE EXCEPTION 'Existing workflow records violate owner lineage';
        END IF;

        IF EXISTS (
          SELECT 1 FROM translation_segment_runs runs
          JOIN translation_runs parents ON parents.id = runs.translation_run_id
          JOIN experiment_segments segments ON segments.id = runs.experiment_segment_id
          JOIN document_execution_plans plans ON plans.id = segments.document_execution_plan_id
          WHERE parents.experiment_id <> plans.experiment_id
        ) OR EXISTS (
          SELECT 1 FROM review_segment_runs runs
          JOIN review_runs parents ON parents.id = runs.review_run_id
          JOIN review_rounds rounds ON rounds.id = parents.review_round_id
          JOIN experiment_segments segments ON segments.id = runs.experiment_segment_id
          JOIN document_execution_plans plans ON plans.id = segments.document_execution_plan_id
          WHERE rounds.experiment_id <> plans.experiment_id
        ) OR EXISTS (
          SELECT 1 FROM judge_segment_runs runs
          JOIN judge_runs parents ON parents.id = runs.judge_run_id
          JOIN judge_rounds rounds ON rounds.id = parents.judge_round_id
          JOIN review_rounds reviews ON reviews.id = rounds.review_round_id
          JOIN experiment_segments segments ON segments.id = runs.experiment_segment_id
          JOIN document_execution_plans plans ON plans.id = segments.document_execution_plan_id
          WHERE reviews.experiment_id <> plans.experiment_id
        ) OR EXISTS (
          SELECT 1 FROM finalization_segment_runs runs
          JOIN finalization_runs parents ON parents.id = runs.finalization_run_id
          JOIN finalization_rounds rounds ON rounds.id = parents.finalization_round_id
          JOIN final_translations translations ON translations.id = rounds.final_translation_id
          JOIN experiment_segments segments ON segments.id = runs.experiment_segment_id
          JOIN document_execution_plans plans ON plans.id = segments.document_execution_plan_id
          WHERE translations.experiment_id <> plans.experiment_id
        ) OR EXISTS (
          SELECT 1 FROM final_translation_version_segments version_segments
          JOIN final_translation_versions versions ON versions.id = version_segments.final_translation_version_id
          JOIN final_translations translations ON translations.id = versions.final_translation_id
          JOIN experiment_segments segments ON segments.id = version_segments.experiment_segment_id
          JOIN document_execution_plans plans ON plans.id = segments.document_execution_plan_id
          WHERE translations.experiment_id <> plans.experiment_id
        ) THEN
          RAISE EXCEPTION 'Existing segmented records violate experiment lineage';
        END IF;

        IF EXISTS (
          SELECT 1 FROM review_evaluations evaluations
          JOIN review_runs runs ON runs.id = evaluations.review_run_id
          JOIN review_rounds rounds ON rounds.id = runs.review_round_id
          JOIN translation_runs candidates ON candidates.id = evaluations.translation_run_id
          WHERE rounds.experiment_id <> candidates.experiment_id
        ) OR EXISTS (
          SELECT 1 FROM judge_evaluations evaluations
          JOIN judge_runs runs ON runs.id = evaluations.judge_run_id
          JOIN judge_rounds rounds ON rounds.id = runs.judge_round_id
          JOIN review_rounds reviews ON reviews.id = rounds.review_round_id
          JOIN translation_runs candidates ON candidates.id = evaluations.translation_run_id
          WHERE reviews.experiment_id <> candidates.experiment_id
        ) THEN
          RAISE EXCEPTION 'Existing evaluations violate experiment lineage';
        END IF;

        IF EXISTS (
          SELECT 1 FROM judge_rounds rounds
          JOIN review_rounds reviews ON reviews.id = rounds.review_round_id
          JOIN translation_runs winners ON winners.id = rounds.winner_translation_run_id
          WHERE reviews.experiment_id <> winners.experiment_id OR winners.status <> 'completed'
             OR NOT EXISTS (
               SELECT 1 FROM judge_evaluations evaluations
               JOIN judge_runs runs ON runs.id = evaluations.judge_run_id
               WHERE runs.judge_round_id = rounds.id
                 AND evaluations.translation_run_id = rounds.winner_translation_run_id
             )
        ) OR EXISTS (
          SELECT 1 FROM judge_runs runs
          JOIN judge_rounds rounds ON rounds.id = runs.judge_round_id
          JOIN review_rounds reviews ON reviews.id = rounds.review_round_id
          JOIN translation_runs winners ON winners.id = runs.winner_translation_run_id
          WHERE reviews.experiment_id <> winners.experiment_id OR winners.status <> 'completed'
             OR NOT EXISTS (
               SELECT 1 FROM judge_evaluations evaluations
               WHERE evaluations.judge_run_id = runs.id
                 AND evaluations.translation_run_id = runs.winner_translation_run_id
                 AND evaluations.rank = 1
                 AND evaluations.overall_score IS NOT NULL
                 AND BTRIM(evaluations.rationale) <> ''
                 AND BTRIM(evaluations.strengths) <> ''
                 AND BTRIM(evaluations.risks) <> ''
             )
        ) THEN
          RAISE EXCEPTION 'Existing judge winners violate experiment lineage';
        END IF;

        IF EXISTS (
          SELECT 1 FROM (
            SELECT version, ROW_NUMBER() OVER (PARTITION BY workflow_profile_id ORDER BY version) expected
            FROM workflow_profile_revisions
          ) revisions WHERE version <> expected
        ) OR EXISTS (
          SELECT 1 FROM (
            SELECT version, ROW_NUMBER() OVER (PARTITION BY glossary_id ORDER BY version) expected
            FROM glossary_revisions
          ) revisions WHERE version <> expected
        ) OR EXISTS (
          SELECT 1 FROM (
            SELECT version, ROW_NUMBER() OVER (PARTITION BY methodology_profile_id ORDER BY version) expected
            FROM methodology_profile_revisions
          ) revisions WHERE version <> expected
        ) OR EXISTS (
          SELECT 1 FROM (
            SELECT version, ROW_NUMBER() OVER (PARTITION BY translation_reference_id ORDER BY version) expected
            FROM translation_reference_revisions
          ) revisions WHERE version <> expected
        ) THEN
          RAISE EXCEPTION 'Existing revision history is not monotonic';
        END IF;

        IF EXISTS (
          SELECT 1 FROM (
            SELECT version_number,
                   ROW_NUMBER() OVER (PARTITION BY final_translation_id ORDER BY version_number) expected
            FROM final_translation_versions
          ) versions WHERE version_number <> expected
        ) THEN
          RAISE EXCEPTION 'Existing final translation version history is not monotonic';
        END IF;
      END
      $$;
    SQL
  end

  def add_final_version_origin_constraint
    add_check_constraint :final_translation_versions,
                         "(origin = 'ai_applied') = (source_finalization_run_id IS NOT NULL)",
                         name: "final_translation_versions_source_origin_check",
                         validate: false
  end

  def add_provider_attempt_constraints
    {
      gateway_snapshot: 50,
      provider_snapshot: 100,
      model_identifier_snapshot: 255,
      display_name_snapshot: 150
    }.each do |column, maximum|
      suffix = column == :model_identifier_snapshot ? "identifier_snapshot" : column
      add_check_constraint :ai_provider_attempts,
                           "char_length(#{column}) BETWEEN 1 AND #{maximum}",
                           name: "ai_provider_attempts_#{suffix}_check",
                           validate: false
    end
    add_check_constraint :ai_provider_attempts,
                         "error_code IS NULL OR (char_length(error_code) BETWEEN 1 AND 80 AND error_code ~ '^[a-z0-9_.:-]+$')",
                         name: "ai_provider_attempts_error_code_format_check",
                         validate: false
    add_check_constraint :ai_provider_attempts,
                         <<~SQL.squish,
                           total_tokens IS NULL OR (
                             (prompt_tokens IS NULL OR prompt_tokens <= total_tokens) AND
                             (completion_tokens IS NULL OR completion_tokens <= total_tokens) AND
                             (cached_tokens IS NULL OR cached_tokens <= total_tokens) AND
                             (reasoning_tokens IS NULL OR reasoning_tokens <= total_tokens)
                           )
                         SQL
                         name: "ai_provider_attempts_token_consistency_check",
                         validate: false
  end

  def create_immutability_functions
    execute <<~SQL
      CREATE FUNCTION prevent_immutable_row_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION '% rows are immutable', TG_TABLE_NAME;
      END;
      $$;

      CREATE FUNCTION prevent_completed_record_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN
          IF OLD.status = 'completed' THEN
            RAISE EXCEPTION 'Completed % rows are immutable', TG_TABLE_NAME;
          END IF;
        END IF;

        IF TG_OP <> 'DELETE' THEN
          IF NEW.status IS NOT DISTINCT FROM 'completed' THEN
            CASE TG_TABLE_NAME
            WHEN 'review_runs' THEN
              IF NOT EXISTS (
                SELECT 1 FROM review_evaluations WHERE review_run_id = NEW.id
              ) OR EXISTS (
                SELECT 1 FROM review_evaluations
                WHERE review_run_id = NEW.id
                  AND (faithfulness_score IS NULL OR naturalness_score IS NULL
                    OR terminology_score IS NULL OR instruction_adherence_score IS NULL
                    OR overall_score IS NULL OR strengths IS NULL OR issues IS NULL
                    OR recommended_corrections IS NULL)
              ) THEN
                RAISE EXCEPTION 'Completed review runs require complete evaluations';
              END IF;
            WHEN 'judge_runs' THEN
              IF NOT EXISTS (
                SELECT 1 FROM judge_evaluations WHERE judge_run_id = NEW.id
              ) OR EXISTS (
                SELECT 1 FROM judge_evaluations
                WHERE judge_run_id = NEW.id
                  AND (rank IS NULL OR overall_score IS NULL
                    OR BTRIM(rationale) = '' OR BTRIM(strengths) = '' OR BTRIM(risks) = '')
              ) THEN
                RAISE EXCEPTION 'Completed judge runs require complete evaluations';
              END IF;
              IF (SELECT COUNT(DISTINCT rank) FROM judge_evaluations WHERE judge_run_id = NEW.id)
                   <> (SELECT COUNT(*) FROM judge_evaluations WHERE judge_run_id = NEW.id)
                 OR (SELECT MIN(rank) FROM judge_evaluations WHERE judge_run_id = NEW.id) <> 1
                 OR (SELECT MAX(rank) FROM judge_evaluations WHERE judge_run_id = NEW.id)
                   <> (SELECT COUNT(*) FROM judge_evaluations WHERE judge_run_id = NEW.id) THEN
                RAISE EXCEPTION 'Completed judge runs require one complete ranking';
              END IF;
              IF NEW.winner_translation_run_id IS NULL
                 OR NEW.confidence_score IS NULL
                 OR NEW.winner_rationale IS NULL
                 OR BTRIM(NEW.winner_rationale) = ''
                 OR NOT EXISTS (
                   SELECT 1 FROM judge_evaluations
                   WHERE judge_run_id = NEW.id AND rank = 1
                     AND translation_run_id = NEW.winner_translation_run_id
                 ) THEN
                RAISE EXCEPTION 'Completed judge runs require a complete rank-one winner';
              END IF;
            WHEN 'finalization_runs' THEN
              IF NEW.proposed_translation IS NULL OR BTRIM(NEW.proposed_translation) = '' THEN
                RAISE EXCEPTION 'Completed finalization runs require a proposal';
              END IF;
              IF EXISTS (
                SELECT 1
                FROM jsonb_array_elements(NEW.change_summary || NEW.terminology_notes || NEW.warnings) AS items(item)
                WHERE jsonb_typeof(items.item) <> 'string'
              ) THEN
                RAISE EXCEPTION 'Completed finalization runs require string proposal lists';
              END IF;
            WHEN 'review_rounds' THEN
              IF NOT EXISTS (
                SELECT 1 FROM review_runs WHERE review_round_id = NEW.id
              ) OR EXISTS (
                SELECT 1 FROM review_runs
                WHERE review_round_id = NEW.id AND status NOT IN ('completed', 'failed')
              ) THEN
                RAISE EXCEPTION 'Completed review rounds require terminal review runs';
              END IF;
              IF EXISTS (
                SELECT 1 FROM review_runs WHERE review_round_id = NEW.id AND status = 'failed'
              ) THEN
                RAISE EXCEPTION 'Completed review rounds cannot contain failed review runs';
              END IF;
            WHEN 'judge_rounds' THEN
              IF NOT EXISTS (
                SELECT 1 FROM judge_runs WHERE judge_round_id = NEW.id
              ) OR EXISTS (
                SELECT 1 FROM judge_runs
                WHERE judge_round_id = NEW.id AND status NOT IN ('completed', 'failed')
              ) THEN
                RAISE EXCEPTION 'Completed judge rounds require terminal judge runs';
              END IF;
              IF EXISTS (
                SELECT 1 FROM judge_runs WHERE judge_round_id = NEW.id AND status = 'failed'
              ) THEN
                RAISE EXCEPTION 'Completed judge rounds cannot contain failed judge runs';
              END IF;
              IF NEW.winner_translation_run_id IS NULL
                 OR NOT EXISTS (
                   SELECT 1 FROM judge_evaluations evaluations
                   JOIN judge_runs runs ON runs.id = evaluations.judge_run_id
                   WHERE runs.judge_round_id = NEW.id
                     AND evaluations.translation_run_id = NEW.winner_translation_run_id
                 ) THEN
                RAISE EXCEPTION 'Completed judge rounds require an evaluated winner';
              END IF;
            WHEN 'finalization_rounds' THEN
              IF NOT EXISTS (
                SELECT 1 FROM finalization_runs WHERE finalization_round_id = NEW.id
              ) OR EXISTS (
                SELECT 1 FROM finalization_runs
                WHERE finalization_round_id = NEW.id AND status NOT IN ('completed', 'failed')
              ) THEN
                RAISE EXCEPTION 'Completed finalization rounds require terminal finalization runs';
              END IF;
              IF EXISTS (
                SELECT 1 FROM finalization_runs
                WHERE finalization_round_id = NEW.id AND status = 'failed'
              ) THEN
                RAISE EXCEPTION 'Completed finalization rounds cannot contain failed finalization runs';
              END IF;
            ELSE
              NULL;
            END CASE;
          END IF;
        END IF;

        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
      END;
      $$;

      CREATE FUNCTION prevent_terminal_evaluation_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        old_parent_id bigint;
        new_parent_id bigint;
        parent_status text;
      BEGIN
        IF TG_OP <> 'INSERT' THEN
          old_parent_id := (to_jsonb(OLD)->>TG_ARGV[1])::bigint;
          EXECUTE format('SELECT status FROM %I WHERE id = $1 FOR UPDATE', TG_ARGV[0])
            INTO parent_status USING old_parent_id;
          IF parent_status = 'completed' THEN
            RAISE EXCEPTION 'Completed evaluation results are immutable';
          END IF;
        END IF;

        IF TG_OP <> 'DELETE' THEN
          new_parent_id := (to_jsonb(NEW)->>TG_ARGV[1])::bigint;
          IF TG_OP = 'INSERT' OR new_parent_id <> old_parent_id THEN
            EXECUTE format('SELECT status FROM %I WHERE id = $1 FOR UPDATE', TG_ARGV[0])
              INTO parent_status USING new_parent_id;
            IF parent_status = 'completed' THEN
              RAISE EXCEPTION 'Completed evaluation results are immutable';
            END IF;
          END IF;
        END IF;

        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
      END;
      $$;
    SQL
  end

  def create_provider_attempt_functions
    execute <<~SQL
      CREATE FUNCTION prevent_provider_attempt_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP = 'DELETE' OR OLD.status IN ('completed', 'failed') THEN
          RAISE EXCEPTION 'Historical provider attempts are immutable';
        END IF;
        IF OLD.provider_run_type IS DISTINCT FROM NEW.provider_run_type OR
           OLD.provider_run_id IS DISTINCT FROM NEW.provider_run_id OR
           OLD.attempt_number IS DISTINCT FROM NEW.attempt_number OR
           OLD.stage IS DISTINCT FROM NEW.stage OR
           OLD.gateway_snapshot IS DISTINCT FROM NEW.gateway_snapshot OR
           OLD.provider_snapshot IS DISTINCT FROM NEW.provider_snapshot OR
           OLD.model_identifier_snapshot IS DISTINCT FROM NEW.model_identifier_snapshot OR
           OLD.display_name_snapshot IS DISTINCT FROM NEW.display_name_snapshot OR
           OLD.started_at IS DISTINCT FROM NEW.started_at OR
           OLD.created_at IS DISTINCT FROM NEW.created_at THEN
          RAISE EXCEPTION 'Provider attempt identity and routing snapshots are immutable';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION enforce_provider_attempt_lineage()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        parent_exists boolean;
        expected_stage text;
      BEGIN
        CASE NEW.provider_run_type
        WHEN 'TranslationRun' THEN
          expected_stage := 'translation';
          SELECT TRUE INTO parent_exists FROM translation_runs
           WHERE id = NEW.provider_run_id FOR KEY SHARE;
        WHEN 'TranslationSegmentRun' THEN
          expected_stage := 'translation';
          SELECT TRUE INTO parent_exists FROM translation_segment_runs
           WHERE id = NEW.provider_run_id FOR KEY SHARE;
        WHEN 'ReviewRun' THEN
          expected_stage := 'review';
          SELECT TRUE INTO parent_exists FROM review_runs
           WHERE id = NEW.provider_run_id FOR KEY SHARE;
        WHEN 'ReviewSegmentRun' THEN
          expected_stage := 'review';
          SELECT TRUE INTO parent_exists FROM review_segment_runs
           WHERE id = NEW.provider_run_id FOR KEY SHARE;
        WHEN 'JudgeRun' THEN
          expected_stage := 'judge';
          SELECT TRUE INTO parent_exists FROM judge_runs
           WHERE id = NEW.provider_run_id FOR KEY SHARE;
        WHEN 'JudgeSegmentRun' THEN
          expected_stage := 'judge';
          SELECT TRUE INTO parent_exists FROM judge_segment_runs
           WHERE id = NEW.provider_run_id FOR KEY SHARE;
        WHEN 'FinalizationRun' THEN
          expected_stage := 'finalization';
          SELECT TRUE INTO parent_exists FROM finalization_runs
           WHERE id = NEW.provider_run_id FOR KEY SHARE;
        WHEN 'FinalizationSegmentRun' THEN
          expected_stage := 'finalization';
          SELECT TRUE INTO parent_exists FROM finalization_segment_runs
           WHERE id = NEW.provider_run_id FOR KEY SHARE;
        ELSE
          RAISE EXCEPTION 'Unsupported provider run type';
        END CASE;

        IF parent_exists IS DISTINCT FROM TRUE OR NEW.stage <> expected_stage THEN
          RAISE EXCEPTION 'Provider attempt run and stage must match';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION restrict_provider_run_deletion()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM ai_provider_attempts
          WHERE provider_run_type = TG_ARGV[0] AND provider_run_id = OLD.id
        ) THEN
          RAISE EXCEPTION 'Provider runs with attempt history cannot be deleted';
        END IF;
        RETURN OLD;
      END;
      $$;
    SQL
  end

  def create_lineage_functions
    execute <<~SQL
      CREATE FUNCTION enforce_segment_lineage()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        parent_experiment_id bigint;
        segment_experiment_id bigint;
      BEGIN
        SELECT plans.experiment_id
          INTO segment_experiment_id
          FROM experiment_segments segments
          JOIN document_execution_plans plans ON plans.id = segments.document_execution_plan_id
         WHERE segments.id = NEW.experiment_segment_id;

        CASE TG_TABLE_NAME
        WHEN 'translation_segment_runs' THEN
          SELECT experiment_id INTO parent_experiment_id FROM translation_runs WHERE id = NEW.translation_run_id;
        WHEN 'review_segment_runs' THEN
          SELECT rounds.experiment_id INTO parent_experiment_id
            FROM review_runs runs JOIN review_rounds rounds ON rounds.id = runs.review_round_id
           WHERE runs.id = NEW.review_run_id;
        WHEN 'judge_segment_runs' THEN
          SELECT review_rounds.experiment_id INTO parent_experiment_id
            FROM judge_runs runs
            JOIN judge_rounds rounds ON rounds.id = runs.judge_round_id
            JOIN review_rounds ON review_rounds.id = rounds.review_round_id
           WHERE runs.id = NEW.judge_run_id;
        WHEN 'finalization_segment_runs' THEN
          SELECT translations.experiment_id INTO parent_experiment_id
            FROM finalization_runs runs
            JOIN finalization_rounds rounds ON rounds.id = runs.finalization_round_id
            JOIN final_translations translations ON translations.id = rounds.final_translation_id
           WHERE runs.id = NEW.finalization_run_id;
        WHEN 'final_translation_version_segments' THEN
          SELECT translations.experiment_id INTO parent_experiment_id
            FROM final_translation_versions versions
            JOIN final_translations translations ON translations.id = versions.final_translation_id
           WHERE versions.id = NEW.final_translation_version_id;
        ELSE
          RAISE EXCEPTION 'Unsupported segmented lineage table';
        END CASE;

        IF parent_experiment_id IS NULL OR segment_experiment_id IS NULL OR parent_experiment_id <> segment_experiment_id THEN
          RAISE EXCEPTION 'Segment must belong to the parent experiment';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION enforce_evaluation_lineage()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        parent_experiment_id bigint;
        candidate_experiment_id bigint;
      BEGIN
        SELECT experiment_id INTO candidate_experiment_id FROM translation_runs WHERE id = NEW.translation_run_id;
        IF TG_TABLE_NAME = 'review_evaluations' THEN
          SELECT rounds.experiment_id INTO parent_experiment_id
            FROM review_runs runs JOIN review_rounds rounds ON rounds.id = runs.review_round_id
           WHERE runs.id = NEW.review_run_id;
        ELSE
          SELECT review_rounds.experiment_id INTO parent_experiment_id
            FROM judge_runs runs
            JOIN judge_rounds rounds ON rounds.id = runs.judge_round_id
            JOIN review_rounds ON review_rounds.id = rounds.review_round_id
           WHERE runs.id = NEW.judge_run_id;
        END IF;
        IF parent_experiment_id IS NULL OR candidate_experiment_id IS NULL OR parent_experiment_id <> candidate_experiment_id THEN
          RAISE EXCEPTION 'Evaluation candidate must belong to the reviewed experiment';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION enforce_judge_winner_lineage()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        judged_experiment_id bigint;
        winner_experiment_id bigint;
      BEGIN
        IF NEW.winner_translation_run_id IS NULL THEN RETURN NEW; END IF;
        IF NOT EXISTS (
          SELECT 1 FROM translation_runs
           WHERE id = NEW.winner_translation_run_id AND status = 'completed'
        ) THEN
          RAISE EXCEPTION 'Judge winner must be a completed translation';
        END IF;
        IF TG_TABLE_NAME = 'judge_rounds' THEN
          SELECT experiment_id INTO judged_experiment_id FROM review_rounds WHERE id = NEW.review_round_id;
          IF NOT EXISTS (
            SELECT 1
              FROM judge_evaluations evaluations
              JOIN judge_runs runs ON runs.id = evaluations.judge_run_id
             WHERE runs.judge_round_id = NEW.id
               AND evaluations.translation_run_id = NEW.winner_translation_run_id
          ) THEN
            RAISE EXCEPTION 'Judge round winner must be an evaluated candidate';
          END IF;
        ELSE
          SELECT reviews.experiment_id INTO judged_experiment_id
            FROM judge_rounds rounds
            JOIN review_rounds reviews ON reviews.id = rounds.review_round_id
           WHERE rounds.id = NEW.judge_round_id;
          IF NOT EXISTS (
            SELECT 1
              FROM judge_evaluations evaluations
             WHERE evaluations.judge_run_id = NEW.id
               AND evaluations.translation_run_id = NEW.winner_translation_run_id
               AND evaluations.rank = 1
               AND evaluations.overall_score IS NOT NULL
               AND BTRIM(evaluations.rationale) <> ''
               AND BTRIM(evaluations.strengths) <> ''
               AND BTRIM(evaluations.risks) <> ''
          ) THEN
            RAISE EXCEPTION 'Judge run winner must be its complete rank-one evaluation';
          END IF;
        END IF;
        SELECT experiment_id INTO winner_experiment_id
          FROM translation_runs WHERE id = NEW.winner_translation_run_id;
        IF judged_experiment_id IS NULL OR winner_experiment_id IS NULL OR judged_experiment_id <> winner_experiment_id THEN
          RAISE EXCEPTION 'Judge winner must belong to the judged experiment';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION prevent_segment_parent_lineage_change()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        child_exists boolean;
      BEGIN
        IF (to_jsonb(OLD)->>TG_ARGV[0]) IS NOT DISTINCT FROM (to_jsonb(NEW)->>TG_ARGV[0]) THEN
          RETURN NEW;
        END IF;

        CASE TG_TABLE_NAME
        WHEN 'translation_runs' THEN
          SELECT EXISTS (
            SELECT 1 FROM translation_segment_runs WHERE translation_run_id = OLD.id
          ) OR EXISTS (
            SELECT 1 FROM review_evaluations WHERE translation_run_id = OLD.id
          ) OR EXISTS (
            SELECT 1 FROM judge_evaluations WHERE translation_run_id = OLD.id
          ) INTO child_exists;
        WHEN 'review_runs' THEN
          SELECT EXISTS (
            SELECT 1 FROM review_segment_runs WHERE review_run_id = OLD.id
          ) OR EXISTS (
            SELECT 1 FROM review_evaluations WHERE review_run_id = OLD.id
          ) INTO child_exists;
        WHEN 'review_rounds' THEN
          SELECT EXISTS (
            SELECT 1 FROM review_segment_runs segments
            JOIN review_runs runs ON runs.id = segments.review_run_id
            WHERE runs.review_round_id = OLD.id
          ) OR EXISTS (
            SELECT 1 FROM judge_segment_runs segments
            JOIN judge_runs runs ON runs.id = segments.judge_run_id
            JOIN judge_rounds rounds ON rounds.id = runs.judge_round_id
            WHERE rounds.review_round_id = OLD.id
          ) OR EXISTS (
            SELECT 1 FROM review_evaluations evaluations
            JOIN review_runs runs ON runs.id = evaluations.review_run_id
            WHERE runs.review_round_id = OLD.id
          ) OR EXISTS (
            SELECT 1 FROM judge_evaluations evaluations
            JOIN judge_runs runs ON runs.id = evaluations.judge_run_id
            JOIN judge_rounds rounds ON rounds.id = runs.judge_round_id
            WHERE rounds.review_round_id = OLD.id
          ) INTO child_exists;
        WHEN 'judge_runs' THEN
          SELECT EXISTS (
            SELECT 1 FROM judge_segment_runs WHERE judge_run_id = OLD.id
          ) OR EXISTS (
            SELECT 1 FROM judge_evaluations WHERE judge_run_id = OLD.id
          ) INTO child_exists;
        WHEN 'judge_rounds' THEN
          SELECT EXISTS (
            SELECT 1 FROM judge_segment_runs segments
            JOIN judge_runs runs ON runs.id = segments.judge_run_id
            WHERE runs.judge_round_id = OLD.id
          ) OR EXISTS (
            SELECT 1 FROM judge_evaluations evaluations
            JOIN judge_runs runs ON runs.id = evaluations.judge_run_id
            WHERE runs.judge_round_id = OLD.id
          ) INTO child_exists;
        WHEN 'finalization_runs' THEN
          SELECT EXISTS (
            SELECT 1 FROM finalization_segment_runs WHERE finalization_run_id = OLD.id
          ) OR EXISTS (
            SELECT 1 FROM final_translation_versions WHERE source_finalization_run_id = OLD.id
          ) INTO child_exists;
        WHEN 'finalization_rounds' THEN
          SELECT EXISTS (
            SELECT 1 FROM finalization_segment_runs segments
            JOIN finalization_runs runs ON runs.id = segments.finalization_run_id
            WHERE runs.finalization_round_id = OLD.id
          ) OR EXISTS (
            SELECT 1 FROM final_translation_versions versions
            JOIN finalization_runs runs ON runs.id = versions.source_finalization_run_id
            WHERE runs.finalization_round_id = OLD.id
          ) INTO child_exists;
        WHEN 'final_translations' THEN
          SELECT EXISTS (
            SELECT 1 FROM finalization_segment_runs segments
            JOIN finalization_runs runs ON runs.id = segments.finalization_run_id
            JOIN finalization_rounds rounds ON rounds.id = runs.finalization_round_id
            WHERE rounds.final_translation_id = OLD.id
          ) OR EXISTS (
            SELECT 1 FROM final_translation_version_segments segments
            JOIN final_translation_versions versions ON versions.id = segments.final_translation_version_id
            WHERE versions.final_translation_id = OLD.id
          ) INTO child_exists;
        ELSE
          RAISE EXCEPTION 'Unsupported segmented lineage parent table';
        END CASE;

        IF child_exists THEN
          RAISE EXCEPTION 'Historical lineage parent cannot change after child records exist';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION enforce_owned_workflow_lineage()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        left_owner_id bigint;
        right_owner_id bigint;
      BEGIN
        IF TG_TABLE_NAME = 'pipeline_runs' THEN
          SELECT projects.user_id INTO left_owner_id
            FROM experiments JOIN documents ON documents.id = experiments.document_id
            JOIN projects ON projects.id = documents.project_id
           WHERE experiments.id = NEW.experiment_id;
          SELECT profiles.user_id INTO right_owner_id
            FROM workflow_profile_revisions revisions
            JOIN workflow_profiles profiles ON profiles.id = revisions.workflow_profile_id
           WHERE revisions.id = NEW.workflow_profile_revision_id;
          IF NEW.finalization_round_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM finalization_rounds rounds
            JOIN final_translations translations ON translations.id = rounds.final_translation_id
            WHERE rounds.id = NEW.finalization_round_id AND translations.experiment_id = NEW.experiment_id
          ) THEN
            RAISE EXCEPTION 'Pipeline finalization round must belong to its experiment';
          END IF;
        ELSIF TG_TABLE_NAME = 'source_imports' THEN
          IF NEW.resulting_document_id IS NULL THEN RETURN NEW; END IF;
          left_owner_id := NEW.user_id;
          SELECT projects.user_id INTO right_owner_id
            FROM documents JOIN projects ON projects.id = documents.project_id
           WHERE documents.id = NEW.resulting_document_id;
        ELSE
          IF NEW.experiment_id IS NULL THEN RETURN NEW; END IF;
          left_owner_id := NEW.user_id;
          SELECT projects.user_id INTO right_owner_id
            FROM experiments JOIN documents ON documents.id = experiments.document_id
            JOIN projects ON projects.id = documents.project_id
           WHERE experiments.id = NEW.experiment_id;
        END IF;

        IF left_owner_id IS NULL OR right_owner_id IS NULL OR left_owner_id <> right_owner_id THEN
          RAISE EXCEPTION 'Referenced workflow records must have the same owner';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION enforce_final_version_lineage()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        run_translation_id bigint;
      BEGIN
        IF NEW.source_finalization_run_id IS NULL THEN RETURN NEW; END IF;
        SELECT rounds.final_translation_id INTO run_translation_id
          FROM finalization_runs runs
          JOIN finalization_rounds rounds ON rounds.id = runs.finalization_round_id
         WHERE runs.id = NEW.source_finalization_run_id;
        IF run_translation_id IS NULL OR run_translation_id <> NEW.final_translation_id THEN
          RAISE EXCEPTION 'Finalization source run must belong to the final translation';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL
  end

  def create_revision_sequence_function
    execute <<~SQL
      CREATE FUNCTION enforce_revision_sequence()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        parent_id bigint;
        next_version integer;
      BEGIN
        parent_id := (to_jsonb(NEW)->>TG_ARGV[1])::bigint;
        EXECUTE format('SELECT 1 FROM %I WHERE id = $1 FOR UPDATE', TG_ARGV[0]) USING parent_id;
        EXECUTE format(
          'SELECT COALESCE(MAX(version), 0) + 1 FROM %I WHERE %I = $1',
          TG_TABLE_NAME, TG_ARGV[1]
        ) INTO next_version USING parent_id;
        IF NEW.version <> next_version THEN
          RAISE EXCEPTION 'Revision version must be the next monotonic value';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION enforce_final_version_sequence()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        next_version integer;
      BEGIN
        PERFORM 1 FROM final_translations WHERE id = NEW.final_translation_id FOR UPDATE;
        SELECT COALESCE(MAX(version_number), 0) + 1 INTO next_version
          FROM final_translation_versions
         WHERE final_translation_id = NEW.final_translation_id;
        IF NEW.version_number <> next_version THEN
          RAISE EXCEPTION 'Final translation version must be the next monotonic value';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL
  end

  def install_triggers
    IMMUTABLE_TABLES.each do |table|
      create_trigger(table, "prevent_#{table}_mutation", "BEFORE UPDATE OR DELETE", "prevent_immutable_row_mutation()")
    end

    (PROVIDER_RUNS.keys + COMPLETED_RECORD_TABLES).each do |table|
      create_trigger(table, "prevent_completed_#{table}_mutation", "BEFORE INSERT OR UPDATE OR DELETE", "prevent_completed_record_mutation()")
    end

    create_trigger(:ai_provider_attempts, "prevent_ai_provider_attempt_mutation", "BEFORE UPDATE OR DELETE", "prevent_provider_attempt_mutation()")
    create_trigger(:ai_provider_attempts, "enforce_ai_provider_attempt_lineage", "BEFORE INSERT OR UPDATE OF provider_run_type, provider_run_id, stage", "enforce_provider_attempt_lineage()")

    PROVIDER_RUNS.each do |table, run_type|
      create_trigger(table, "restrict_#{table}_attempt_deletion", "BEFORE DELETE", "restrict_provider_run_deletion('#{run_type}')")
    end

    %i[translation_segment_runs review_segment_runs judge_segment_runs finalization_segment_runs].each do |table|
      parent = table.to_s.sub("_segment_runs", "_run_id")
      create_trigger(table, "enforce_#{table}_lineage", "BEFORE INSERT OR UPDATE OF #{parent}, experiment_segment_id", "enforce_segment_lineage()")
    end
    create_trigger(:final_translation_version_segments, "enforce_final_version_segment_lineage", "BEFORE INSERT OR UPDATE OF final_translation_version_id, experiment_segment_id", "enforce_segment_lineage()")

    {
      translation_runs: :experiment_id,
      review_runs: :review_round_id,
      review_rounds: :experiment_id,
      judge_runs: :judge_round_id,
      judge_rounds: :review_round_id,
      finalization_runs: :finalization_round_id,
      finalization_rounds: :final_translation_id,
      final_translations: :experiment_id
    }.each do |table, column|
      create_trigger(
        table,
        "prevent_#{table}_segment_parent_change",
        "BEFORE UPDATE OF #{column}",
        "prevent_segment_parent_lineage_change('#{column}')"
      )
    end

    create_trigger(:review_evaluations, "enforce_review_evaluation_lineage", "BEFORE INSERT OR UPDATE OF review_run_id, translation_run_id", "enforce_evaluation_lineage()")
    create_trigger(:judge_evaluations, "enforce_judge_evaluation_lineage", "BEFORE INSERT OR UPDATE OF judge_run_id, translation_run_id", "enforce_evaluation_lineage()")
    create_trigger(:review_evaluations, "prevent_completed_review_evaluation_mutation", "BEFORE INSERT OR UPDATE OR DELETE", "prevent_terminal_evaluation_mutation('review_runs', 'review_run_id')")
    create_trigger(:judge_evaluations, "prevent_completed_judge_evaluation_mutation", "BEFORE INSERT OR UPDATE OR DELETE", "prevent_terminal_evaluation_mutation('judge_runs', 'judge_run_id')")
    create_trigger(:judge_rounds, "enforce_judge_round_winner_lineage", "BEFORE INSERT OR UPDATE OF review_round_id, winner_translation_run_id", "enforce_judge_winner_lineage()")
    create_trigger(:judge_runs, "enforce_judge_run_winner_lineage", "BEFORE INSERT OR UPDATE OF judge_round_id, winner_translation_run_id", "enforce_judge_winner_lineage()")

    create_trigger(:pipeline_runs, "enforce_pipeline_owner_lineage", "BEFORE INSERT OR UPDATE OF experiment_id, workflow_profile_revision_id, finalization_round_id", "enforce_owned_workflow_lineage()")
    create_trigger(:source_imports, "enforce_source_import_owner_lineage", "BEFORE INSERT OR UPDATE OF user_id, resulting_document_id", "enforce_owned_workflow_lineage()")
    create_trigger(:translation_workspace_submissions, "enforce_workspace_submission_owner_lineage", "BEFORE INSERT OR UPDATE OF user_id, experiment_id", "enforce_owned_workflow_lineage()")
    create_trigger(:final_translation_versions, "enforce_final_version_source_lineage", "BEFORE INSERT OR UPDATE OF final_translation_id, source_finalization_run_id", "enforce_final_version_lineage()")
    create_trigger(:final_translation_versions, "enforce_final_version_sequence", "BEFORE INSERT", "enforce_final_version_sequence()")

    {
      workflow_profile_revisions: %w[workflow_profiles workflow_profile_id],
      glossary_revisions: %w[glossaries glossary_id],
      methodology_profile_revisions: %w[methodology_profiles methodology_profile_id],
      translation_reference_revisions: %w[translation_references translation_reference_id]
    }.each do |table, (parent_table, parent_column)|
      create_trigger(table, "enforce_#{table}_sequence", "BEFORE INSERT", "enforce_revision_sequence('#{parent_table}', '#{parent_column}')")
    end
  end

  def create_trigger(table, name, timing, function)
    execute <<~SQL
      CREATE TRIGGER #{quote_column_name(name)}
      #{timing} ON #{quote_table_name(table)}
      FOR EACH ROW EXECUTE FUNCTION #{function};
    SQL
  end

  def trigger_names
    names = IMMUTABLE_TABLES.map { |table| [ table, "prevent_#{table}_mutation" ] }
    names += (PROVIDER_RUNS.keys + COMPLETED_RECORD_TABLES).map { |table| [ table, "prevent_completed_#{table}_mutation" ] }
    names += [
      [ :ai_provider_attempts, "prevent_ai_provider_attempt_mutation" ],
      [ :ai_provider_attempts, "enforce_ai_provider_attempt_lineage" ],
      [ :final_translation_version_segments, "enforce_final_version_segment_lineage" ],
      [ :review_evaluations, "enforce_review_evaluation_lineage" ],
      [ :judge_evaluations, "enforce_judge_evaluation_lineage" ],
      [ :review_evaluations, "prevent_completed_review_evaluation_mutation" ],
      [ :judge_evaluations, "prevent_completed_judge_evaluation_mutation" ],
      [ :judge_rounds, "enforce_judge_round_winner_lineage" ],
      [ :judge_runs, "enforce_judge_run_winner_lineage" ],
      [ :pipeline_runs, "enforce_pipeline_owner_lineage" ],
      [ :source_imports, "enforce_source_import_owner_lineage" ],
      [ :translation_workspace_submissions, "enforce_workspace_submission_owner_lineage" ],
      [ :final_translation_versions, "enforce_final_version_source_lineage" ],
      [ :final_translation_versions, "enforce_final_version_sequence" ]
    ]
    names += PROVIDER_RUNS.keys.map { |table| [ table, "restrict_#{table}_attempt_deletion" ] }
    names += %i[translation_segment_runs review_segment_runs judge_segment_runs finalization_segment_runs].map do |table|
      [ table, "enforce_#{table}_lineage" ]
    end
    names += %i[
      translation_runs review_runs review_rounds judge_runs judge_rounds
      finalization_runs finalization_rounds final_translations
    ].map { |table| [ table, "prevent_#{table}_segment_parent_change" ] }
    names + %i[
      workflow_profile_revisions glossary_revisions methodology_profile_revisions translation_reference_revisions
    ].map { |table| [ table, "enforce_#{table}_sequence" ] }
  end
end
