class CreateTranslationWorkspaceDraftEditors < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    previous = select_value("SHOW lock_timeout")
    connection.execute "SET lock_timeout = '1s'"
    unless table_exists?(:translation_workspace_draft_editors)
      transaction do
        create_table :translation_workspace_draft_editors do |t|
          t.references :user, null: false, foreign_key: { on_delete: :cascade }
          t.string :context_key, null: false, limit: 80
          t.string :editor_id, null: false, limit: 512
          t.string :state, null: false, default: "active"
          t.bigint :sequence, null: false, default: 0
          t.datetime :expires_at, null: false, default: -> { "CURRENT_TIMESTAMP + interval '24 hours'" }
          t.index %i[user_id context_key editor_id], unique: true, name: :index_workspace_draft_editors_on_identity
          t.check_constraint "editor_id ~ '^[0-9a-f]{32}$|^[A-Za-z0-9_-]{16,255}--[0-9a-f]{64}\\.[0-9a-f]{32}$'", name: :workspace_draft_editors_identity_check
          t.check_constraint "state::text = ANY (ARRAY['active'::text, 'rejected'::text, 'retired'::text])", name: :workspace_draft_editors_state_check
          t.check_constraint "sequence >= 0 AND sequence <= 9007199254740991", name: :workspace_draft_editors_sequence_check
        end
        add_index :translation_workspace_draft_editors, %i[expires_at id], name: "index_translation_workspace_draft_editors_on_expiry"
      end
    end
    # Preserve the current writer of drafts saved before this ledger existed,
    # including drafts that will next be removed by launch or expiry cleanup.
    execute <<~SQL
      INSERT INTO translation_workspace_draft_editors (user_id, context_key, editor_id, sequence)
      SELECT user_id, context_key, editor_id, editor_sequence
      FROM translation_workspace_drafts WHERE editor_id IS NOT NULL
      ON CONFLICT (user_id, context_key, editor_id) DO NOTHING
    SQL
  ensure
    connection.execute "SET lock_timeout = #{connection.quote(previous)}" if previous
  end
  def down
    previous = select_value("SHOW lock_timeout")
    connection.execute "SET lock_timeout = '1s'"
    drop_table :translation_workspace_draft_editors, if_exists: true
  ensure
    connection.execute "SET lock_timeout = #{connection.quote(previous)}" if previous
  end
end
