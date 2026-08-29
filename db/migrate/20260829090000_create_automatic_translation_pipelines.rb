class CreateAutomaticTranslationPipelines < ActiveRecord::Migration[8.1]
  def change
    create_table :workflow_profiles do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.bigint :current_revision_id
      t.boolean :active, null: false, default: true

      t.timestamps
    end
    add_index :workflow_profiles, [ :user_id, :active ]

    create_table :workflow_profile_revisions do |t|
      t.references :workflow_profile, null: false, foreign_key: { on_delete: :restrict }
      t.integer :version, null: false
      t.string :name, null: false
      t.string :description
      t.string :completion_mode, null: false
      t.string :configuration_digest, null: false

      t.timestamps
    end
    add_index :workflow_profile_revisions,
              [ :workflow_profile_id, :version ],
              unique: true,
              name: "index_workflow_profile_revisions_on_profile_and_version"
    add_index :workflow_profile_revisions,
              [ :workflow_profile_id, :id ],
              unique: true,
              name: "index_workflow_profile_revisions_on_profile_and_id"
    add_index :workflow_profile_revisions, :configuration_digest
    add_check_constraint :workflow_profile_revisions,
                         "version > 0",
                         name: "workflow_profile_revisions_version_check"
    add_check_constraint :workflow_profile_revisions,
                         "char_length(btrim(name)) BETWEEN 1 AND 150",
                         name: "workflow_profile_revisions_name_check"
    add_check_constraint :workflow_profile_revisions,
                         "description IS NULL OR char_length(description) <= 500",
                         name: "workflow_profile_revisions_description_check"
    add_check_constraint :workflow_profile_revisions,
                         "completion_mode IN ('winner_draft', 'refinement_proposals')",
                         name: "workflow_profile_revisions_completion_mode_check"
    add_check_constraint :workflow_profile_revisions,
                         "char_length(configuration_digest) = 64",
                         name: "workflow_profile_revisions_digest_check"

    add_foreign_key :workflow_profiles,
                    :workflow_profile_revisions,
                    column: [ :id, :current_revision_id ],
                    primary_key: [ :workflow_profile_id, :id ],
                    name: "fk_workflow_profiles_owned_current_revision"

    create_table :workflow_profile_model_selections do |t|
      t.references :workflow_profile_revision,
                   null: false,
                   foreign_key: { on_delete: :restrict },
                   index: { name: "index_profile_model_selections_on_revision" }
      t.references :llm_model, null: false, foreign_key: { on_delete: :restrict }
      t.string :role, null: false
      t.integer :position, null: false
      t.string :gateway_snapshot, null: false
      t.string :provider_snapshot, null: false
      t.string :model_identifier_snapshot, null: false
      t.string :display_name_snapshot, null: false

      t.timestamps
    end
    add_index :workflow_profile_model_selections,
              [ :workflow_profile_revision_id, :role, :llm_model_id ],
              unique: true,
              name: "index_profile_selections_on_revision_role_model"
    add_index :workflow_profile_model_selections,
              [ :workflow_profile_revision_id, :role, :position ],
              unique: true,
              name: "index_profile_selections_on_revision_role_position"
    add_check_constraint :workflow_profile_model_selections,
                         "role IN ('translator', 'reviewer', 'judge', 'finalizer')",
                         name: "workflow_profile_model_selections_role_check"
    add_check_constraint :workflow_profile_model_selections,
                         "position > 0",
                         name: "workflow_profile_model_selections_position_check"
    add_check_constraint :workflow_profile_model_selections,
                         "char_length(gateway_snapshot) BETWEEN 1 AND 50",
                         name: "workflow_profile_selections_gateway_check"
    add_check_constraint :workflow_profile_model_selections,
                         "char_length(provider_snapshot) BETWEEN 1 AND 100",
                         name: "workflow_profile_selections_provider_check"
    add_check_constraint :workflow_profile_model_selections,
                         "char_length(model_identifier_snapshot) BETWEEN 1 AND 255",
                         name: "workflow_profile_selections_identifier_check"
    add_check_constraint :workflow_profile_model_selections,
                         "char_length(display_name_snapshot) BETWEEN 1 AND 150",
                         name: "workflow_profile_selections_display_name_check"

    create_table :pipeline_runs do |t|
      t.references :experiment, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :workflow_profile_revision,
                   null: false,
                   foreign_key: { on_delete: :restrict },
                   index: { name: "index_pipeline_runs_on_profile_revision" }
      t.references :finalization_round,
                   foreign_key: { on_delete: :restrict },
                   index: { unique: true, where: "finalization_round_id IS NOT NULL" }
      t.string :status, null: false, default: "running"
      t.string :current_stage, null: false, default: "translation"
      t.string :blocked_stage
      t.string :blocked_reason_code
      t.string :blocked_message
      t.string :completion_mode, null: false
      t.integer :translator_count, null: false
      t.integer :reviewer_count, null: false
      t.integer :judge_count, null: false
      t.integer :finalizer_count, null: false
      t.integer :authorized_initial_provider_run_count, null: false
      t.string :configuration_digest, null: false
      t.datetime :confirmed_at, null: false
      t.datetime :started_at, null: false
      t.datetime :ready_for_editor_at
      t.datetime :stopped_at

      t.timestamps
    end
    add_index :pipeline_runs,
              [ :status, :updated_at, :id ],
              name: "index_pipeline_runs_for_reconciliation"
    add_index :pipeline_runs, [ :current_stage, :status ]
    add_check_constraint :pipeline_runs,
                         "status IN ('running', 'blocked', 'ready_for_editor', 'stopped')",
                         name: "pipeline_runs_status_check"
    add_check_constraint :pipeline_runs,
                         "current_stage IN ('translation', 'review', 'judge', 'finalization', 'editor')",
                         name: "pipeline_runs_current_stage_check"
    add_check_constraint :pipeline_runs,
                         "blocked_stage IS NULL OR blocked_stage IN ('translation', 'review', 'judge', 'finalization')",
                         name: "pipeline_runs_blocked_stage_check"
    add_check_constraint :pipeline_runs,
                         "(status = 'blocked') = (blocked_stage IS NOT NULL AND blocked_reason_code IS NOT NULL)",
                         name: "pipeline_runs_blocked_state_check"
    add_check_constraint :pipeline_runs,
                         "blocked_message IS NULL OR char_length(blocked_message) <= 500",
                         name: "pipeline_runs_blocked_message_check"
    add_check_constraint :pipeline_runs,
                         "blocked_reason_code IS NULL OR char_length(blocked_reason_code) <= 80",
                         name: "pipeline_runs_blocked_reason_check"
    add_check_constraint :pipeline_runs,
                         "completion_mode IN ('winner_draft', 'refinement_proposals')",
                         name: "pipeline_runs_completion_mode_check"
    add_check_constraint :pipeline_runs,
                         "translator_count BETWEEN 2 AND 6 AND reviewer_count BETWEEN 1 AND 5 AND judge_count BETWEEN 1 AND 5 AND finalizer_count BETWEEN 0 AND 5",
                         name: "pipeline_runs_role_counts_check"
    add_check_constraint :pipeline_runs,
                         "authorized_initial_provider_run_count = translator_count + reviewer_count + judge_count + finalizer_count",
                         name: "pipeline_runs_authorized_count_check"
    add_check_constraint :pipeline_runs,
                         "(completion_mode = 'winner_draft' AND finalizer_count = 0) OR (completion_mode = 'refinement_proposals' AND finalizer_count > 0)",
                         name: "pipeline_runs_completion_finalizer_check"
    add_check_constraint :pipeline_runs,
                         "char_length(configuration_digest) = 64",
                         name: "pipeline_runs_digest_check"
    add_check_constraint :pipeline_runs,
                         "(status = 'ready_for_editor') = (ready_for_editor_at IS NOT NULL)",
                         name: "pipeline_runs_ready_timestamp_check"
    add_check_constraint :pipeline_runs,
                         "(status = 'stopped') = (stopped_at IS NOT NULL)",
                         name: "pipeline_runs_stopped_timestamp_check"

    create_table :pipeline_events do |t|
      t.references :pipeline_run, null: false, foreign_key: { on_delete: :restrict }
      t.integer :sequence_number, null: false
      t.string :event_key, null: false
      t.string :event_type, null: false
      t.string :from_stage
      t.string :to_stage
      t.string :reason_code
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :pipeline_events,
              [ :pipeline_run_id, :sequence_number ],
              unique: true,
              name: "index_pipeline_events_on_run_and_sequence"
    add_index :pipeline_events,
              [ :pipeline_run_id, :event_key ],
              unique: true,
              name: "index_pipeline_events_on_run_and_key"
    add_check_constraint :pipeline_events,
                         "sequence_number > 0",
                         name: "pipeline_events_sequence_check"
    add_check_constraint :pipeline_events,
                         "char_length(event_key) BETWEEN 1 AND 120",
                         name: "pipeline_events_key_check"
    add_check_constraint :pipeline_events,
                         "char_length(event_type) BETWEEN 1 AND 80",
                         name: "pipeline_events_type_check"
    add_check_constraint :pipeline_events,
                         "from_stage IS NULL OR from_stage IN ('translation', 'review', 'judge', 'finalization', 'editor')",
                         name: "pipeline_events_from_stage_check"
    add_check_constraint :pipeline_events,
                         "to_stage IS NULL OR to_stage IN ('translation', 'review', 'judge', 'finalization', 'editor')",
                         name: "pipeline_events_to_stage_check"
    add_check_constraint :pipeline_events,
                         "reason_code IS NULL OR char_length(reason_code) <= 80",
                         name: "pipeline_events_reason_check"
    add_check_constraint :pipeline_events,
                         "jsonb_typeof(metadata) = 'object' AND octet_length(metadata::text) <= 2048",
                         name: "pipeline_events_metadata_check"
  end
end
