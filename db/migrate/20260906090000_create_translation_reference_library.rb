class CreateTranslationReferenceLibrary < ActiveRecord::Migration[8.1]
  def up
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    create_table :translation_references do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.bigint :current_revision_id
      t.boolean :active, null: false, default: true

      t.timestamps
    end
    add_index :translation_references, [ :user_id, :active ]

    create_table :translation_reference_revisions do |t|
      t.references :translation_reference, null: false, foreign_key: { on_delete: :restrict }
      t.integer :version, null: false
      t.string :title, null: false
      t.string :source_language, null: false
      t.string :target_language, null: false
      t.text :source_text, null: false
      t.text :approved_translation, null: false
      t.string :configuration_digest, null: false

      t.timestamps
    end
    add_index :translation_reference_revisions,
              [ :translation_reference_id, :version ],
              unique: true,
              name: "index_translation_reference_revisions_on_reference_and_version"
    add_index :translation_reference_revisions,
              [ :translation_reference_id, :id ],
              unique: true,
              name: "index_translation_reference_revisions_on_reference_and_id"
    add_index :translation_reference_revisions, :configuration_digest
    add_check_constraint :translation_reference_revisions,
                         "version > 0",
                         name: "translation_reference_revisions_version_check"
    add_check_constraint :translation_reference_revisions,
                         "char_length(btrim(title)) BETWEEN 1 AND 150",
                         name: "translation_reference_revisions_title_check"
    add_check_constraint :translation_reference_revisions,
                         "char_length(btrim(source_language)) BETWEEN 1 AND 100",
                         name: "translation_reference_revisions_source_language_check"
    add_check_constraint :translation_reference_revisions,
                         "char_length(btrim(target_language)) BETWEEN 1 AND 100",
                         name: "translation_reference_revisions_target_language_check"
    add_check_constraint :translation_reference_revisions,
                         "char_length(btrim(source_text)) BETWEEN 1 AND 100000",
                         name: "translation_reference_revisions_source_text_check"
    add_check_constraint :translation_reference_revisions,
                         "char_length(btrim(approved_translation)) BETWEEN 1 AND 100000",
                         name: "translation_reference_revisions_approved_translation_check"
    add_check_constraint :translation_reference_revisions,
                         "configuration_digest ~ '^[0-9a-f]{64}$'",
                         name: "translation_reference_revisions_digest_check"

    add_foreign_key :translation_references,
                    :translation_reference_revisions,
                    column: [ :id, :current_revision_id ],
                    primary_key: [ :translation_reference_id, :id ],
                    name: "fk_translation_references_owned_current_revision"

    create_table :experiment_reference_revisions do |t|
      t.references :experiment, null: false, foreign_key: { on_delete: :restrict }
      t.references :translation_reference_revision,
                   null: false,
                   foreign_key: { on_delete: :restrict },
                   index: false
      t.integer :position, null: false

      t.timestamps
    end
    add_index :experiment_reference_revisions,
              [ :experiment_id, :position ],
              unique: true,
              name: "index_experiment_reference_revisions_on_experiment_position"
    add_index :experiment_reference_revisions,
              [ :experiment_id, :translation_reference_revision_id ],
              unique: true,
              name: "index_experiment_reference_revisions_on_experiment_revision"
    add_index :experiment_reference_revisions,
              :translation_reference_revision_id,
              name: "index_experiment_reference_revisions_on_reference_revision"
    add_check_constraint :experiment_reference_revisions,
                         "position BETWEEN 1 AND 5",
                         name: "experiment_reference_revisions_position_check"

    add_column :experiments, :guidance_preference, :string
    execute <<~SQL
      UPDATE experiments
      SET guidance_preference = 'experiment_instruction'
      WHERE guidance_preference IS NULL;
    SQL
    change_column_default :experiments, :guidance_preference, from: nil, to: "reference_examples"
    change_column_null :experiments, :guidance_preference, false
    add_check_constraint :experiments,
                         "guidance_preference IN ('reference_examples', 'glossary', 'experiment_instruction')",
                         name: "experiments_guidance_preference_check"

    execute <<~SQL
      CREATE FUNCTION translation_reference_revision_configuration_digest(
        source_language text,
        target_language text,
        source_text text,
        approved_translation text
      )
      RETURNS text
      LANGUAGE sql
      IMMUTABLE
      STRICT
      AS $$
        SELECT encode(digest(
          '{"source_language":' || to_json(source_language)::text ||
          ',"target_language":' || to_json(target_language)::text ||
          ',"source_text":' || to_json(source_text)::text ||
          ',"approved_translation":' || to_json(approved_translation)::text || '}',
          'sha256'
        ), 'hex');
      $$;
    SQL

    add_check_constraint :translation_reference_revisions,
                         <<~SQL.squish,
                           configuration_digest = translation_reference_revision_configuration_digest(
                             source_language,
                             target_language,
                             source_text,
                             approved_translation
                           )
                         SQL
                         name: "translation_reference_revisions_payload_digest_check"

    execute <<~SQL
      CREATE FUNCTION prevent_translation_reference_revision_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'Translation reference revisions cannot be deleted'
            USING ERRCODE = 'check_violation';
        END IF;

        RAISE EXCEPTION 'Translation reference revisions are immutable'
          USING ERRCODE = 'check_violation';
      END;
      $$;

      CREATE FUNCTION prevent_experiment_reference_snapshot_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'Experiment reference snapshots cannot be deleted'
            USING ERRCODE = 'check_violation';
        END IF;

        RAISE EXCEPTION 'Experiment reference snapshots are immutable'
          USING ERRCODE = 'check_violation';
      END;
      $$;

      CREATE FUNCTION enforce_new_experiment_reference_snapshot()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        document_id bigint;
        reference_id bigint;
        project_id bigint;
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('experiment:' || NEW.experiment_id::text, 0));
        PERFORM 1 FROM experiments WHERE id = NEW.experiment_id FOR UPDATE;
        SELECT experiments.document_id, documents.project_id INTO document_id, project_id
          FROM experiments
          INNER JOIN documents ON documents.id = experiments.document_id
          WHERE experiments.id = NEW.experiment_id;
        PERFORM pg_advisory_xact_lock(hashtextextended('document:' || document_id::text, 0));
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
            AND lower(btrim(translation_reference_revisions.source_language)) = lower(btrim(projects.source_language))
            AND lower(btrim(translation_reference_revisions.target_language)) = lower(btrim(projects.target_language))
        ) THEN
          RAISE EXCEPTION 'Translation reference revision is not available for this experiment'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION enforce_experiment_reference_snapshots()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('experiment:' || NEW.id::text, 0));

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
              OR lower(btrim(translation_reference_revisions.source_language)) <> lower(btrim(projects.source_language))
              OR lower(btrim(translation_reference_revisions.target_language)) <> lower(btrim(projects.target_language))
            )
        ) THEN
          RAISE EXCEPTION 'Experiment change would invalidate a reference snapshot'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION enforce_project_reference_snapshots()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.id::text, 0));

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
              OR lower(btrim(translation_reference_revisions.source_language)) <> lower(btrim(NEW.source_language))
              OR lower(btrim(translation_reference_revisions.target_language)) <> lower(btrim(NEW.target_language))
            )
        ) THEN
          RAISE EXCEPTION 'Project change would invalidate an experiment reference snapshot'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION enforce_document_reference_snapshots()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('document:' || NEW.id::text, 0));
        PERFORM pg_advisory_xact_lock(hashtextextended('project:' || NEW.project_id::text, 0));

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
              OR lower(btrim(translation_reference_revisions.source_language)) <> lower(btrim(projects.source_language))
              OR lower(btrim(translation_reference_revisions.target_language)) <> lower(btrim(projects.target_language))
            )
        ) THEN
          RAISE EXCEPTION 'Document change would invalidate an experiment reference snapshot'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION enforce_translation_reference_owner()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('translation_reference:' || NEW.id::text, 0));

        IF EXISTS (
          SELECT 1
          FROM translation_reference_revisions
          INNER JOIN experiment_reference_revisions
            ON experiment_reference_revisions.translation_reference_revision_id = translation_reference_revisions.id
          INNER JOIN experiments ON experiments.id = experiment_reference_revisions.experiment_id
          INNER JOIN documents ON documents.id = experiments.document_id
          INNER JOIN projects ON projects.id = documents.project_id
          WHERE translation_reference_revisions.translation_reference_id = NEW.id
            AND projects.user_id <> NEW.user_id
        ) THEN
          RAISE EXCEPTION 'Translation reference ownership change would invalidate an experiment snapshot'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION prevent_experiment_guidance_preference_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.guidance_preference IS DISTINCT FROM NEW.guidance_preference THEN
          RAISE EXCEPTION 'Experiment guidance preference cannot change after creation'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER prevent_translation_reference_revision_mutation_trigger
      BEFORE UPDATE OR DELETE ON translation_reference_revisions
      FOR EACH ROW EXECUTE FUNCTION prevent_translation_reference_revision_mutation();

      CREATE TRIGGER enforce_new_experiment_reference_snapshot_trigger
      BEFORE INSERT ON experiment_reference_revisions
      FOR EACH ROW EXECUTE FUNCTION enforce_new_experiment_reference_snapshot();

      CREATE TRIGGER prevent_experiment_reference_snapshot_mutation_trigger
      BEFORE UPDATE OR DELETE ON experiment_reference_revisions
      FOR EACH ROW EXECUTE FUNCTION prevent_experiment_reference_snapshot_mutation();

      CREATE TRIGGER enforce_experiment_reference_snapshots_trigger
      BEFORE UPDATE OF document_id ON experiments
      FOR EACH ROW EXECUTE FUNCTION enforce_experiment_reference_snapshots();

      CREATE TRIGGER enforce_project_reference_snapshots_trigger
      BEFORE UPDATE OF user_id, source_language, target_language ON projects
      FOR EACH ROW EXECUTE FUNCTION enforce_project_reference_snapshots();

      CREATE TRIGGER enforce_document_reference_snapshots_trigger
      BEFORE UPDATE OF project_id ON documents
      FOR EACH ROW EXECUTE FUNCTION enforce_document_reference_snapshots();

      CREATE TRIGGER enforce_translation_reference_owner_trigger
      BEFORE UPDATE OF user_id ON translation_references
      FOR EACH ROW EXECUTE FUNCTION enforce_translation_reference_owner();

      CREATE TRIGGER prevent_experiment_guidance_preference_mutation_trigger
      BEFORE UPDATE OF guidance_preference ON experiments
      FOR EACH ROW EXECUTE FUNCTION prevent_experiment_guidance_preference_mutation();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS prevent_experiment_guidance_preference_mutation_trigger ON experiments;
      DROP TRIGGER IF EXISTS enforce_translation_reference_owner_trigger ON translation_references;
      DROP TRIGGER IF EXISTS enforce_document_reference_snapshots_trigger ON documents;
      DROP TRIGGER IF EXISTS enforce_project_reference_snapshots_trigger ON projects;
      DROP TRIGGER IF EXISTS enforce_experiment_reference_snapshots_trigger ON experiments;
      DROP TRIGGER IF EXISTS prevent_experiment_reference_snapshot_mutation_trigger ON experiment_reference_revisions;
      DROP TRIGGER IF EXISTS enforce_new_experiment_reference_snapshot_trigger ON experiment_reference_revisions;
      DROP TRIGGER IF EXISTS prevent_translation_reference_revision_mutation_trigger ON translation_reference_revisions;

      DROP FUNCTION IF EXISTS prevent_experiment_guidance_preference_mutation();
      DROP FUNCTION IF EXISTS enforce_translation_reference_owner();
      DROP FUNCTION IF EXISTS enforce_document_reference_snapshots();
      DROP FUNCTION IF EXISTS enforce_project_reference_snapshots();
      DROP FUNCTION IF EXISTS enforce_experiment_reference_snapshots();
      DROP FUNCTION IF EXISTS enforce_new_experiment_reference_snapshot();
      DROP FUNCTION IF EXISTS prevent_experiment_reference_snapshot_mutation();
      DROP FUNCTION IF EXISTS prevent_translation_reference_revision_mutation();
    SQL

    remove_check_constraint :experiments, name: "experiments_guidance_preference_check"
    remove_column :experiments, :guidance_preference
    drop_table :experiment_reference_revisions
    remove_foreign_key :translation_references, name: "fk_translation_references_owned_current_revision"
    remove_check_constraint :translation_reference_revisions,
                            name: "translation_reference_revisions_payload_digest_check"
    drop_table :translation_reference_revisions
    drop_table :translation_references
    execute "DROP FUNCTION IF EXISTS translation_reference_revision_configuration_digest(text, text, text, text);"
  end
end
