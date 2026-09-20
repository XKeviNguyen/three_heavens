class CorrectReferenceSnapshotSerialization < ActiveRecord::Migration[8.1]
  def up
    # Lock order: experiment row, document advisory, project advisory, reference
    # advisories in ID order. Parent UPDATE triggers already own their own row,
    # but no reference trigger requests those parent rows after advisory locks.
    # Read a document's project only after taking its advisory lock.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_new_experiment_reference_snapshot()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        document_id bigint;
        reference_id bigint;
        project_id bigint;
      BEGIN
        PERFORM 1 FROM experiments WHERE id = NEW.experiment_id FOR UPDATE;
        SELECT experiments.document_id INTO document_id FROM experiments WHERE id = NEW.experiment_id;
        PERFORM pg_advisory_xact_lock(hashtextextended('document:' || document_id::text, 0));
        SELECT documents.project_id INTO project_id FROM documents WHERE id = document_id;
        PERFORM pg_advisory_xact_lock(hashtextextended('project:' || project_id::text, 0));
        SELECT translation_reference_id INTO reference_id
          FROM translation_reference_revisions
          WHERE id = NEW.translation_reference_revision_id;
        PERFORM pg_advisory_xact_lock(hashtextextended('translation_reference:' || reference_id::text, 0));

        IF EXISTS (SELECT 1 FROM translation_runs WHERE experiment_id = NEW.experiment_id) THEN
          RAISE EXCEPTION 'Experiment reference snapshots must be selected before provider work starts'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NOT EXISTS (
          SELECT 1
          FROM experiments
          INNER JOIN documents ON documents.id = experiments.document_id
          INNER JOIN projects ON projects.id = documents.project_id
          INNER JOIN translation_reference_revisions
            ON translation_reference_revisions.id = NEW.translation_reference_revision_id
          INNER JOIN translation_references
            ON translation_references.id = translation_reference_revisions.translation_reference_id
          WHERE experiments.id = NEW.experiment_id
            AND translation_references.user_id = projects.user_id
            AND translation_references.active
            AND translation_references.current_revision_id = translation_reference_revisions.id
            AND lower(btrim(translation_reference_revisions.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) = lower(btrim(projects.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
            AND lower(btrim(translation_reference_revisions.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) = lower(btrim(projects.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
        ) THEN
          RAISE EXCEPTION 'Translation reference revision is not available for this experiment'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION enforce_experiment_reference_snapshots()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        project_id bigint;
      BEGIN
        -- UPDATE already owns the experiment row. Never request it after advisory locks.
        PERFORM pg_advisory_xact_lock(hashtextextended('document:' || NEW.document_id::text, 0));
        SELECT documents.project_id INTO project_id FROM documents WHERE id = NEW.document_id;
        PERFORM pg_advisory_xact_lock(hashtextextended('project:' || project_id::text, 0));
        PERFORM pg_advisory_xact_lock(hashtextextended('translation_reference:' || reference_id::text, 0))
          FROM (
            SELECT DISTINCT revisions.translation_reference_id AS reference_id
            FROM experiment_reference_revisions snapshots
            JOIN translation_reference_revisions revisions ON revisions.id = snapshots.translation_reference_revision_id
            WHERE snapshots.experiment_id = NEW.id
            ORDER BY reference_id
          ) references_to_lock;

        IF EXISTS (
          SELECT 1
          FROM experiment_reference_revisions
          INNER JOIN translation_reference_revisions
            ON translation_reference_revisions.id = experiment_reference_revisions.translation_reference_revision_id
          INNER JOIN translation_references
            ON translation_references.id = translation_reference_revisions.translation_reference_id
          INNER JOIN documents ON documents.id = NEW.document_id
          INNER JOIN projects ON projects.id = documents.project_id
          WHERE experiment_reference_revisions.experiment_id = NEW.id
            AND (
              translation_references.user_id <> projects.user_id
              OR lower(btrim(translation_reference_revisions.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) <> lower(btrim(projects.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
              OR lower(btrim(translation_reference_revisions.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) <> lower(btrim(projects.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
            )
        ) THEN
          RAISE EXCEPTION 'Experiment change would invalidate a reference snapshot'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION enforce_project_reference_snapshots()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.id::text, 0));
        PERFORM pg_advisory_xact_lock(hashtextextended('translation_reference:' || reference_id::text, 0))
          FROM (
            SELECT DISTINCT revisions.translation_reference_id AS reference_id
            FROM experiment_reference_revisions snapshots
            JOIN translation_reference_revisions revisions ON revisions.id = snapshots.translation_reference_revision_id
            JOIN experiments ON experiments.id = snapshots.experiment_id
            JOIN documents ON documents.id = experiments.document_id
            WHERE documents.project_id = NEW.id
            ORDER BY reference_id
          ) references_to_lock;

        IF EXISTS (
          SELECT 1
          FROM documents
          INNER JOIN experiments ON experiments.document_id = documents.id
          INNER JOIN experiment_reference_revisions
            ON experiment_reference_revisions.experiment_id = experiments.id
          INNER JOIN translation_reference_revisions
            ON translation_reference_revisions.id = experiment_reference_revisions.translation_reference_revision_id
          INNER JOIN translation_references
            ON translation_references.id = translation_reference_revisions.translation_reference_id
          WHERE documents.project_id = NEW.id
            AND (
              translation_references.user_id <> NEW.user_id
              OR lower(btrim(translation_reference_revisions.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) <> lower(btrim(NEW.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
              OR lower(btrim(translation_reference_revisions.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) <> lower(btrim(NEW.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
            )
        ) THEN
          RAISE EXCEPTION 'Project change would invalidate an experiment reference snapshot'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION enforce_document_reference_snapshots()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('document:' || NEW.id::text, 0));
        PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.project_id::text, 0));
        PERFORM pg_advisory_xact_lock(hashtextextended('translation_reference:' || reference_id::text, 0))
          FROM (
            SELECT DISTINCT revisions.translation_reference_id AS reference_id
            FROM experiment_reference_revisions snapshots
            JOIN translation_reference_revisions revisions ON revisions.id = snapshots.translation_reference_revision_id
            JOIN experiments ON experiments.id = snapshots.experiment_id
            WHERE experiments.document_id = NEW.id
            ORDER BY reference_id
          ) references_to_lock;

        IF EXISTS (
          SELECT 1
          FROM experiments
          INNER JOIN experiment_reference_revisions
            ON experiment_reference_revisions.experiment_id = experiments.id
          INNER JOIN translation_reference_revisions
            ON translation_reference_revisions.id = experiment_reference_revisions.translation_reference_revision_id
          INNER JOIN translation_references
            ON translation_references.id = translation_reference_revisions.translation_reference_id
          INNER JOIN projects ON projects.id = NEW.project_id
          WHERE experiments.document_id = NEW.id
            AND (
              translation_references.user_id <> projects.user_id
              OR lower(btrim(translation_reference_revisions.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) <> lower(btrim(projects.source_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
              OR lower(btrim(translation_reference_revisions.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) <> lower(btrim(projects.target_language, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))
            )
        ) THEN
          RAISE EXCEPTION 'Document change would invalidate an experiment reference snapshot'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

    SQL
  end

  def down
    # Restoring the old functions reintroduces a deadlock and integrity races.
    # Roll back application code while retaining these compatible protections;
    # any database rollback requires a forward migration with equivalent integrity.
    raise ActiveRecord::IrreversibleMigration, "Reference integrity corrections must be retained"
  end
end
