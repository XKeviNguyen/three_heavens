class HardenMethodologySnapshotIntegrity < ActiveRecord::Migration[8.1]
  def up
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    execute <<~SQL
      LOCK TABLE methodology_profile_revisions, methodology_profiles, experiments, documents, projects
      IN SHARE ROW EXCLUSIVE MODE;

      CREATE FUNCTION methodology_revision_configuration_digest(
        source_language text,
        target_language text,
        guidance text
      )
      RETURNS text
      LANGUAGE sql
      IMMUTABLE
      STRICT
      AS $$
        SELECT encode(digest(
          '{"source_language":' || to_json(source_language)::text ||
          ',"target_language":' || to_json(target_language)::text ||
          ',"guidance":' || to_json(guidance)::text || '}',
          'sha256'
        ), 'hex');
      $$;

      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1
          FROM methodology_profile_revisions
          WHERE configuration_digest <> methodology_revision_configuration_digest(
            source_language,
            target_language,
            guidance
          )
        ) THEN
          RAISE EXCEPTION 'Existing methodology revision configuration digest does not match its payload';
        END IF;
      END;
      $$;
    SQL

    add_check_constraint :methodology_profile_revisions,
                         <<~SQL.squish,
                           configuration_digest = methodology_revision_configuration_digest(
                             source_language,
                             target_language,
                             guidance
                           )
                         SQL
                         name: "methodology_profile_revisions_payload_digest_check"

    execute <<~SQL
      DROP TRIGGER enforce_experiment_methodology_snapshot_trigger ON experiments;

      CREATE OR REPLACE FUNCTION enforce_experiment_methodology_snapshot()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        project_id bigint;
        methodology_profile_id bigint;
      BEGIN
        IF TG_OP = 'UPDATE'
           AND OLD.methodology_profile_revision_id IS DISTINCT FROM NEW.methodology_profile_revision_id THEN
          RAISE EXCEPTION 'Experiment methodology revision cannot change after creation'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.methodology_profile_revision_id IS NULL THEN
          RETURN NEW;
        END IF;

        PERFORM pg_advisory_xact_lock(hashtextextended('document:' || NEW.document_id::text, 0));
        SELECT documents.project_id INTO project_id FROM documents WHERE documents.id = NEW.document_id;
        PERFORM pg_advisory_xact_lock(hashtextextended('project:' || project_id::text, 0));
        SELECT methodology_profile_revisions.methodology_profile_id
          INTO methodology_profile_id
          FROM methodology_profile_revisions
          WHERE methodology_profile_revisions.id = NEW.methodology_profile_revision_id;
        PERFORM pg_advisory_xact_lock(hashtextextended('methodology:' || methodology_profile_id::text, 0));

        IF NOT EXISTS (
          SELECT 1
          FROM documents
          INNER JOIN projects ON projects.id = documents.project_id
          INNER JOIN methodology_profile_revisions
            ON methodology_profile_revisions.id = NEW.methodology_profile_revision_id
          INNER JOIN methodology_profiles
            ON methodology_profiles.id = methodology_profile_revisions.methodology_profile_id
          WHERE documents.id = NEW.document_id
            AND methodology_profiles.user_id = projects.user_id
            AND lower(btrim(methodology_profile_revisions.source_language)) = lower(btrim(projects.source_language))
            AND lower(btrim(methodology_profile_revisions.target_language)) = lower(btrim(projects.target_language))
        ) THEN
          RAISE EXCEPTION 'Experiment methodology revision is not available for this project and language pair'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION enforce_project_methodology_snapshots()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.id::text, 0));

        IF EXISTS (
          SELECT 1
          FROM experiments
          INNER JOIN documents ON documents.id = experiments.document_id
          INNER JOIN methodology_profile_revisions
            ON methodology_profile_revisions.id = experiments.methodology_profile_revision_id
          INNER JOIN methodology_profiles
            ON methodology_profiles.id = methodology_profile_revisions.methodology_profile_id
          WHERE documents.project_id = NEW.id
            AND (
              methodology_profiles.user_id <> NEW.user_id
              OR lower(btrim(methodology_profile_revisions.source_language)) <> lower(btrim(NEW.source_language))
              OR lower(btrim(methodology_profile_revisions.target_language)) <> lower(btrim(NEW.target_language))
            )
        ) THEN
          RAISE EXCEPTION 'Project change would invalidate an experiment methodology revision'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION enforce_document_methodology_snapshots()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('document:' || NEW.id::text, 0));
        PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.project_id::text, 0));

        IF EXISTS (
          SELECT 1
          FROM experiments
          INNER JOIN methodology_profile_revisions
            ON methodology_profile_revisions.id = experiments.methodology_profile_revision_id
          INNER JOIN methodology_profiles
            ON methodology_profiles.id = methodology_profile_revisions.methodology_profile_id
          INNER JOIN projects ON projects.id = NEW.project_id
          WHERE experiments.document_id = NEW.id
            AND (
              methodology_profiles.user_id <> projects.user_id
              OR lower(btrim(methodology_profile_revisions.source_language)) <> lower(btrim(projects.source_language))
              OR lower(btrim(methodology_profile_revisions.target_language)) <> lower(btrim(projects.target_language))
            )
        ) THEN
          RAISE EXCEPTION 'Document project change would invalidate an experiment methodology revision'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION enforce_methodology_profile_owner()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('methodology:' || NEW.id::text, 0));

        IF EXISTS (
          SELECT 1
          FROM methodology_profile_revisions
          INNER JOIN experiments
            ON experiments.methodology_profile_revision_id = methodology_profile_revisions.id
          INNER JOIN documents ON documents.id = experiments.document_id
          INNER JOIN projects ON projects.id = documents.project_id
          WHERE methodology_profile_revisions.methodology_profile_id = NEW.id
            AND projects.user_id <> NEW.user_id
        ) THEN
          RAISE EXCEPTION 'Methodology ownership change would invalidate an experiment methodology revision'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER enforce_experiment_methodology_snapshot_trigger
      AFTER INSERT OR UPDATE OF document_id, methodology_profile_revision_id ON experiments
      FOR EACH ROW EXECUTE FUNCTION enforce_experiment_methodology_snapshot();

      CREATE TRIGGER enforce_project_methodology_snapshots_trigger
      BEFORE UPDATE OF user_id, source_language, target_language ON projects
      FOR EACH ROW EXECUTE FUNCTION enforce_project_methodology_snapshots();

      CREATE TRIGGER enforce_document_methodology_snapshots_trigger
      BEFORE UPDATE OF project_id ON documents
      FOR EACH ROW EXECUTE FUNCTION enforce_document_methodology_snapshots();

      CREATE TRIGGER enforce_methodology_profile_owner_trigger
      BEFORE UPDATE OF user_id ON methodology_profiles
      FOR EACH ROW EXECUTE FUNCTION enforce_methodology_profile_owner();
    SQL
  end

  def down
    remove_check_constraint :methodology_profile_revisions,
                            name: "methodology_profile_revisions_payload_digest_check"

    execute <<~SQL
      DROP TRIGGER IF EXISTS enforce_methodology_profile_owner_trigger ON methodology_profiles;
      DROP TRIGGER IF EXISTS enforce_document_methodology_snapshots_trigger ON documents;
      DROP TRIGGER IF EXISTS enforce_project_methodology_snapshots_trigger ON projects;
      DROP TRIGGER IF EXISTS enforce_experiment_methodology_snapshot_trigger ON experiments;
      DROP FUNCTION IF EXISTS enforce_methodology_profile_owner();
      DROP FUNCTION IF EXISTS enforce_document_methodology_snapshots();
      DROP FUNCTION IF EXISTS enforce_project_methodology_snapshots();

      CREATE OR REPLACE FUNCTION enforce_experiment_methodology_snapshot()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP = 'UPDATE'
           AND OLD.methodology_profile_revision_id IS DISTINCT FROM NEW.methodology_profile_revision_id THEN
          RAISE EXCEPTION 'Experiment methodology revision cannot change after creation'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.methodology_profile_revision_id IS NULL THEN
          RETURN NEW;
        END IF;

        IF NOT EXISTS (
          SELECT 1
          FROM documents
          INNER JOIN projects ON projects.id = documents.project_id
          INNER JOIN methodology_profile_revisions
            ON methodology_profile_revisions.id = NEW.methodology_profile_revision_id
          INNER JOIN methodology_profiles
            ON methodology_profiles.id = methodology_profile_revisions.methodology_profile_id
          WHERE documents.id = NEW.document_id
            AND methodology_profiles.user_id = projects.user_id
            AND lower(btrim(methodology_profile_revisions.source_language)) = lower(btrim(projects.source_language))
            AND lower(btrim(methodology_profile_revisions.target_language)) = lower(btrim(projects.target_language))
        ) THEN
          RAISE EXCEPTION 'Experiment methodology revision is not available for this project and language pair'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER enforce_experiment_methodology_snapshot_trigger
      BEFORE INSERT OR UPDATE OF methodology_profile_revision_id ON experiments
      FOR EACH ROW EXECUTE FUNCTION enforce_experiment_methodology_snapshot();

      DROP FUNCTION IF EXISTS methodology_revision_configuration_digest(text, text, text);
    SQL
  end
end
