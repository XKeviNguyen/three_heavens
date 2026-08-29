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

ActiveRecord::Schema[8.1].define(version: 2026_08_30_090000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.datetime "updated_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "documents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "detected_content_type"
    t.string "extraction_version"
    t.bigint "original_byte_size"
    t.string "original_filename"
    t.bigint "project_id", null: false
    t.string "source_format"
    t.string "source_kind", default: "pasted_text", null: false
    t.string "source_sha256"
    t.text "source_text", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_documents_on_project_id"
    t.check_constraint "original_byte_size IS NULL OR original_byte_size >= 0 AND original_byte_size <= 10485760", name: "documents_original_byte_size_check"
    t.check_constraint "source_format IS NULL OR (source_format::text = ANY (ARRAY['txt'::character varying, 'md'::character varying, 'docx'::character varying]::text[]))", name: "documents_source_format_check"
    t.check_constraint "source_kind::text = ANY (ARRAY['pasted_text'::character varying, 'uploaded_file'::character varying]::text[])", name: "documents_source_kind_check"
    t.check_constraint "source_sha256 IS NULL OR char_length(source_sha256::text) = 64", name: "documents_source_sha256_check"
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

  create_table "final_translation_versions", force: :cascade do |t|
    t.string "change_note"
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.bigint "final_translation_id", null: false
    t.string "origin", null: false
    t.bigint "source_finalization_run_id"
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.index ["final_translation_id", "id"], name: "index_final_versions_on_translation_and_id", unique: true
    t.index ["final_translation_id", "version_number"], name: "index_final_versions_on_translation_and_number", unique: true
    t.index ["final_translation_id"], name: "index_final_translation_versions_on_final_translation_id"
    t.index ["source_finalization_run_id"], name: "index_final_versions_on_unique_source_run", unique: true, where: "(source_finalization_run_id IS NOT NULL)"
    t.check_constraint "change_note IS NULL OR char_length(change_note::text) <= 500", name: "final_translation_versions_change_note_check"
    t.check_constraint "char_length(btrim(content)) > 0 AND char_length(content) <= 100000", name: "final_translation_versions_content_check"
    t.check_constraint "origin::text = ANY (ARRAY['seed'::character varying::text, 'manual'::character varying::text, 'ai_applied'::character varying::text, 'restored'::character varying::text])", name: "final_translation_versions_origin_check"
    t.check_constraint "version_number > 0", name: "final_translation_versions_number_check"
  end

  create_table "final_translations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "current_version_id"
    t.bigint "experiment_id", null: false
    t.datetime "finalized_at"
    t.bigint "judge_round_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.bigint "source_winner_translation_run_id", null: false
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["experiment_id"], name: "index_final_translations_on_experiment_id"
    t.index ["id", "experiment_id"], name: "index_final_translations_on_id_and_experiment_id", unique: true
    t.index ["judge_round_id"], name: "index_final_translations_on_judge_round_id", unique: true
    t.index ["source_winner_translation_run_id"], name: "index_final_translations_on_source_winner_translation_run_id"
    t.check_constraint "(status::text = 'finalized'::text) = (finalized_at IS NOT NULL)", name: "final_translations_finalized_at_check"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying::text, 'finalized'::character varying::text])", name: "final_translations_status_check"
  end

  create_table "finalization_rounds", force: :cascade do |t|
    t.bigint "base_final_translation_version_id", null: false
    t.datetime "created_at", null: false
    t.bigint "final_translation_id", null: false
    t.string "selection_key", null: false
    t.string "status", default: "running", null: false
    t.datetime "updated_at", null: false
    t.index ["base_final_translation_version_id"], name: "index_finalization_rounds_on_base_final_translation_version_id"
    t.index ["final_translation_id", "base_final_translation_version_id"], name: "index_finalization_rounds_on_translation_and_base"
    t.index ["final_translation_id"], name: "index_finalization_rounds_on_final_translation_id"
    t.index ["final_translation_id"], name: "index_finalization_rounds_one_running", unique: true, where: "((status)::text = 'running'::text)"
    t.check_constraint "char_length(selection_key::text) = 64", name: "finalization_rounds_selection_key_check"
    t.check_constraint "status::text = ANY (ARRAY['running'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text])", name: "finalization_rounds_status_check"
  end

  create_table "finalization_runs", force: :cascade do |t|
    t.bigint "cached_tokens"
    t.jsonb "change_summary", default: [], null: false
    t.integer "claimed_job_execution", default: 0, null: false
    t.datetime "completed_at"
    t.bigint "completion_tokens"
    t.decimal "cost", precision: 20, scale: 10
    t.datetime "created_at", null: false
    t.string "error_code"
    t.text "error_message"
    t.integer "execution_attempt", default: 0, null: false
    t.bigint "finalization_round_id", null: false
    t.bigint "finalizer_llm_model_id", null: false
    t.datetime "last_claimed_at"
    t.datetime "pending_since"
    t.bigint "prompt_tokens"
    t.text "proposed_translation"
    t.string "provider_response_id"
    t.bigint "reasoning_tokens"
    t.string "resolved_model_identifier"
    t.string "scheduled_job_id"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.jsonb "terminology_notes", default: [], null: false
    t.bigint "total_tokens"
    t.datetime "updated_at", null: false
    t.jsonb "warnings", default: [], null: false
    t.index ["finalization_round_id", "finalizer_llm_model_id"], name: "index_finalization_runs_on_round_and_model", unique: true
    t.index ["finalization_round_id"], name: "index_finalization_runs_on_finalization_round_id"
    t.index ["finalizer_llm_model_id"], name: "index_finalization_runs_on_finalizer_llm_model_id"
    t.index ["last_claimed_at"], name: "index_finalization_runs_on_running_last_claimed_at", where: "((status)::text = 'running'::text)"
    t.index ["pending_since"], name: "index_finalization_runs_on_pending_since", where: "((status)::text = 'pending'::text)"
    t.check_constraint "cached_tokens IS NULL OR cached_tokens >= 0", name: "finalization_runs_cached_tokens_check"
    t.check_constraint "claimed_job_execution >= 0", name: "finalization_runs_claimed_job_execution_check"
    t.check_constraint "completion_tokens IS NULL OR completion_tokens >= 0", name: "finalization_runs_completion_tokens_check"
    t.check_constraint "cost IS NULL OR cost >= 0::numeric", name: "finalization_runs_cost_check"
    t.check_constraint "execution_attempt >= 0", name: "finalization_runs_execution_attempt_check"
    t.check_constraint "jsonb_typeof(change_summary) = 'array'::text", name: "finalization_runs_change_summary_array_check"
    t.check_constraint "jsonb_typeof(terminology_notes) = 'array'::text", name: "finalization_runs_terminology_notes_array_check"
    t.check_constraint "jsonb_typeof(warnings) = 'array'::text", name: "finalization_runs_warnings_array_check"
    t.check_constraint "prompt_tokens IS NULL OR prompt_tokens >= 0", name: "finalization_runs_prompt_tokens_check"
    t.check_constraint "proposed_translation IS NULL OR char_length(proposed_translation) <= 100000", name: "finalization_runs_proposal_length_check"
    t.check_constraint "reasoning_tokens IS NULL OR reasoning_tokens >= 0", name: "finalization_runs_reasoning_tokens_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'running'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text])", name: "finalization_runs_status_check"
    t.check_constraint "total_tokens IS NULL OR total_tokens >= 0", name: "finalization_runs_total_tokens_check"
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
    t.index ["id", "winner_translation_run_id"], name: "index_judge_rounds_on_id_and_winner", unique: true
    t.index ["review_round_id"], name: "index_judge_rounds_on_review_round_id", unique: true
    t.index ["winner_translation_run_id"], name: "index_judge_rounds_on_winner_translation_run_id"
    t.check_constraint "(status::text = 'completed'::text) = (winner_translation_run_id IS NOT NULL)", name: "judge_rounds_completed_winner_check"
    t.check_constraint "jsonb_typeof(aggregate_rankings) = 'array'::text", name: "judge_rounds_aggregate_rankings_array_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'running'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text])", name: "judge_rounds_status_check"
  end

  create_table "judge_runs", force: :cascade do |t|
    t.bigint "cached_tokens"
    t.integer "claimed_job_execution", default: 0, null: false
    t.datetime "completed_at"
    t.bigint "completion_tokens"
    t.integer "confidence_score"
    t.decimal "cost", precision: 20, scale: 10
    t.datetime "created_at", null: false
    t.string "error_code"
    t.text "error_message"
    t.integer "execution_attempt", default: 0, null: false
    t.bigint "judge_llm_model_id", null: false
    t.bigint "judge_round_id", null: false
    t.datetime "last_claimed_at"
    t.datetime "pending_since"
    t.bigint "prompt_tokens"
    t.string "provider_response_id"
    t.bigint "reasoning_tokens"
    t.string "resolved_model_identifier"
    t.string "scheduled_job_id"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.bigint "total_tokens"
    t.datetime "updated_at", null: false
    t.text "winner_rationale"
    t.bigint "winner_translation_run_id"
    t.index ["judge_llm_model_id"], name: "index_judge_runs_on_judge_llm_model_id"
    t.index ["judge_round_id", "judge_llm_model_id"], name: "index_judge_runs_on_judge_round_id_and_judge_llm_model_id", unique: true
    t.index ["judge_round_id"], name: "index_judge_runs_on_judge_round_id"
    t.index ["last_claimed_at"], name: "index_judge_runs_on_running_last_claimed_at", where: "((status)::text = 'running'::text)"
    t.index ["pending_since"], name: "index_judge_runs_on_pending_since", where: "((status)::text = 'pending'::text)"
    t.index ["winner_translation_run_id"], name: "index_judge_runs_on_winner_translation_run_id"
    t.check_constraint "cached_tokens IS NULL OR cached_tokens >= 0", name: "judge_runs_cached_tokens_check"
    t.check_constraint "claimed_job_execution >= 0", name: "judge_runs_claimed_job_execution_check"
    t.check_constraint "completion_tokens IS NULL OR completion_tokens >= 0", name: "judge_runs_completion_tokens_check"
    t.check_constraint "confidence_score IS NULL OR confidence_score >= 1 AND confidence_score <= 100", name: "judge_runs_confidence_score_check"
    t.check_constraint "cost IS NULL OR cost >= 0::numeric", name: "judge_runs_cost_check"
    t.check_constraint "execution_attempt >= 0", name: "judge_runs_execution_attempt_check"
    t.check_constraint "prompt_tokens IS NULL OR prompt_tokens >= 0", name: "judge_runs_prompt_tokens_check"
    t.check_constraint "reasoning_tokens IS NULL OR reasoning_tokens >= 0", name: "judge_runs_reasoning_tokens_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'running'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text])", name: "judge_runs_status_check"
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

  create_table "pipeline_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_key", null: false
    t.string "event_type", null: false
    t.string "from_stage"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "pipeline_run_id", null: false
    t.string "reason_code"
    t.integer "sequence_number", null: false
    t.string "to_stage"
    t.index ["pipeline_run_id", "event_key"], name: "index_pipeline_events_on_run_and_key", unique: true
    t.index ["pipeline_run_id", "sequence_number"], name: "index_pipeline_events_on_run_and_sequence", unique: true
    t.index ["pipeline_run_id"], name: "index_pipeline_events_on_pipeline_run_id"
    t.check_constraint "char_length(event_key::text) >= 1 AND char_length(event_key::text) <= 120", name: "pipeline_events_key_check"
    t.check_constraint "char_length(event_type::text) >= 1 AND char_length(event_type::text) <= 80", name: "pipeline_events_type_check"
    t.check_constraint "from_stage IS NULL OR (from_stage::text = ANY (ARRAY['translation'::character varying, 'review'::character varying, 'judge'::character varying, 'finalization'::character varying, 'editor'::character varying]::text[]))", name: "pipeline_events_from_stage_check"
    t.check_constraint "jsonb_typeof(metadata) = 'object'::text AND octet_length(metadata::text) <= 2048", name: "pipeline_events_metadata_check"
    t.check_constraint "reason_code IS NULL OR char_length(reason_code::text) <= 80", name: "pipeline_events_reason_check"
    t.check_constraint "sequence_number > 0", name: "pipeline_events_sequence_check"
    t.check_constraint "to_stage IS NULL OR (to_stage::text = ANY (ARRAY['translation'::character varying, 'review'::character varying, 'judge'::character varying, 'finalization'::character varying, 'editor'::character varying]::text[]))", name: "pipeline_events_to_stage_check"
  end

  create_table "pipeline_runs", force: :cascade do |t|
    t.integer "authorized_initial_provider_run_count", null: false
    t.string "blocked_message"
    t.string "blocked_reason_code"
    t.string "blocked_stage"
    t.string "completion_mode", null: false
    t.string "configuration_digest", null: false
    t.datetime "confirmed_at", null: false
    t.datetime "created_at", null: false
    t.string "current_stage", default: "translation", null: false
    t.bigint "experiment_id", null: false
    t.bigint "finalization_round_id"
    t.integer "finalizer_count", null: false
    t.integer "judge_count", null: false
    t.datetime "last_reconciled_at"
    t.datetime "ready_for_editor_at"
    t.integer "reviewer_count", null: false
    t.datetime "started_at", null: false
    t.string "status", default: "running", null: false
    t.datetime "stopped_at"
    t.integer "translator_count", null: false
    t.datetime "updated_at", null: false
    t.bigint "workflow_profile_revision_id", null: false
    t.index ["current_stage", "status"], name: "index_pipeline_runs_on_current_stage_and_status"
    t.index ["experiment_id"], name: "index_pipeline_runs_on_experiment_id", unique: true
    t.index ["finalization_round_id"], name: "index_pipeline_runs_on_finalization_round_id", unique: true, where: "(finalization_round_id IS NOT NULL)"
    t.index ["status", "last_reconciled_at", "id"], name: "index_pipeline_runs_for_fair_reconciliation"
    t.index ["status", "updated_at", "id"], name: "index_pipeline_runs_for_reconciliation"
    t.index ["workflow_profile_revision_id"], name: "index_pipeline_runs_on_profile_revision"
    t.check_constraint "(status::text = 'blocked'::text) = (blocked_stage IS NOT NULL AND blocked_reason_code IS NOT NULL)", name: "pipeline_runs_blocked_state_check"
    t.check_constraint "(status::text = 'ready_for_editor'::text) = (ready_for_editor_at IS NOT NULL)", name: "pipeline_runs_ready_timestamp_check"
    t.check_constraint "(status::text = 'stopped'::text) = (stopped_at IS NOT NULL)", name: "pipeline_runs_stopped_timestamp_check"
    t.check_constraint "authorized_initial_provider_run_count = (translator_count + reviewer_count + judge_count + finalizer_count)", name: "pipeline_runs_authorized_count_check"
    t.check_constraint "blocked_message IS NULL OR char_length(blocked_message::text) <= 500", name: "pipeline_runs_blocked_message_check"
    t.check_constraint "blocked_reason_code IS NULL OR char_length(blocked_reason_code::text) <= 80", name: "pipeline_runs_blocked_reason_check"
    t.check_constraint "blocked_stage IS NULL OR (blocked_stage::text = ANY (ARRAY['translation'::character varying, 'review'::character varying, 'judge'::character varying, 'finalization'::character varying]::text[]))", name: "pipeline_runs_blocked_stage_check"
    t.check_constraint "char_length(configuration_digest::text) = 64", name: "pipeline_runs_digest_check"
    t.check_constraint "completion_mode::text = 'winner_draft'::text AND finalizer_count = 0 OR completion_mode::text = 'refinement_proposals'::text AND finalizer_count > 0", name: "pipeline_runs_completion_finalizer_check"
    t.check_constraint "completion_mode::text = ANY (ARRAY['winner_draft'::character varying, 'refinement_proposals'::character varying]::text[])", name: "pipeline_runs_completion_mode_check"
    t.check_constraint "current_stage::text = ANY (ARRAY['translation'::character varying, 'review'::character varying, 'judge'::character varying, 'finalization'::character varying, 'editor'::character varying]::text[])", name: "pipeline_runs_current_stage_check"
    t.check_constraint "status::text = ANY (ARRAY['running'::character varying, 'blocked'::character varying, 'ready_for_editor'::character varying, 'stopped'::character varying]::text[])", name: "pipeline_runs_status_check"
    t.check_constraint "translator_count >= 2 AND translator_count <= 6 AND reviewer_count >= 1 AND reviewer_count <= 5 AND judge_count >= 1 AND judge_count <= 5 AND finalizer_count >= 0 AND finalizer_count <= 5", name: "pipeline_runs_role_counts_check"
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "source_language", null: false
    t.string "target_language", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_projects_on_user_id"
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
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'running'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text])", name: "review_rounds_status_check"
  end

  create_table "review_runs", force: :cascade do |t|
    t.bigint "cached_tokens"
    t.integer "claimed_job_execution", default: 0, null: false
    t.datetime "completed_at"
    t.bigint "completion_tokens"
    t.decimal "cost", precision: 20, scale: 10
    t.datetime "created_at", null: false
    t.string "error_code"
    t.text "error_message"
    t.integer "execution_attempt", default: 0, null: false
    t.datetime "last_claimed_at"
    t.datetime "pending_since"
    t.bigint "prompt_tokens"
    t.string "provider_response_id"
    t.bigint "reasoning_tokens"
    t.string "resolved_model_identifier"
    t.bigint "review_round_id", null: false
    t.bigint "reviewer_llm_model_id", null: false
    t.string "scheduled_job_id"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.bigint "total_tokens"
    t.datetime "updated_at", null: false
    t.index ["last_claimed_at"], name: "index_review_runs_on_running_last_claimed_at", where: "((status)::text = 'running'::text)"
    t.index ["pending_since"], name: "index_review_runs_on_pending_since", where: "((status)::text = 'pending'::text)"
    t.index ["review_round_id", "reviewer_llm_model_id"], name: "index_review_runs_on_review_round_id_and_reviewer_llm_model_id", unique: true
    t.index ["review_round_id"], name: "index_review_runs_on_review_round_id"
    t.index ["reviewer_llm_model_id"], name: "index_review_runs_on_reviewer_llm_model_id"
    t.check_constraint "cached_tokens IS NULL OR cached_tokens >= 0", name: "review_runs_cached_tokens_check"
    t.check_constraint "claimed_job_execution >= 0", name: "review_runs_claimed_job_execution_check"
    t.check_constraint "completion_tokens IS NULL OR completion_tokens >= 0", name: "review_runs_completion_tokens_check"
    t.check_constraint "cost IS NULL OR cost >= 0::numeric", name: "review_runs_cost_check"
    t.check_constraint "execution_attempt >= 0", name: "review_runs_execution_attempt_check"
    t.check_constraint "prompt_tokens IS NULL OR prompt_tokens >= 0", name: "review_runs_prompt_tokens_check"
    t.check_constraint "reasoning_tokens IS NULL OR reasoning_tokens >= 0", name: "review_runs_reasoning_tokens_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'running'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text])", name: "review_runs_status_check"
    t.check_constraint "total_tokens IS NULL OR total_tokens >= 0", name: "review_runs_total_tokens_check"
  end

  create_table "source_imports", force: :cascade do |t|
    t.bigint "byte_size"
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.string "detected_content_type"
    t.datetime "expires_at", null: false
    t.text "extracted_text"
    t.string "extraction_version"
    t.string "failure_code"
    t.string "failure_message"
    t.string "imported_format"
    t.string "original_filename", null: false
    t.bigint "resulting_document_id"
    t.string "sha256"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["resulting_document_id"], name: "index_source_imports_on_resulting_document_id", unique: true, where: "(resulting_document_id IS NOT NULL)"
    t.index ["status", "expires_at"], name: "index_source_imports_on_status_and_expires_at"
    t.index ["user_id", "status"], name: "index_source_imports_on_user_id_and_status"
    t.index ["user_id"], name: "index_source_imports_on_user_id"
    t.check_constraint "(status::text = 'consumed'::text) = (consumed_at IS NOT NULL)", name: "source_imports_consumed_at_check"
    t.check_constraint "byte_size IS NULL OR byte_size >= 0 AND byte_size <= 10485760", name: "source_imports_byte_size_check"
    t.check_constraint "imported_format IS NULL OR (imported_format::text = ANY (ARRAY['txt'::character varying, 'md'::character varying, 'docx'::character varying]::text[]))", name: "source_imports_format_check"
    t.check_constraint "sha256 IS NULL OR char_length(sha256::text) = 64", name: "source_imports_sha256_check"
    t.check_constraint "status::text <> 'consumed'::text OR resulting_document_id IS NOT NULL", name: "source_imports_consumed_document_check"
    t.check_constraint "status::text <> 'ready'::text OR extracted_text IS NOT NULL", name: "source_imports_ready_text_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'ready'::character varying, 'failed'::character varying, 'consumed'::character varying]::text[])", name: "source_imports_status_check"
  end

  create_table "translation_runs", force: :cascade do |t|
    t.bigint "cached_tokens"
    t.integer "claimed_job_execution", default: 0, null: false
    t.datetime "completed_at"
    t.bigint "completion_tokens"
    t.decimal "cost", precision: 20, scale: 10
    t.datetime "created_at", null: false
    t.string "error_code"
    t.text "error_message"
    t.integer "execution_attempt", default: 0, null: false
    t.bigint "experiment_id", null: false
    t.datetime "last_claimed_at"
    t.bigint "llm_model_id", null: false
    t.datetime "pending_since"
    t.bigint "prompt_tokens"
    t.string "provider_response_id"
    t.bigint "reasoning_tokens"
    t.string "resolved_model_identifier"
    t.string "scheduled_job_id"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.bigint "total_tokens"
    t.text "translated_text"
    t.datetime "updated_at", null: false
    t.index ["experiment_id", "id"], name: "index_translation_runs_on_experiment_and_id", unique: true
    t.index ["experiment_id", "llm_model_id"], name: "index_translation_runs_on_experiment_id_and_llm_model_id", unique: true
    t.index ["experiment_id"], name: "index_translation_runs_on_experiment_id"
    t.index ["last_claimed_at"], name: "index_translation_runs_on_running_last_claimed_at", where: "((status)::text = 'running'::text)"
    t.index ["llm_model_id"], name: "index_translation_runs_on_llm_model_id"
    t.index ["pending_since"], name: "index_translation_runs_on_pending_since", where: "((status)::text = 'pending'::text)"
    t.check_constraint "claimed_job_execution >= 0", name: "translation_runs_claimed_job_execution_check"
    t.check_constraint "execution_attempt >= 0", name: "translation_runs_execution_attempt_check"
  end

  create_table "translation_workspace_submissions", force: :cascade do |t|
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.bigint "experiment_id"
    t.datetime "expires_at", null: false
    t.string "status", default: "available", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["experiment_id"], name: "index_translation_workspace_submissions_on_experiment_id", unique: true, where: "(experiment_id IS NOT NULL)"
    t.index ["status", "expires_at"], name: "idx_on_status_expires_at_ed9c9803ce"
    t.index ["token_digest"], name: "index_translation_workspace_submissions_on_token_digest", unique: true
    t.index ["user_id", "status"], name: "index_translation_workspace_submissions_on_user_id_and_status"
    t.index ["user_id"], name: "index_translation_workspace_submissions_on_user_id"
    t.check_constraint "char_length(token_digest::text) = 64", name: "translation_workspace_submissions_digest_check"
    t.check_constraint "expires_at > created_at", name: "translation_workspace_submissions_expiry_check"
    t.check_constraint "status::text = 'available'::text AND consumed_at IS NULL AND experiment_id IS NULL OR status::text = 'consumed'::text AND consumed_at IS NOT NULL AND experiment_id IS NOT NULL", name: "translation_workspace_submissions_lifecycle_check"
    t.check_constraint "status::text = ANY (ARRAY['available'::character varying, 'consumed'::character varying]::text[])", name: "translation_workspace_submissions_status_check"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.string "role", default: "user", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email", unique: true
    t.check_constraint "email::text = lower(btrim(email::text)) AND char_length(email::text) >= 3 AND char_length(email::text) <= 254", name: "users_normalized_email_check"
    t.check_constraint "role::text = ANY (ARRAY['user'::character varying::text, 'admin'::character varying::text])", name: "users_role_check"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'disabled'::character varying::text])", name: "users_status_check"
  end

  create_table "workflow_profile_model_selections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_name_snapshot", null: false
    t.string "gateway_snapshot", null: false
    t.bigint "llm_model_id", null: false
    t.string "model_identifier_snapshot", null: false
    t.integer "position", null: false
    t.string "provider_snapshot", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.bigint "workflow_profile_revision_id", null: false
    t.index ["llm_model_id"], name: "index_workflow_profile_model_selections_on_llm_model_id"
    t.index ["workflow_profile_revision_id", "role", "llm_model_id"], name: "index_profile_selections_on_revision_role_model", unique: true
    t.index ["workflow_profile_revision_id", "role", "position"], name: "index_profile_selections_on_revision_role_position", unique: true
    t.index ["workflow_profile_revision_id"], name: "index_profile_model_selections_on_revision"
    t.check_constraint "\"position\" > 0", name: "workflow_profile_model_selections_position_check"
    t.check_constraint "char_length(display_name_snapshot::text) >= 1 AND char_length(display_name_snapshot::text) <= 150", name: "workflow_profile_selections_display_name_check"
    t.check_constraint "char_length(gateway_snapshot::text) >= 1 AND char_length(gateway_snapshot::text) <= 50", name: "workflow_profile_selections_gateway_check"
    t.check_constraint "char_length(model_identifier_snapshot::text) >= 1 AND char_length(model_identifier_snapshot::text) <= 255", name: "workflow_profile_selections_identifier_check"
    t.check_constraint "char_length(provider_snapshot::text) >= 1 AND char_length(provider_snapshot::text) <= 100", name: "workflow_profile_selections_provider_check"
    t.check_constraint "role::text = ANY (ARRAY['translator'::character varying, 'reviewer'::character varying, 'judge'::character varying, 'finalizer'::character varying]::text[])", name: "workflow_profile_model_selections_role_check"
  end

  create_table "workflow_profile_revisions", force: :cascade do |t|
    t.string "completion_mode", null: false
    t.string "configuration_digest", null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.bigint "workflow_profile_id", null: false
    t.index ["configuration_digest"], name: "index_workflow_profile_revisions_on_configuration_digest"
    t.index ["workflow_profile_id", "id"], name: "index_workflow_profile_revisions_on_profile_and_id", unique: true
    t.index ["workflow_profile_id", "version"], name: "index_workflow_profile_revisions_on_profile_and_version", unique: true
    t.index ["workflow_profile_id"], name: "index_workflow_profile_revisions_on_workflow_profile_id"
    t.check_constraint "char_length(btrim(name::text)) >= 1 AND char_length(btrim(name::text)) <= 150", name: "workflow_profile_revisions_name_check"
    t.check_constraint "char_length(configuration_digest::text) = 64", name: "workflow_profile_revisions_digest_check"
    t.check_constraint "completion_mode::text = ANY (ARRAY['winner_draft'::character varying, 'refinement_proposals'::character varying]::text[])", name: "workflow_profile_revisions_completion_mode_check"
    t.check_constraint "description IS NULL OR char_length(description::text) <= 500", name: "workflow_profile_revisions_description_check"
    t.check_constraint "version > 0", name: "workflow_profile_revisions_version_check"
  end

  create_table "workflow_profiles", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.bigint "current_revision_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "active"], name: "index_workflow_profiles_on_user_id_and_active"
    t.index ["user_id"], name: "index_workflow_profiles_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "documents", "projects"
  add_foreign_key "experiments", "documents"
  add_foreign_key "final_translation_versions", "final_translations"
  add_foreign_key "final_translation_versions", "finalization_runs", column: "source_finalization_run_id"
  add_foreign_key "final_translations", "experiments"
  add_foreign_key "final_translations", "final_translation_versions", column: ["id", "current_version_id"], primary_key: ["final_translation_id", "id"], name: "fk_final_translations_current_owned_version"
  add_foreign_key "final_translations", "judge_rounds"
  add_foreign_key "final_translations", "judge_rounds", column: ["judge_round_id", "source_winner_translation_run_id"], primary_key: ["id", "winner_translation_run_id"], name: "fk_final_translations_official_judge_winner"
  add_foreign_key "final_translations", "translation_runs", column: "source_winner_translation_run_id"
  add_foreign_key "final_translations", "translation_runs", column: ["experiment_id", "source_winner_translation_run_id"], primary_key: ["experiment_id", "id"], name: "fk_final_translations_winner_in_experiment"
  add_foreign_key "finalization_rounds", "final_translation_versions", column: "base_final_translation_version_id"
  add_foreign_key "finalization_rounds", "final_translation_versions", column: ["final_translation_id", "base_final_translation_version_id"], primary_key: ["final_translation_id", "id"], name: "fk_finalization_rounds_owned_base_version"
  add_foreign_key "finalization_rounds", "final_translations"
  add_foreign_key "finalization_runs", "finalization_rounds"
  add_foreign_key "finalization_runs", "llm_models", column: "finalizer_llm_model_id"
  add_foreign_key "judge_evaluations", "judge_runs"
  add_foreign_key "judge_evaluations", "translation_runs"
  add_foreign_key "judge_rounds", "review_rounds"
  add_foreign_key "judge_rounds", "translation_runs", column: "winner_translation_run_id"
  add_foreign_key "judge_runs", "judge_rounds"
  add_foreign_key "judge_runs", "llm_models", column: "judge_llm_model_id"
  add_foreign_key "judge_runs", "translation_runs", column: "winner_translation_run_id"
  add_foreign_key "pipeline_events", "pipeline_runs", on_delete: :restrict
  add_foreign_key "pipeline_runs", "experiments", on_delete: :restrict
  add_foreign_key "pipeline_runs", "finalization_rounds", on_delete: :restrict
  add_foreign_key "pipeline_runs", "workflow_profile_revisions", on_delete: :restrict
  add_foreign_key "projects", "users", on_delete: :restrict
  add_foreign_key "review_evaluations", "review_runs"
  add_foreign_key "review_evaluations", "translation_runs"
  add_foreign_key "review_rounds", "experiments"
  add_foreign_key "review_runs", "llm_models", column: "reviewer_llm_model_id"
  add_foreign_key "review_runs", "review_rounds"
  add_foreign_key "source_imports", "documents", column: "resulting_document_id", on_delete: :restrict
  add_foreign_key "source_imports", "users", on_delete: :restrict
  add_foreign_key "translation_runs", "experiments"
  add_foreign_key "translation_runs", "llm_models"
  add_foreign_key "translation_workspace_submissions", "experiments", on_delete: :restrict
  add_foreign_key "translation_workspace_submissions", "users", on_delete: :restrict
  add_foreign_key "workflow_profile_model_selections", "llm_models", on_delete: :restrict
  add_foreign_key "workflow_profile_model_selections", "workflow_profile_revisions", on_delete: :restrict
  add_foreign_key "workflow_profile_revisions", "workflow_profiles", on_delete: :restrict
  add_foreign_key "workflow_profiles", "users", on_delete: :restrict
  add_foreign_key "workflow_profiles", "workflow_profile_revisions", column: ["id", "current_revision_id"], primary_key: ["workflow_profile_id", "id"], name: "fk_workflow_profiles_owned_current_revision"
end
