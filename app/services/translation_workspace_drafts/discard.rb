module TranslationWorkspaceDrafts
  class Discard
    def self.call(user:, context_key:, draft_id:, version:, editor_id:, sequence: nil)
      TranslationWorkspaceDraft.transaction do
        editor = TranslationWorkspaceDraftEditor.lock_for(user:, context_key:, editor_id:)
        draft = user.translation_workspace_drafts.current.lock.find_by(context_key:)
        next draft if editor&.retired?
        if editor&.rejected? || (draft.nil? && draft_id.present?)
          raise ActiveRecord::RecordNotFound if !editor && draft_id.present?
          editor.update!(state: :rejected, sequence: [ editor.sequence, sequence || 0 ].max) if editor
          next draft || :conflict
        end
        raise ActionController::BadRequest if draft && draft_id.present? && version.nil?

        if draft && (!draft.writable_by?(editor_id:, public_id: draft_id.presence, version:) ||
            (sequence && draft.editor_id == editor_id && draft.editor_sequence > sequence))
          editor.update!(state: :rejected, sequence: [ editor.sequence, sequence || 0 ].max) if editor
          next draft
        end

        if editor
          watermark = [ editor.sequence, sequence || 0, draft&.editor_id == editor_id ? draft.editor_sequence : 0 ].max
          editor.update!(sequence: watermark, state: :retired)
        end
        draft&.destroy!
        nil
      end
    end

    def self.after_launch(user:, context_key:, public_id:, version:)
      TranslationWorkspaceDraft.transaction do
        draft = user.translation_workspace_drafts.find_by(context_key:, public_id:, lock_version: version)
        next unless draft

        editor = TranslationWorkspaceDraftEditor.where(user:, context_key:, editor_id: draft.editor_id).lock.first
        current = user.translation_workspace_drafts.lock.find_by(id: draft.id, lock_version: version)
        next unless current

        editor.update!(state: :retired) if editor
        current.delete
      end
    end
  end
end
