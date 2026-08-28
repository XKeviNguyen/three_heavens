class AddSourceProvenanceToDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :documents, :source_kind, :string, null: false, default: "pasted_text"
    add_column :documents, :source_format, :string
    add_column :documents, :original_filename, :string
    add_column :documents, :detected_content_type, :string
    add_column :documents, :original_byte_size, :bigint
    add_column :documents, :source_sha256, :string
    add_column :documents, :extraction_version, :string

    add_check_constraint :documents,
                         "source_kind IN ('pasted_text', 'uploaded_file')",
                         name: :documents_source_kind_check
    add_check_constraint :documents,
                         "source_format IS NULL OR source_format IN ('txt', 'md', 'docx')",
                         name: :documents_source_format_check
    add_check_constraint :documents,
                         "original_byte_size IS NULL OR (original_byte_size >= 0 AND original_byte_size <= 10485760)",
                         name: :documents_original_byte_size_check
    add_check_constraint :documents,
                         "source_sha256 IS NULL OR char_length(source_sha256) = 64",
                         name: :documents_source_sha256_check
  end
end
