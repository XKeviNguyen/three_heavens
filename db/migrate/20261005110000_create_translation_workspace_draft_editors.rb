class CreateTranslationWorkspaceDraftEditors < ActiveRecord::Migration[8.1]
  def change
    create_table :translation_workspace_draft_editors do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :context_key, null: false, limit: 80
      t.string :editor_id, null: false, limit: 32
      t.bigint :sequence, null: false, default: 0
      t.index %i[user_id context_key editor_id], unique: true, name: :index_workspace_draft_editors_on_identity
      t.check_constraint "editor_id ~ '^[0-9a-f]{32}$'", name: :workspace_draft_editors_identity_check
      t.check_constraint "sequence >= 0 AND sequence <= 9007199254740991", name: :workspace_draft_editors_sequence_check
    end
    # Preserve the current writer of drafts saved before this ledger existed,
    # including drafts that will next be removed by launch or expiry cleanup.
    reversible do |direction|
      direction.up do
        execute <<~SQL
          INSERT INTO translation_workspace_draft_editors (user_id, context_key, editor_id, sequence)
          SELECT user_id, context_key, editor_id, editor_sequence
          FROM translation_workspace_drafts WHERE editor_id IS NOT NULL
        SQL
      end
    end
  end
end
