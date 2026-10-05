class BoundReplayCoordinationLifetimes < ActiveRecord::Migration[8.1]
  TABLE_KEYS = {
    source_import_retirements: :request_key,
    translation_workspace_draft_editors: :editor_id,
    translation_reference_creations: :creation_key
  }.freeze
  IDENTITY_SQL = "'^[0-9a-f]{32}$|^[A-Za-z0-9_-]{16,200}--[0-9a-f]{64}\\.[0-9a-f]{32}$'"

  def up
    TABLE_KEYS.each do |table, key|
      change_column table, key, :string, limit: 512, null: false
      # Existing identities get a full admission window after the upgrade,
      # independent of how old the draft/action happened to be beforehand.
      add_column table, :expires_at, :datetime, null: false,
        default: -> { "CURRENT_TIMESTAMP + interval '24 hours'" }
      add_index table, %i[expires_at id], name: "index_#{table}_on_expiry"
    end
    change_column :source_imports, :request_key, :string, limit: 512
    change_column :translation_workspace_drafts, :editor_id, :string, limit: 512
    replace_checks(new_format: true)
    remove_index :translation_reference_creations, name: "index_reference_creations_on_expiring_failure"
    add_index :translation_reference_creations, %i[created_at id], where: "status = 'failed'",
      name: "index_reference_creations_on_expiring_failure"
  end

  def down
    # Signed identities cannot be represented by the old protocol. Rollback
    # is supported before new traffic; never silently truncate protective keys.
    tables = TABLE_KEYS.merge(source_imports: :request_key, translation_workspace_drafts: :editor_id)
    tables.each do |table, key|
      if select_value("SELECT EXISTS (SELECT 1 FROM #{table} WHERE length(#{key}) > 32)")
        raise ActiveRecord::IrreversibleMigration, "Signed identities exist; rollback requires draining their lifecycle first"
      end
    end
    replace_checks(new_format: false)
    TABLE_KEYS.each do |table, key|
      remove_index table, name: "index_#{table}_on_expiry"
      remove_column table, :expires_at
      change_column table, key, :string, limit: 32, null: false
    end
    change_column :source_imports, :request_key, :string, limit: nil
    change_column :translation_workspace_drafts, :editor_id, :string, limit: nil
    remove_index :translation_reference_creations, name: "index_reference_creations_on_expiring_failure"
    add_index :translation_reference_creations, :created_at, where: "status = 'failed'",
      name: "index_reference_creations_on_expiring_failure"
  end

  private

  def replace_checks(new_format:)
    format = new_format ? IDENTITY_SQL : "'^[0-9a-f]{32}$'"
    {
      source_import_retirements: [ :request_key, "source_import_retirements_request_key_check" ],
      translation_workspace_draft_editors: [ :editor_id, "workspace_draft_editors_identity_check" ],
      translation_reference_creations: [ :creation_key, "reference_creations_identity_check" ],
      source_imports: [ :request_key, "source_imports_request_key_check" ],
      translation_workspace_drafts: [ :editor_id, "workspace_drafts_editor_id_check" ]
    }.each do |table, (key, name)|
      remove_check_constraint table, name: name
      expression = "#{key} ~ #{format}"
      expression += " AND payload_digest ~ '^[0-9a-f]{64}$'" if table == :translation_reference_creations
      expression = "#{key} IS NULL OR (#{expression})" if table.in?([ :source_imports, :translation_workspace_drafts ])
      add_check_constraint table, expression, name: name
    end
  end
end
