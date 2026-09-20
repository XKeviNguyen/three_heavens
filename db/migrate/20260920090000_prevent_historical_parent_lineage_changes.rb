class PreventHistoricalParentLineageChanges < ActiveRecord::Migration[8.1]
  PARENT_COLUMNS = {
    translation_runs: :experiment_id,
    review_runs: :review_round_id,
    review_rounds: :experiment_id,
    judge_runs: :judge_round_id,
    judge_rounds: :review_round_id,
    finalization_runs: :finalization_round_id,
    finalization_rounds: :final_translation_id,
    final_translations: :experiment_id
  }.freeze

  LEGACY_FUNCTION_SQL = <<~SQL.freeze
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
  SQL

  def up
    execute <<~SQL
      CREATE FUNCTION prevent_parent_lineage_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF (to_jsonb(OLD)->>TG_ARGV[0]) IS DISTINCT FROM (to_jsonb(NEW)->>TG_ARGV[0]) THEN
          RAISE EXCEPTION 'Historical parent lineage cannot change after creation'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL

    PARENT_COLUMNS.each do |table, column|
      execute "DROP TRIGGER IF EXISTS #{quote_column_name("prevent_#{table}_segment_parent_change")} ON #{quote_table_name(table)}"
      execute <<~SQL
        CREATE TRIGGER #{quote_column_name("prevent_#{table}_parent_mutation")}
        BEFORE UPDATE OF #{quote_column_name(column)} ON #{quote_table_name(table)}
        FOR EACH ROW EXECUTE FUNCTION prevent_parent_lineage_mutation('#{column}');
      SQL
    end

    execute "DROP FUNCTION IF EXISTS prevent_segment_parent_lineage_change()"
  end

  def down
    PARENT_COLUMNS.each_key do |table|
      execute "DROP TRIGGER IF EXISTS #{quote_column_name("prevent_#{table}_parent_mutation")} ON #{quote_table_name(table)}"
    end
    execute "DROP FUNCTION IF EXISTS prevent_parent_lineage_mutation()"

    execute LEGACY_FUNCTION_SQL

    PARENT_COLUMNS.each do |table, column|
      execute <<~SQL
        CREATE TRIGGER #{quote_column_name("prevent_#{table}_segment_parent_change")}
        BEFORE UPDATE OF #{quote_column_name(column)} ON #{quote_table_name(table)}
        FOR EACH ROW EXECUTE FUNCTION prevent_segment_parent_lineage_change('#{column}');
      SQL
    end
  end
end
