class CreateLongDocumentEngine < ActiveRecord::Migration[8.1]
  PARENT_RUN_TABLES = %i[
    translation_runs review_runs judge_runs finalization_runs
  ].freeze

  def change
    add_column :llm_models, :context_window_tokens, :integer
    add_column :llm_models, :max_output_tokens, :integer
    add_check_constraint :llm_models,
                         "context_window_tokens IS NULL OR context_window_tokens BETWEEN 1024 AND 2000000",
                         name: "llm_models_context_window_tokens_check"
    add_check_constraint :llm_models,
                         "max_output_tokens IS NULL OR max_output_tokens BETWEEN 256 AND 200000",
                         name: "llm_models_max_output_tokens_check"
    add_check_constraint :llm_models,
                         "context_window_tokens IS NULL OR max_output_tokens IS NULL OR max_output_tokens < context_window_tokens",
                         name: "llm_models_output_below_context_check"

    create_table :document_execution_plans do |t|
      t.references :experiment, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.string :segmentation_version, null: false
      t.string :budget_policy_version, null: false
      t.string :source_sha256, null: false
      t.integer :segment_count, null: false
      t.integer :segment_target_characters, null: false

      t.timestamps
    end
    add_check_constraint :document_execution_plans,
                         "char_length(source_sha256) = 64",
                         name: "document_execution_plans_source_digest_check"
    add_check_constraint :document_execution_plans,
                         "segment_count > 1",
                         name: "document_execution_plans_segment_count_check"
    add_check_constraint :document_execution_plans,
                         "segment_target_characters BETWEEN 256 AND 20000",
                         name: "document_execution_plans_target_check"

    create_table :experiment_segments do |t|
      t.references :document_execution_plan,
                   null: false,
                   foreign_key: { on_delete: :restrict },
                   index: false
      t.integer :position, null: false
      t.text :source_text, null: false
      t.integer :source_character_count, null: false
      t.string :source_sha256, null: false

      t.timestamps
    end
    add_index :experiment_segments,
              [ :document_execution_plan_id, :position ],
              unique: true,
              name: "index_experiment_segments_on_plan_and_position"
    add_index :experiment_segments,
              [ :document_execution_plan_id, :id ],
              unique: true,
              name: "index_experiment_segments_on_plan_and_id"
    add_check_constraint :experiment_segments,
                         "position > 0",
                         name: "experiment_segments_position_check"
    add_check_constraint :experiment_segments,
                         "source_character_count > 0 AND source_character_count = char_length(source_text)",
                         name: "experiment_segments_source_length_check"
    add_check_constraint :experiment_segments,
                         "char_length(source_sha256) = 64",
                         name: "experiment_segments_source_digest_check"

    create_segment_run_table :translation_segment_runs, :translation_run do |t|
      t.text :translated_text
    end
    add_check_constraint :translation_segment_runs,
                         "translated_text IS NULL OR char_length(translated_text) <= 20000",
                         name: "translation_segment_runs_output_length_check"

    create_segment_run_table :review_segment_runs, :review_run do |t|
      t.jsonb :evaluations, null: false, default: []
    end
    add_check_constraint :review_segment_runs,
                         "jsonb_typeof(evaluations) = 'array' AND octet_length(evaluations::text) <= 100000",
                         name: "review_segment_runs_evaluations_check"

    create_segment_run_table :judge_segment_runs, :judge_run do |t|
      t.jsonb :judgment, null: false, default: {}
    end
    add_check_constraint :judge_segment_runs,
                         "jsonb_typeof(judgment) = 'object' AND octet_length(judgment::text) <= 100000",
                         name: "judge_segment_runs_judgment_check"

    create_segment_run_table :finalization_segment_runs, :finalization_run do |t|
      t.text :proposed_translation
      t.jsonb :change_summary, null: false, default: []
      t.jsonb :terminology_notes, null: false, default: []
      t.jsonb :warnings, null: false, default: []
    end
    add_check_constraint :finalization_segment_runs,
                         "proposed_translation IS NULL OR char_length(proposed_translation) <= 20000",
                         name: "finalization_segment_runs_proposal_length_check"
    %i[change_summary terminology_notes warnings].each do |column|
      add_check_constraint :finalization_segment_runs,
                           "jsonb_typeof(#{column}) = 'array' AND octet_length(#{column}::text) <= 50000",
                           name: "finalization_segment_runs_#{column}_check"
    end

    PARENT_RUN_TABLES.each { |table| add_budget_snapshot_columns(table) }
    add_check_constraint :translation_runs,
                         "translated_text IS NULL OR char_length(translated_text) <= 100000",
                         name: "translation_runs_output_length_check"

    add_column :pipeline_runs, :provider_work_plan, :jsonb, null: false, default: {}
    add_check_constraint :pipeline_runs,
                         "jsonb_typeof(provider_work_plan) = 'object' AND octet_length(provider_work_plan::text) <= 16384",
                         name: "pipeline_runs_provider_work_plan_check"

    add_column :final_translation_versions, :segment_alignment_valid, :boolean, null: false, default: true

    create_table :final_translation_version_segments do |t|
      t.references :final_translation_version,
                   null: false,
                   foreign_key: { on_delete: :restrict },
                   index: false
      t.references :experiment_segment,
                   null: false,
                   foreign_key: { on_delete: :restrict },
                   index: false
      t.text :content, null: false

      t.timestamps
    end
    add_index :final_translation_version_segments,
              [ :final_translation_version_id, :experiment_segment_id ],
              unique: true,
              name: "index_final_version_segments_on_version_and_segment"
    add_check_constraint :final_translation_version_segments,
                         "char_length(content) BETWEEN 1 AND 20000",
                         name: "final_translation_version_segments_content_check"
  end

  private

  def create_segment_run_table(table_name, parent_name)
    create_table table_name do |t|
      t.references parent_name, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.references :experiment_segment, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.string :status, null: false, default: "pending"
      t.string :scheduled_job_id
      t.integer :claimed_job_execution, null: false, default: 0
      t.integer :execution_attempt, null: false, default: 0
      t.datetime :pending_since
      t.datetime :last_claimed_at
      t.datetime :started_at
      t.datetime :completed_at
      t.string :error_code
      t.text :error_message
      t.string :provider_response_id
      t.string :resolved_model_identifier
      t.bigint :prompt_tokens
      t.bigint :completion_tokens
      t.bigint :total_tokens
      t.bigint :cached_tokens
      t.bigint :reasoning_tokens
      t.decimal :cost, precision: 20, scale: 10
      t.integer :context_window_tokens_snapshot, null: false
      t.integer :max_output_tokens_snapshot, null: false
      t.integer :estimated_input_tokens, null: false
      t.integer :reserved_output_tokens, null: false
      t.integer :context_safety_margin_tokens, null: false
      t.string :budget_policy_version, null: false

      yield t
      t.timestamps
    end

    parent_id = "#{parent_name}_id"
    add_index table_name,
              [ parent_id, :experiment_segment_id ],
              unique: true,
              name: "index_#{table_name}_on_parent_and_segment"
    add_index table_name, [ parent_id, :id ], unique: true, name: "index_#{table_name}_on_parent_and_id"
    add_index table_name, :pending_since, where: "status = 'pending'", name: "index_#{table_name}_on_pending_since"
    add_index table_name, :last_claimed_at, where: "status = 'running'", name: "index_#{table_name}_on_running_last_claimed_at"
    add_check_constraint table_name,
                         "status IN ('pending', 'running', 'completed', 'failed')",
                         name: "#{table_name}_status_check"
    add_check_constraint table_name, "claimed_job_execution >= 0", name: "#{table_name}_claimed_execution_check"
    add_check_constraint table_name, "execution_attempt >= 0", name: "#{table_name}_execution_attempt_check"
    add_check_constraint table_name,
                         "context_window_tokens_snapshot BETWEEN 1024 AND 2000000",
                         name: "#{table_name}_context_snapshot_check"
    add_check_constraint table_name,
                         "max_output_tokens_snapshot BETWEEN 256 AND 200000 AND max_output_tokens_snapshot < context_window_tokens_snapshot",
                         name: "#{table_name}_output_snapshot_check"
    add_check_constraint table_name,
                         "estimated_input_tokens >= 0 AND reserved_output_tokens > 0 AND context_safety_margin_tokens > 0",
                         name: "#{table_name}_budget_numbers_check"
    %i[prompt_tokens completion_tokens total_tokens cached_tokens reasoning_tokens].each do |column|
      add_check_constraint table_name,
                           "#{column} IS NULL OR #{column} >= 0",
                           name: "#{table_name}_#{column}_check"
    end
    add_check_constraint table_name, "cost IS NULL OR cost >= 0", name: "#{table_name}_cost_check"
  end

  def add_budget_snapshot_columns(table)
    add_column table, :context_window_tokens_snapshot, :integer
    add_column table, :max_output_tokens_snapshot, :integer
    add_column table, :estimated_input_tokens, :integer
    add_column table, :reserved_output_tokens, :integer
    add_column table, :context_safety_margin_tokens, :integer
    add_column table, :budget_policy_version, :string
    add_check_constraint table,
                         "context_window_tokens_snapshot IS NULL OR context_window_tokens_snapshot BETWEEN 1024 AND 2000000",
                         name: "#{table}_context_snapshot_check"
    add_check_constraint table,
                         "max_output_tokens_snapshot IS NULL OR max_output_tokens_snapshot BETWEEN 256 AND 200000",
                         name: "#{table}_output_snapshot_check"
  end
end
