class AddTelemetryToTranslationRuns < ActiveRecord::Migration[8.1]
  def change
    change_table :translation_runs, bulk: true do |t|
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
    end

    add_index :translation_runs,
              [ :experiment_id, :llm_model_id ],
              unique: true
  end
end
