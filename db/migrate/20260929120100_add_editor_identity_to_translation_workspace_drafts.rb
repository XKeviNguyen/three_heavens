# Records which editor (one browser page load) last wrote each draft and the
# sequence number of that save, so a save whose response was lost can be
# recognized and later edits from the same page are neither refused nor
# overwritten by a late duplicate. Existing drafts have no recorded editor.
class AddEditorIdentityToTranslationWorkspaceDrafts < ActiveRecord::Migration[8.1]
  def change
    add_column :translation_workspace_drafts, :editor_id, :string
    add_column :translation_workspace_drafts, :editor_sequence, :bigint
    add_check_constraint :translation_workspace_drafts,
                         "(editor_id IS NULL) = (editor_sequence IS NULL)",
                         name: "workspace_drafts_editor_pair_check"
    add_check_constraint :translation_workspace_drafts,
                         "editor_id IS NULL OR editor_id ~ '^[0-9a-f]{32}$'",
                         name: "workspace_drafts_editor_id_check"
    add_check_constraint :translation_workspace_drafts,
                         "editor_sequence IS NULL OR editor_sequence > 0",
                         name: "workspace_drafts_editor_sequence_check"
  end
end
