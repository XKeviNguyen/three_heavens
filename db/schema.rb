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

ActiveRecord::Schema[8.1].define(version: 2026_08_24_064807) do
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
    t.string "name"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["document_id"], name: "index_experiments_on_document_id"
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

  create_table "translation_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "experiment_id", null: false
    t.bigint "llm_model_id", null: false
    t.string "status", default: "pending", null: false
    t.text "translated_text"
    t.datetime "updated_at", null: false
    t.index ["experiment_id"], name: "index_translation_runs_on_experiment_id"
    t.index ["llm_model_id"], name: "index_translation_runs_on_llm_model_id"
  end

  add_foreign_key "documents", "projects"
  add_foreign_key "experiments", "documents"
  add_foreign_key "translation_runs", "experiments"
  add_foreign_key "translation_runs", "llm_models"
end
