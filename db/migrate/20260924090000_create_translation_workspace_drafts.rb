class CreateTranslationWorkspaceDrafts < ActiveRecord::Migration[8.1]
  def change
    create_table :translation_workspace_drafts do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :public_id, null: false
      t.string :context_key, null: false
      t.text :workspace_payload, null: false
      t.integer :lock_version, null: false, default: 0
      t.datetime :expires_at, null: false

      t.timestamps

      t.index :public_id, unique: true
      t.index %i[user_id context_key], unique: true
      t.index %i[expires_at id]
      t.check_constraint "lock_version >= 0", name: :workspace_drafts_lock_version_check
      t.check_constraint "char_length(context_key) <= 80", name: :workspace_drafts_context_key_check
    end
  end
end
