class CreateBlindReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :review_rounds do |t|
      t.references :experiment,
                   null: false,
                   foreign_key: true,
                   index: { unique: true }
      t.string :status, null: false, default: "pending"

      t.timestamps
    end
    add_check_constraint :review_rounds,
                         "status IN ('pending', 'running', 'completed', 'failed')",
                         name: "review_rounds_status_check"

    create_table :review_runs do |t|
      t.references :review_round, null: false, foreign_key: true
      t.references :reviewer_llm_model,
                   null: false,
                   foreign_key: { to_table: :llm_models }
      t.string :status, null: false, default: "pending"
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
    add_index :review_runs,
              [ :review_round_id, :reviewer_llm_model_id ],
              unique: true
    add_check_constraint :review_runs,
                         "status IN ('pending', 'running', 'completed', 'failed')",
                         name: "review_runs_status_check"
    add_check_constraint :review_runs,
                         "prompt_tokens IS NULL OR prompt_tokens >= 0",
                         name: "review_runs_prompt_tokens_check"
    add_check_constraint :review_runs,
                         "completion_tokens IS NULL OR completion_tokens >= 0",
                         name: "review_runs_completion_tokens_check"
    add_check_constraint :review_runs,
                         "total_tokens IS NULL OR total_tokens >= 0",
                         name: "review_runs_total_tokens_check"
    add_check_constraint :review_runs,
                         "cached_tokens IS NULL OR cached_tokens >= 0",
                         name: "review_runs_cached_tokens_check"
    add_check_constraint :review_runs,
                         "reasoning_tokens IS NULL OR reasoning_tokens >= 0",
                         name: "review_runs_reasoning_tokens_check"
    add_check_constraint :review_runs,
                         "cost IS NULL OR cost >= 0",
                         name: "review_runs_cost_check"

    create_table :review_evaluations do |t|
      t.references :review_run, null: false, foreign_key: true
      t.references :translation_run, null: false, foreign_key: true
      t.string :anonymous_label, null: false
      t.integer :faithfulness_score
      t.integer :naturalness_score
      t.integer :terminology_score
      t.integer :instruction_adherence_score
      t.integer :overall_score
      t.text :strengths
      t.text :issues
      t.text :recommended_corrections
      t.text :suggested_translation

      t.timestamps
    end
    add_index :review_evaluations,
              [ :review_run_id, :translation_run_id ],
              unique: true,
              name: "index_review_evaluations_on_run_and_translation"
    add_index :review_evaluations,
              [ :review_run_id, :anonymous_label ],
              unique: true,
              name: "index_review_evaluations_on_run_and_label"
    add_check_constraint :review_evaluations,
                         "anonymous_label ~ '^Candidate [A-Z]+$'",
                         name: "review_evaluations_label_check"

    %i[
      faithfulness_score
      naturalness_score
      terminology_score
      instruction_adherence_score
      overall_score
    ].each do |column|
      add_check_constraint :review_evaluations,
                           "#{column} IS NULL OR #{column} BETWEEN 1 AND 10",
                           name: "review_evaluations_#{column}_check"
    end
  end
end
