module TranslationWorkspaceDrafts
  class Discard
    def self.call(user:, context_key:, draft_id:, version:, editor_id:, sequence: nil)
      TranslationWorkspaceDraft.transaction do
        editor = TranslationWorkspaceDraftEditor.lock_for(user:, context_key:, editor_id:)
        draft = user.translation_workspace_drafts.current.lock.find_by(context_key:)
        raise ActiveRecord::RecordNotFound if draft.nil? && draft_id.present?
        raise ActionController::BadRequest if draft && draft_id.present? && version.nil?

        if draft && (!draft.writable_by?(editor_id:, public_id: draft_id.presence, version:) ||
            (sequence && draft.editor_id == editor_id && draft.editor_sequence > sequence))
          editor.destroy! if editor&.sequence == 0
          next draft
        end

        if editor
          watermark = [ editor.sequence, sequence || 0, draft&.editor_id == editor_id ? draft.editor_sequence : 0 ].max
          editor.update!(sequence: watermark)
        end
        draft&.destroy!
        nil
      end
    end
  end
end
