class AllowPdfSourceFormats < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :source_imports, name: :source_imports_format_check
    remove_check_constraint :documents, name: :documents_source_format_check
    add_check_constraint :source_imports, "imported_format IS NULL OR imported_format IN ('txt', 'md', 'docx', 'pdf')", name: :source_imports_format_check
    add_check_constraint :documents, "source_format IS NULL OR source_format IN ('txt', 'md', 'docx', 'pdf')", name: :documents_source_format_check
  end

  def down
    remove_check_constraint :source_imports, name: :source_imports_format_check
    remove_check_constraint :documents, name: :documents_source_format_check
    add_check_constraint :source_imports, "imported_format IS NULL OR imported_format IN ('txt', 'md', 'docx')", name: :source_imports_format_check
    add_check_constraint :documents, "source_format IS NULL OR source_format IN ('txt', 'md', 'docx')", name: :documents_source_format_check
  end
end
