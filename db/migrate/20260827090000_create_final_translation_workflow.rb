class CreateFinalTranslationWorkflow < ActiveRecord::Migration[8.1]
  def change
    create_table :final_translations do |t|
      t.references :experiment, null: false, foreign_key: true
      t.references :judge_round, null: false, foreign_key: true, index: { unique: true }
      t.references :source_winner_translation_run,
                   null: false,
                   foreign_key: { to_table: :translation_runs }
      t.bigint :current_version_id
      t.string :status, null: false, default: "draft"
      t.datetime :finalized_at
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end
    add_index :final_translations, [ :id, :experiment_id ], unique: true
    add_check_constraint :final_translations,
                         "status IN ('draft', 'finalized')",
                         name: "final_translations_status_check"
    add_check_constraint :final_translations,
                         "(status = 'finalized') = (finalized_at IS NOT NULL)",
                         name: "final_translations_finalized_at_check"

    create_table :final_translation_versions do |t|
      t.references :final_translation, null: false, foreign_key: true
      t.bigint :source_finalization_run_id
      t.integer :version_number, null: false
      t.text :content, null: false
      t.string :origin, null: false
      t.string :change_note

      t.timestamps
    end
    add_index :final_translation_versions,
              [ :final_translation_id, :version_number ],
              unique: true,
              name: "index_final_versions_on_translation_and_number"
    add_index :final_translation_versions,
              [ :final_translation_id, :id ],
              unique: true,
              name: "index_final_versions_on_translation_and_id"
    add_check_constraint :final_translation_versions,
                         "version_number > 0",
                         name: "final_translation_versions_number_check"
    add_check_constraint :final_translation_versions,
                         "char_length(btrim(content)) > 0 AND char_length(content) <= 100000",
                         name: "final_translation_versions_content_check"
    add_check_constraint :final_translation_versions,
                         "origin IN ('seed', 'manual', 'ai_applied', 'restored')",
                         name: "final_translation_versions_origin_check"
    add_check_constraint :final_translation_versions,
                         "change_note IS NULL OR char_length(change_note) <= 500",
                         name: "final_translation_versions_change_note_check"

    create_table :finalization_rounds do |t|
      t.references :final_translation, null: false, foreign_key: true
      t.references :base_final_translation_version,
                   null: false,
                   foreign_key: { to_table: :final_translation_versions }
      t.string :status, null: false, default: "running"
      t.string :selection_key, null: false

      t.timestamps
    end
    add_index :finalization_rounds,
              :final_translation_id,
              unique: true,
              where: "status = 'running'",
              name: "index_finalization_rounds_one_running"
    add_index :finalization_rounds,
              [ :final_translation_id, :base_final_translation_version_id ],
              name: "index_finalization_rounds_on_translation_and_base"
    add_check_constraint :finalization_rounds,
                         "status IN ('running', 'completed', 'failed')",
                         name: "finalization_rounds_status_check"
    add_check_constraint :finalization_rounds,
                         "char_length(selection_key) = 64",
                         name: "finalization_rounds_selection_key_check"

    create_table :finalization_runs do |t|
      t.references :finalization_round, null: false, foreign_key: true
      t.references :finalizer_llm_model,
                   null: false,
                   foreign_key: { to_table: :llm_models }
      t.string :status, null: false, default: "pending"
      t.text :proposed_translation
      t.jsonb :change_summary, null: false, default: []
      t.jsonb :terminology_notes, null: false, default: []
      t.jsonb :warnings, null: false, default: []
      t.string :provider_response_id
      t.string :resolved_model_identifier
      t.bigint :prompt_tokens
      t.bigint :completion_tokens
      t.bigint :total_tokens
      t.bigint :cached_tokens
      t.bigint :reasoning_tokens
      t.decimal :cost, precision: 20, scale: 10
      t.datetime :started_at
      t.datetime :completed_at
      t.string :error_code
      t.text :error_message

      t.timestamps
    end
    add_index :finalization_runs,
              [ :finalization_round_id, :finalizer_llm_model_id ],
              unique: true,
              name: "index_finalization_runs_on_round_and_model"
    add_check_constraint :finalization_runs,
                         "status IN ('pending', 'running', 'completed', 'failed')",
                         name: "finalization_runs_status_check"
    add_check_constraint :finalization_runs,
                         "proposed_translation IS NULL OR char_length(proposed_translation) <= 100000",
                         name: "finalization_runs_proposal_length_check"
    %i[change_summary terminology_notes warnings].each do |column|
      add_check_constraint :finalization_runs,
                           "jsonb_typeof(#{column}) = 'array'",
                           name: "finalization_runs_#{column}_array_check"
    end
    %i[prompt_tokens completion_tokens total_tokens cached_tokens reasoning_tokens].each do |column|
      add_check_constraint :finalization_runs,
                           "#{column} IS NULL OR #{column} >= 0",
                           name: "finalization_runs_#{column}_check"
    end
    add_check_constraint :finalization_runs,
                         "cost IS NULL OR cost >= 0",
                         name: "finalization_runs_cost_check"

    add_foreign_key :final_translations,
                    :final_translation_versions,
                    column: [ :id, :current_version_id ],
                    primary_key: [ :final_translation_id, :id ],
                    name: "fk_final_translations_current_owned_version"
    add_foreign_key :finalization_rounds,
                    :final_translation_versions,
                    column: [ :final_translation_id, :base_final_translation_version_id ],
                    primary_key: [ :final_translation_id, :id ],
                    name: "fk_finalization_rounds_owned_base_version"
    add_foreign_key :final_translation_versions,
                    :finalization_runs,
                    column: :source_finalization_run_id
  end
end
