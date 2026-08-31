class CreateMethodologyProfiles < ActiveRecord::Migration[8.1]
  def up
    create_table :methodology_profiles do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.bigint :current_revision_id
      t.boolean :active, null: false, default: true

      t.timestamps
    end
    add_index :methodology_profiles, [ :user_id, :active ]

    create_table :methodology_profile_revisions do |t|
      t.references :methodology_profile, null: false, foreign_key: { on_delete: :restrict }
      t.integer :version, null: false
      t.string :name, null: false
      t.string :description
      t.string :source_language, null: false
      t.string :target_language, null: false
      t.text :guidance, null: false
      t.string :configuration_digest, null: false

      t.timestamps
    end
    add_index :methodology_profile_revisions, [ :methodology_profile_id, :version ], unique: true
    add_index :methodology_profile_revisions, [ :methodology_profile_id, :id ], unique: true
    add_index :methodology_profile_revisions, :configuration_digest
    add_check_constraint :methodology_profile_revisions, "version > 0", name: "methodology_profile_revisions_version_check"
    add_check_constraint :methodology_profile_revisions,
                         "char_length(btrim(name)) BETWEEN 1 AND 150",
                         name: "methodology_profile_revisions_name_check"
    add_check_constraint :methodology_profile_revisions,
                         "description IS NULL OR char_length(description) <= 500",
                         name: "methodology_profile_revisions_description_check"
    add_check_constraint :methodology_profile_revisions,
                         "char_length(btrim(source_language)) BETWEEN 1 AND 100",
                         name: "methodology_profile_revisions_source_language_check"
    add_check_constraint :methodology_profile_revisions,
                         "char_length(btrim(target_language)) BETWEEN 1 AND 100",
                         name: "methodology_profile_revisions_target_language_check"
    add_check_constraint :methodology_profile_revisions,
                         "char_length(btrim(guidance)) BETWEEN 1 AND 10000",
                         name: "methodology_profile_revisions_guidance_check"
    add_check_constraint :methodology_profile_revisions,
                         "configuration_digest ~ '^[0-9a-f]{64}$'",
                         name: "methodology_profile_revisions_digest_check"

    add_foreign_key :methodology_profiles, :methodology_profile_revisions,
                    column: [ :id, :current_revision_id ],
                    primary_key: [ :methodology_profile_id, :id ],
                    name: "fk_methodology_profiles_owned_current_revision"

    add_reference :experiments, :methodology_profile_revision,
                  foreign_key: { on_delete: :restrict }, index: true, null: true

    execute <<~SQL
      CREATE FUNCTION prevent_methodology_profile_revision_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'Methodology profile revisions cannot be deleted'
            USING ERRCODE = 'check_violation';
        END IF;

        RAISE EXCEPTION 'Methodology profile revisions are immutable'
          USING ERRCODE = 'check_violation';
      END;
      $$;

      CREATE TRIGGER prevent_methodology_profile_revision_mutation_trigger
      BEFORE UPDATE OR DELETE ON methodology_profile_revisions
      FOR EACH ROW
      EXECUTE FUNCTION prevent_methodology_profile_revision_mutation();

      CREATE FUNCTION enforce_experiment_methodology_snapshot()
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
      FOR EACH ROW
      EXECUTE FUNCTION enforce_experiment_methodology_snapshot();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS enforce_experiment_methodology_snapshot_trigger
        ON experiments;
      DROP FUNCTION IF EXISTS enforce_experiment_methodology_snapshot();
      DROP TRIGGER IF EXISTS prevent_methodology_profile_revision_mutation_trigger
        ON methodology_profile_revisions;
      DROP FUNCTION IF EXISTS prevent_methodology_profile_revision_mutation();
    SQL
    remove_reference :experiments, :methodology_profile_revision, foreign_key: true
    remove_foreign_key :methodology_profiles, name: "fk_methodology_profiles_owned_current_revision"
    drop_table :methodology_profile_revisions
    drop_table :methodology_profiles
  end
end
