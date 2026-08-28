class CreateSourceImports < ActiveRecord::Migration[8.1]
  def change
    create_table :source_imports do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.references :resulting_document,
                   index: false,
                   foreign_key: { to_table: :documents, on_delete: :restrict }
      t.string :status, null: false, default: "pending"
      t.string :original_filename, null: false
      t.string :detected_content_type
      t.string :imported_format
      t.bigint :byte_size
      t.string :sha256
      t.text :extracted_text
      t.string :extraction_version
      t.string :failure_code
      t.string :failure_message
      t.datetime :expires_at, null: false
      t.datetime :consumed_at

      t.timestamps

      t.index %i[user_id status]
      t.index %i[status expires_at]
      t.index :resulting_document_id, unique: true, where: "resulting_document_id IS NOT NULL"
      t.check_constraint "status IN ('pending', 'ready', 'failed', 'consumed')",
                         name: :source_imports_status_check
      t.check_constraint "byte_size IS NULL OR (byte_size >= 0 AND byte_size <= 10485760)",
                         name: :source_imports_byte_size_check
      t.check_constraint "sha256 IS NULL OR char_length(sha256) = 64",
                         name: :source_imports_sha256_check
      t.check_constraint "imported_format IS NULL OR imported_format IN ('txt', 'md', 'docx')",
                         name: :source_imports_format_check
      t.check_constraint "(status = 'consumed') = (consumed_at IS NOT NULL)",
                         name: :source_imports_consumed_at_check
      t.check_constraint "status <> 'consumed' OR resulting_document_id IS NOT NULL",
                         name: :source_imports_consumed_document_check
      t.check_constraint "status <> 'ready' OR extracted_text IS NOT NULL",
                         name: :source_imports_ready_text_check
    end
  end
end
