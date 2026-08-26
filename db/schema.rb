# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_26_090000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "documents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "project_id", null: false
    t.text "source_text", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_documents_on_project_id"
  end

  create_table "experiments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "document_id", null: false
    t.text "instruction_prompt", null: false
    t.string "name"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["document_id"], name: "index_experiments_on_document_id"
  end

  create_table "judge_evaluations", force: :cascade do |t|
    t.string "anonymous_label", null: false
    t.datetime "created_at", null: false
    t.bigint "judge_run_id", null: false
    t.integer "overall_score"
    t.integer "rank"
    t.text "rationale"
    t.text "risks"
    t.text "strengths"
    t.bigint "translation_run_id", null: false
    t.datetime "updated_at", null: false
    t.index ["judge_run_id", "anonymous_label"], name: "index_judge_evaluations_on_run_and_label", unique: true
    t.index ["judge_run_id", "rank"], name: "index_judge_evaluations_on_run_and_rank", unique: true, where: "(rank IS NOT NULL)"
    t.index ["judge_run_id", "translation_run_id"], name: "index_judge_evaluations_on_run_and_translation", unique: true
    t.index ["judge_run_id"], name: "index_judge_evaluations_on_judge_run_id"
    t.index ["translation_run_id"], name: "index_judge_evaluations_on_translation_run_id"
    t.check_constraint "anonymous_label::text ~ '^Candidate [A-Z]+$'::text", name: "judge_evaluations_label_check"
    t.check_constraint "overall_score IS NULL OR overall_score >= 1 AND overall_score <= 100", name: "judge_evaluations_overall_score_check"
    t.check_constraint "rank IS NULL OR rank > 0", name: "judge_evaluations_rank_check"
  end

  create_table "judge_rounds", force: :cascade do |t|
    t.jsonb "aggregate_rankings", default: [], null: false
    t.text "aggregation_explanation"
    t.datetime "created_at", null: false
    t.bigint "review_round_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "winner_translation_run_id"
    t.index ["review_round_id"], name: "index_judge_rounds_on_review_round_id", unique: true
    t.index ["winner_translation_run_id"], name: "index_judge_rounds_on_winner_translation_run_id"
    t.check_constraint "(status::text = 'completed'::text) = (winner_translation_run_id IS NOT NULL)", name: "judge_rounds_completed_winner_check"
    t.check_constraint "jsonb_typeof(aggregate_rankings) = 'array'::text", name: "judge_rounds_aggregate_rankings_array_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'running'::character varying, 'completed'::character varying, 'failed'::character varying]::text[])", name: "judge_rounds_status_check"
  end

  create_table "judge_runs", force: :cascade do |t|
    t.bigint "cached_tokens"
    t.datetime "completed_at"
    t.bigint "completion_tokens"
    t.integer "confidence_score"
    t.decimal "cost", precision: 20, scale: 10
    t.datetime "created_at", null: false
    t.string "error_code"
    t.text "error_message"
    t.bigint "judge_llm_model_id", null: false
    t.bigint "judge_round_id", null: false
    t.bigint "prompt_tokens"
    t.string "provider_response_id"
    t.bigint "reasoning_tokens"
    t.string "resolved_model_identifier"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.bigint "total_tokens"
    t.datetime "updated_at", null: false
    t.text "winner_rationale"
    t.bigint "winner_translation_run_id"
    t.index ["judge_llm_model_id"], name: "index_judge_runs_on_judge_llm_model_id"
    t.index ["judge_round_id", "judge_llm_model_id"], name: "index_judge_runs_on_judge_round_id_and_judge_llm_model_id", unique: true
    t.index ["judge_round_id"], name: "index_judge_runs_on_judge_round_id"
    t.index ["winner_translation_run_id"], name: "index_judge_runs_on_winner_translation_run_id"
    t.check_constraint "cached_tokens IS NULL OR cached_tokens >= 0", name: "judge_runs_cached_tokens_check"
    t.check_constraint "completion_tokens IS NULL OR completion_tokens >= 0", name: "judge_runs_completion_tokens_check"
    t.check_constraint "confidence_score IS NULL OR confidence_score >= 1 AND confidence_score <= 100", name: "judge_runs_confidence_score_check"
    t.check_constraint "cost IS NULL OR cost >= 0::numeric", name: "judge_runs_cost_check"
    t.check_constraint "prompt_tokens IS NULL OR prompt_tokens >= 0", name: "judge_runs_prompt_tokens_check"
    t.check_constraint "reasoning_tokens IS NULL OR reasoning_tokens >= 0", name: "judge_runs_reasoning_tokens_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'running'::character varying, 'completed'::character varying, 'failed'::character varying]::text[])", name: "judge_runs_status_check"
    t.check_constraint "total_tokens IS NULL OR total_tokens >= 0", name: "judge_runs_total_tokens_check"
    t.check_constraint "winner_translation_run_id IS NULL OR status::text = 'completed'::text", name: "judge_runs_winner_status_check"
  end

  create_table "llm_models", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.string "gateway", null: false
    t.string "model_identifier", null: false
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.index ["gateway", "model_identifier"], name: "index_llm_models_on_gateway_and_model_identifier", unique: true
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "source_language", null: false
    t.string "target_language", null: false
    t.datetime "updated_at", null: false
  end

  create_table "review_evaluations", force: :cascade do |t|
    t.string "anonymous_label", null: false
    t.datetime "created_at", null: false
    t.integer "faithfulness_score"
    t.integer "instruction_adherence_score"
    t.text "issues"
    t.integer "naturalness_score"
    t.integer "overall_score"
    t.text "recommended_corrections"
    t.bigint "review_run_id", null: false
    t.text "strengths"
    t.text "suggested_translation"
    t.integer "terminology_score"
    t.bigint "translation_run_id", null: false
    t.datetime "updated_at", null: false
    t.index ["review_run_id", "anonymous_label"], name: "index_review_evaluations_on_run_and_label", unique: true
    t.index ["review_run_id", "translation_run_id"], name: "index_review_evaluations_on_run_and_translation", unique: true
    t.index ["review_run_id"], name: "index_review_evaluations_on_review_run_id"
    t.index ["translation_run_id"], name: "index_review_evaluations_on_translation_run_id"
    t.check_constraint "anonymous_label::text ~ '^Candidate [A-Z]+$'::text", name: "review_evaluations_label_check"
    t.check_constraint "faithfulness_score IS NULL OR faithfulness_score >= 1 AND faithfulness_score <= 10", name: "review_evaluations_faithfulness_score_check"
    t.check_constraint "instruction_adherence_score IS NULL OR instruction_adherence_score >= 1 AND instruction_adherence_score <= 10", name: "review_evaluations_instruction_adherence_score_check"
    t.check_constraint "naturalness_score IS NULL OR naturalness_score >= 1 AND naturalness_score <= 10", name: "review_evaluations_naturalness_score_check"
    t.check_constraint "overall_score IS NULL OR overall_score >= 1 AND overall_score <= 10", name: "review_evaluations_overall_score_check"
    t.check_constraint "terminology_score IS NULL OR terminology_score >= 1 AND terminology_score <= 10", name: "review_evaluations_terminology_score_check"
  end

  create_table "review_rounds", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "experiment_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["experiment_id"], name: "index_review_rounds_on_experiment_id", unique: true
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'running'::character varying, 'completed'::character varying, 'failed'::character varying]::text[])", name: "review_rounds_status_check"
  end

  create_table "review_runs", force: :cascade do |t|
    t.bigint "cached_tokens"
    t.datetime "completed_at"
    t.bigint "completion_tokens"
    t.decimal "cost", precision: 20, scale: 10
    t.datetime "created_at", null: false
    t.string "error_code"
    t.text "error_message"
    t.bigint "prompt_tokens"
    t.string "provider_response_id"
    t.bigint "reasoning_tokens"
    t.string "resolved_model_identifier"
    t.bigint "review_round_id", null: false
    t.bigint "reviewer_llm_model_id", null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.bigint "total_tokens"
    t.datetime "updated_at", null: false
    t.index ["review_round_id", "reviewer_llm_model_id"], name: "index_review_runs_on_review_round_id_and_reviewer_llm_model_id", unique: true
    t.index ["review_round_id"], name: "index_review_runs_on_review_round_id"
    t.index ["reviewer_llm_model_id"], name: "index_review_runs_on_reviewer_llm_model_id"
    t.check_constraint "cached_tokens IS NULL OR cached_tokens >= 0", name: "review_runs_cached_tokens_check"
    t.check_constraint "completion_tokens IS NULL OR completion_tokens >= 0", name: "review_runs_completion_tokens_check"
    t.check_constraint "cost IS NULL OR cost >= 0::numeric", name: "review_runs_cost_check"
    t.check_constraint "prompt_tokens IS NULL OR prompt_tokens >= 0", name: "review_runs_prompt_tokens_check"
    t.check_constraint "reasoning_tokens IS NULL OR reasoning_tokens >= 0", name: "review_runs_reasoning_tokens_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'running'::character varying, 'completed'::character varying, 'failed'::character varying]::text[])", name: "review_runs_status_check"
    t.check_constraint "total_tokens IS NULL OR total_tokens >= 0", name: "review_runs_total_tokens_check"
  end

  create_table "translation_runs", force: :cascade do |t|
    t.bigint "cached_tokens"
    t.datetime "completed_at"
    t.bigint "completion_tokens"
    t.decimal "cost", precision: 20, scale: 10
    t.datetime "created_at", null: false
    t.string "error_code"
    t.text "error_message"
    t.bigint "experiment_id", null: false
    t.bigint "llm_model_id", null: false
    t.bigint "prompt_tokens"
    t.string "provider_response_id"
    t.bigint "reasoning_tokens"
    t.string "resolved_model_identifier"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.bigint "total_tokens"
    t.text "translated_text"
    t.datetime "updated_at", null: false
    t.index ["experiment_id", "llm_model_id"], name: "index_translation_runs_on_experiment_id_and_llm_model_id", unique: true
    t.index ["experiment_id"], name: "index_translation_runs_on_experiment_id"
    t.index ["llm_model_id"], name: "index_translation_runs_on_llm_model_id"
  end

  add_foreign_key "documents", "projects"
  add_foreign_key "experiments", "documents"
  add_foreign_key "judge_evaluations", "judge_runs"
  add_foreign_key "judge_evaluations", "translation_runs"
  add_foreign_key "judge_rounds", "review_rounds"
  add_foreign_key "judge_rounds", "translation_runs", column: "winner_translation_run_id"
  add_foreign_key "judge_runs", "judge_rounds"
  add_foreign_key "judge_runs", "llm_models", column: "judge_llm_model_id"
  add_foreign_key "judge_runs", "translation_runs", column: "winner_translation_run_id"
  add_foreign_key "review_evaluations", "review_runs"
  add_foreign_key "review_evaluations", "translation_runs"
  add_foreign_key "review_rounds", "experiments"
  add_foreign_key "review_runs", "llm_models", column: "reviewer_llm_model_id"
  add_foreign_key "review_runs", "review_rounds"
  add_foreign_key "translation_runs", "experiments"
  add_foreign_key "translation_runs", "llm_models"
end
