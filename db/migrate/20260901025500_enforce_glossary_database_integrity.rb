class EnforceGlossaryDatabaseIntegrity < ActiveRecord::Migration[8.1]
  def up
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    execute <<~SQL
      LOCK TABLE glossary_revisions, glossary_entries, experiments, documents, projects, glossaries
      IN SHARE ROW EXCLUSIVE MODE;
    SQL

    execute <<~SQL
      CREATE FUNCTION glossary_revision_configuration_digest(revision_id bigint)
      RETURNS text
      LANGUAGE sql
      STABLE
      AS $$
        SELECT encode(digest(
          '{"source_language":' || to_json(glossary_revisions.source_language)::text ||
          ',"target_language":' || to_json(glossary_revisions.target_language)::text ||
          ',"entries":[' || COALESCE((
            SELECT string_agg(
              '{"position":' || position ||
              ',"source_term":' || to_json(source_term)::text ||
              ',"preferred_target_term":' || to_json(preferred_target_term)::text ||
              ',"note":' || COALESCE(to_json(note)::text, 'null') || '}',
              ',' ORDER BY position
            )
            FROM glossary_entries
            WHERE glossary_revision_id = glossary_revisions.id
          ), '') || ']}',
          'sha256'
        ), 'hex')
        FROM glossary_revisions
        WHERE id = revision_id;
      $$;
    SQL

    execute <<~SQL
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1
          FROM glossary_revisions
          WHERE (SELECT count(*) FROM glossary_entries WHERE glossary_revision_id = glossary_revisions.id) NOT BETWEEN 1 AND 100
             OR configuration_digest <> glossary_revision_configuration_digest(glossary_revisions.id)
        ) THEN
          RAISE EXCEPTION 'Existing glossary revisions must have 1-100 entries and a matching configuration digest';
        END IF;
      END;
      $$;
    SQL

    execute <<~SQL
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1
          FROM experiments
          INNER JOIN documents ON documents.id = experiments.document_id
          INNER JOIN projects ON projects.id = documents.project_id
          INNER JOIN glossary_revisions ON glossary_revisions.id = experiments.glossary_revision_id
          INNER JOIN glossaries ON glossaries.id = glossary_revisions.glossary_id
          WHERE experiments.glossary_revision_id IS NOT NULL
            AND projects.user_id <> glossaries.user_id
        ) THEN
          RAISE EXCEPTION 'Existing experiment glossary ownership integrity check failed';
        END IF;
      END;
      $$;
    SQL

    add_column :glossary_revisions, :entry_set_sealed, :boolean, default: true, null: false
    change_column_default :glossary_revisions, :entry_set_sealed, from: true, to: false

    execute <<~SQL
      CREATE FUNCTION enforce_experiment_glossary_owner()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        project_id bigint;
        glossary_id bigint;
      BEGIN
        IF NEW.glossary_revision_id IS NULL THEN
          RETURN NEW;
        END IF;

        PERFORM pg_advisory_xact_lock(hashtextextended('document:' || NEW.document_id::text, 0));
        SELECT documents.project_id INTO project_id FROM documents WHERE documents.id = NEW.document_id;
        PERFORM pg_advisory_xact_lock(hashtextextended('project:' || project_id::text, 0));
        SELECT glossary_revisions.glossary_id INTO glossary_id FROM glossary_revisions WHERE glossary_revisions.id = NEW.glossary_revision_id;
        PERFORM pg_advisory_xact_lock(hashtextextended('glossary:' || glossary_id::text, 0));

        IF NOT EXISTS (
          SELECT 1
          FROM documents
          INNER JOIN projects ON projects.id = documents.project_id
          INNER JOIN glossary_revisions ON glossary_revisions.id = NEW.glossary_revision_id
          INNER JOIN glossaries ON glossaries.id = glossary_revisions.glossary_id
          WHERE documents.id = NEW.document_id
            AND projects.user_id = glossaries.user_id
        ) THEN
          RAISE EXCEPTION 'Experiment glossary revision is not available for this project owner'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE FUNCTION enforce_project_glossary_owner()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.id::text, 0));

        IF EXISTS (
          SELECT 1
          FROM experiments
          INNER JOIN documents ON documents.id = experiments.document_id
          INNER JOIN glossary_revisions ON glossary_revisions.id = experiments.glossary_revision_id
          INNER JOIN glossaries ON glossaries.id = glossary_revisions.glossary_id
          WHERE documents.project_id = NEW.id
            AND glossaries.user_id <> NEW.user_id
        ) THEN
          RAISE EXCEPTION 'Project ownership change would invalidate an experiment glossary revision'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE FUNCTION enforce_document_glossary_owner()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('document:' || NEW.id::text, 0));
        PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.project_id::text, 0));

        IF EXISTS (
          SELECT 1
          FROM experiments
          INNER JOIN glossary_revisions ON glossary_revisions.id = experiments.glossary_revision_id
          INNER JOIN glossaries ON glossaries.id = glossary_revisions.glossary_id
          INNER JOIN projects ON projects.id = NEW.project_id
          WHERE experiments.document_id = NEW.id
            AND glossaries.user_id <> projects.user_id
        ) THEN
          RAISE EXCEPTION 'Document project change would invalidate an experiment glossary revision'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE FUNCTION enforce_glossary_owner()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('glossary:' || NEW.id::text, 0));

        IF EXISTS (
          SELECT 1
          FROM glossary_revisions
          INNER JOIN experiments ON experiments.glossary_revision_id = glossary_revisions.id
          INNER JOIN documents ON documents.id = experiments.document_id
          INNER JOIN projects ON projects.id = documents.project_id
          WHERE glossary_revisions.glossary_id = NEW.id
            AND projects.user_id <> NEW.user_id
        ) THEN
          RAISE EXCEPTION 'Glossary ownership change would invalidate an experiment glossary revision'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE FUNCTION prevent_glossary_revision_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'Glossary revisions cannot be deleted'
            USING ERRCODE = 'check_violation';
        END IF;

        IF OLD.entry_set_sealed = FALSE
           AND NEW.entry_set_sealed = TRUE
           AND (to_jsonb(NEW) - 'entry_set_sealed') = (to_jsonb(OLD) - 'entry_set_sealed') THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'Glossary revisions are immutable'
          USING ERRCODE = 'check_violation';
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE FUNCTION enforce_glossary_entry_set_seal()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        revision_id bigint;
      BEGIN
        revision_id := CASE WHEN TG_OP = 'INSERT' THEN NEW.glossary_revision_id ELSE OLD.glossary_revision_id END;

        IF EXISTS (
          SELECT 1 FROM glossary_revisions WHERE id = revision_id AND entry_set_sealed
        ) THEN
          RAISE EXCEPTION 'Glossary entry sets are sealed'
            USING ERRCODE = 'check_violation';
        END IF;

        IF TG_OP = 'UPDATE' AND NEW.glossary_revision_id <> OLD.glossary_revision_id AND EXISTS (
          SELECT 1 FROM glossary_revisions WHERE id = NEW.glossary_revision_id AND entry_set_sealed
        ) THEN
          RAISE EXCEPTION 'Glossary entry sets are sealed'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN COALESCE(NEW, OLD);
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE FUNCTION seal_glossary_revision_entry_set()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        entry_count integer;
      BEGIN
        SELECT count(*) INTO entry_count FROM glossary_entries WHERE glossary_revision_id = NEW.id;
        IF entry_count NOT BETWEEN 1 AND 100 THEN
          RAISE EXCEPTION 'Glossary revisions must have 1-100 entries'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.configuration_digest <> glossary_revision_configuration_digest(NEW.id) THEN
          RAISE EXCEPTION 'Glossary revision configuration digest does not match its entries'
            USING ERRCODE = 'check_violation';
        END IF;

        UPDATE glossary_revisions
        SET entry_set_sealed = TRUE
        WHERE id = NEW.id AND entry_set_sealed = FALSE;

        RETURN NULL;
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE TRIGGER enforce_experiment_glossary_owner_trigger
      AFTER INSERT OR UPDATE OF document_id, glossary_revision_id ON experiments
      FOR EACH ROW EXECUTE FUNCTION enforce_experiment_glossary_owner();

      CREATE TRIGGER enforce_project_glossary_owner_trigger
      BEFORE UPDATE OF user_id ON projects
      FOR EACH ROW EXECUTE FUNCTION enforce_project_glossary_owner();

      CREATE TRIGGER enforce_document_glossary_owner_trigger
      BEFORE UPDATE OF project_id ON documents
      FOR EACH ROW EXECUTE FUNCTION enforce_document_glossary_owner();

      CREATE TRIGGER enforce_glossary_owner_trigger
      BEFORE UPDATE OF user_id ON glossaries
      FOR EACH ROW EXECUTE FUNCTION enforce_glossary_owner();

      CREATE TRIGGER prevent_glossary_revision_mutation_trigger
      BEFORE UPDATE OR DELETE ON glossary_revisions
      FOR EACH ROW EXECUTE FUNCTION prevent_glossary_revision_mutation();

      CREATE TRIGGER enforce_glossary_entry_set_seal_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON glossary_entries
      FOR EACH ROW EXECUTE FUNCTION enforce_glossary_entry_set_seal();

      CREATE CONSTRAINT TRIGGER seal_glossary_revision_entry_set_trigger
      AFTER INSERT ON glossary_revisions
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION seal_glossary_revision_entry_set();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS seal_glossary_revision_entry_set_trigger ON glossary_revisions;
      DROP TRIGGER IF EXISTS enforce_glossary_entry_set_seal_trigger ON glossary_entries;
      DROP TRIGGER IF EXISTS prevent_glossary_revision_mutation_trigger ON glossary_revisions;
      DROP TRIGGER IF EXISTS enforce_glossary_owner_trigger ON glossaries;
      DROP TRIGGER IF EXISTS enforce_document_glossary_owner_trigger ON documents;
      DROP TRIGGER IF EXISTS enforce_project_glossary_owner_trigger ON projects;
      DROP TRIGGER IF EXISTS enforce_experiment_glossary_owner_trigger ON experiments;
      DROP FUNCTION IF EXISTS seal_glossary_revision_entry_set();
      DROP FUNCTION IF EXISTS enforce_glossary_entry_set_seal();
      DROP FUNCTION IF EXISTS prevent_glossary_revision_mutation();
      DROP FUNCTION IF EXISTS enforce_glossary_owner();
      DROP FUNCTION IF EXISTS enforce_document_glossary_owner();
      DROP FUNCTION IF EXISTS enforce_project_glossary_owner();
      DROP FUNCTION IF EXISTS enforce_experiment_glossary_owner();
      DROP FUNCTION IF EXISTS glossary_revision_configuration_digest(bigint);
    SQL

    remove_column :glossary_revisions, :entry_set_sealed
  end
end
