class CreateAiProviderAttempts < ActiveRecord::Migration[8.1]
  RUN_TYPES = %w[
    TranslationRun
    TranslationSegmentRun
    ReviewRun
    ReviewSegmentRun
    JudgeRun
    JudgeSegmentRun
    FinalizationRun
    FinalizationSegmentRun
  ].freeze

  def change
    create_table :ai_provider_attempts do |t|
      t.string :provider_run_type, null: false
      t.bigint :provider_run_id, null: false
      t.integer :attempt_number, null: false
      t.string :stage, null: false
      t.string :status, null: false
      t.string :gateway_snapshot, null: false
      t.string :provider_snapshot, null: false
      t.string :model_identifier_snapshot, null: false
      t.string :display_name_snapshot, null: false
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.string :error_code
      t.integer :prompt_tokens
      t.integer :completion_tokens
      t.integer :total_tokens
      t.integer :cached_tokens
      t.integer :reasoning_tokens
      t.decimal :cost, precision: 20, scale: 10
      t.timestamps
    end

    add_index :ai_provider_attempts,
              %i[provider_run_type provider_run_id attempt_number],
              unique: true,
              name: "index_ai_provider_attempts_on_run_and_attempt"
    add_index :ai_provider_attempts, %i[status completed_at id]

    add_check_constraint :ai_provider_attempts,
                         "provider_run_type IN (#{RUN_TYPES.map { |type| connection.quote(type) }.join(', ')})",
                         name: "ai_provider_attempts_run_type_check"
    add_check_constraint :ai_provider_attempts,
                         "attempt_number > 0",
                         name: "ai_provider_attempts_attempt_number_check"
    add_check_constraint :ai_provider_attempts,
                         "stage IN ('translation', 'review', 'judge', 'finalization')",
                         name: "ai_provider_attempts_stage_check"
    add_check_constraint :ai_provider_attempts,
                         "status IN ('running', 'completed', 'failed')",
                         name: "ai_provider_attempts_status_check"
    add_check_constraint :ai_provider_attempts,
                         "(status = 'running' AND completed_at IS NULL AND error_code IS NULL) OR " \
                         "(status = 'completed' AND completed_at IS NOT NULL AND error_code IS NULL) OR " \
                         "(status = 'failed' AND completed_at IS NOT NULL AND error_code IS NOT NULL)",
                         name: "ai_provider_attempts_lifecycle_check"
    add_check_constraint :ai_provider_attempts,
                         "completed_at IS NULL OR completed_at >= started_at",
                         name: "ai_provider_attempts_duration_check"
    %i[prompt_tokens completion_tokens total_tokens cached_tokens reasoning_tokens].each do |column|
      add_check_constraint :ai_provider_attempts,
                           "#{column} IS NULL OR #{column} >= 0",
                           name: "ai_provider_attempts_#{column}_check"
    end
    add_check_constraint :ai_provider_attempts,
                         "cost IS NULL OR cost >= 0",
                         name: "ai_provider_attempts_cost_check"
  end
end
