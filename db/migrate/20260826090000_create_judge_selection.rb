class CreateJudgeSelection < ActiveRecord::Migration[8.1]
  def change
    create_table :judge_rounds do |t|
      t.references :review_round,
                   null: false,
                   foreign_key: true,
                   index: { unique: true }
      t.string :status, null: false, default: "pending"
      t.references :winner_translation_run,
                   foreign_key: { to_table: :translation_runs }
      t.jsonb :aggregate_rankings, null: false, default: []
      t.text :aggregation_explanation

      t.timestamps
    end
    add_check_constraint :judge_rounds,
                         "status IN ('pending', 'running', 'completed', 'failed')",
                         name: "judge_rounds_status_check"
    add_check_constraint :judge_rounds,
                         "(status = 'completed') = (winner_translation_run_id IS NOT NULL)",
                         name: "judge_rounds_completed_winner_check"
    add_check_constraint :judge_rounds,
                         "jsonb_typeof(aggregate_rankings) = 'array'",
                         name: "judge_rounds_aggregate_rankings_array_check"

    create_table :judge_runs do |t|
      t.references :judge_round, null: false, foreign_key: true
      t.references :judge_llm_model,
                   null: false,
                   foreign_key: { to_table: :llm_models }
      t.references :winner_translation_run,
                   foreign_key: { to_table: :translation_runs }
      t.string :status, null: false, default: "pending"
      t.text :winner_rationale
      t.integer :confidence_score
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
    add_index :judge_runs,
              [ :judge_round_id, :judge_llm_model_id ],
              unique: true
    add_check_constraint :judge_runs,
                         "status IN ('pending', 'running', 'completed', 'failed')",
                         name: "judge_runs_status_check"
    add_check_constraint :judge_runs,
                         "winner_translation_run_id IS NULL OR status = 'completed'",
                         name: "judge_runs_winner_status_check"
    add_check_constraint :judge_runs,
                         "confidence_score IS NULL OR confidence_score BETWEEN 1 AND 100",
                         name: "judge_runs_confidence_score_check"
    %i[prompt_tokens completion_tokens total_tokens cached_tokens reasoning_tokens].each do |column|
      add_check_constraint :judge_runs,
                           "#{column} IS NULL OR #{column} >= 0",
                           name: "judge_runs_#{column}_check"
    end
    add_check_constraint :judge_runs,
                         "cost IS NULL OR cost >= 0",
                         name: "judge_runs_cost_check"

    create_table :judge_evaluations do |t|
      t.references :judge_run, null: false, foreign_key: true
      t.references :translation_run, null: false, foreign_key: true
      t.string :anonymous_label, null: false
      t.integer :rank
      t.integer :overall_score
      t.text :rationale
      t.text :strengths
      t.text :risks

      t.timestamps
    end
    add_index :judge_evaluations,
              [ :judge_run_id, :translation_run_id ],
              unique: true,
              name: "index_judge_evaluations_on_run_and_translation"
    add_index :judge_evaluations,
              [ :judge_run_id, :anonymous_label ],
              unique: true,
              name: "index_judge_evaluations_on_run_and_label"
    add_index :judge_evaluations,
              [ :judge_run_id, :rank ],
              unique: true,
              where: "rank IS NOT NULL",
              name: "index_judge_evaluations_on_run_and_rank"
    add_check_constraint :judge_evaluations,
                         "anonymous_label ~ '^Candidate [A-Z]+$'",
                         name: "judge_evaluations_label_check"
    add_check_constraint :judge_evaluations,
                         "rank IS NULL OR rank > 0",
                         name: "judge_evaluations_rank_check"
    add_check_constraint :judge_evaluations,
                         "overall_score IS NULL OR overall_score BETWEEN 1 AND 100",
                         name: "judge_evaluations_overall_score_check"
  end
end
