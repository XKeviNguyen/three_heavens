class PreventExperimentGlossaryRevisionChanges < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION prevent_experiment_glossary_revision_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.glossary_revision_id IS DISTINCT FROM NEW.glossary_revision_id THEN
          RAISE EXCEPTION 'Experiment glossary revision cannot change after creation'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER prevent_experiment_glossary_revision_mutation_trigger
      BEFORE UPDATE OF glossary_revision_id ON experiments
      FOR EACH ROW EXECUTE FUNCTION prevent_experiment_glossary_revision_mutation();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS prevent_experiment_glossary_revision_mutation_trigger ON experiments;
      DROP FUNCTION IF EXISTS prevent_experiment_glossary_revision_mutation();
    SQL
  end
end
