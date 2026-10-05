module TranslationWorkspaceDrafts
  # Applies one browser autosave to the single draft for a user and context.
  #
  # A save can commit while its response never reaches the browser. The
  # browser then keeps its older identity and version, so the save must be
  # resolvable without them: each page load is an editor with a random id, and
  # every save it sends carries a strictly increasing sequence number (a retry
  # of an unchanged, unacknowledged save reuses its number).
  #
  # - If this editor wrote the draft last, a newer sequence is applied, while
  #   an equal or older one is a replay or a late duplicate. It is acknowledged
  #   with the current identity and version but never overwrites newer text.
  # - Otherwise the save must name the current draft and version
  #   (TranslationWorkspaceDraft#writable_by?), so another tab's newer draft is
  #   reported as a conflict instead of being overwritten.
  #
  # Editors rejected by an ordering conflict or terminal action remain retired
  # through their admission lease. Reloading obtains a new page identity.
  class Save
    Result = Data.define(:draft, :conflict) do
      def conflict?
        conflict
      end
    end

    def self.call(**arguments)
      new(**arguments).call
    end

    def initialize(user:, context_key:, payload:, draft_id:, version:, editor_id: nil, sequence: nil, at: Time.current)
      @user = user
      @context_key = context_key
      @payload = payload
      @draft_id = draft_id.presence
      @version = version
      @editor_id = editor_id
      @sequence = sequence
      @at = at
    end

    def call
      attempts = 0
      begin
        TranslationWorkspaceDraft.transaction(requires_new: true) { save_locked }
      rescue ActiveRecord::RecordNotUnique
        # A concurrent first save created the draft (the unique index on
        # user_id and context_key rejected this insert); resolve against it.
        attempts += 1
        retry if attempts == 1
        raise
      end
    end

    private

    attr_reader :at, :context_key, :draft_id, :editor_id, :payload, :sequence, :user, :version

    def save_locked
      @editor = TranslationWorkspaceDraftEditor.lock_for(user:, context_key:, editor_id:)
      draft = user.translation_workspace_drafts.lock.find_by(context_key:)
      return Result.new(draft:, conflict: true) if @editor&.rejected?
      if draft && draft.expires_at <= at
        draft.delete
        draft = nil
      end

      if draft.nil?
        if draft_id
          raise ActiveRecord::RecordNotFound, "The saved draft no longer exists" unless @editor
          return rejected(draft)
        end
        return Result.new(draft: nil, conflict: true) if @editor && sequence <= @editor.sequence

        return saved(user.translation_workspace_drafts.create!(context_key:, **written_attributes))
      end
      unless draft.writable_by?(editor_id:, public_id: draft_id, version:)
        return rejected(draft)
      end
      return saved(draft) if editor_id && draft.editor_id == editor_id && sequence <= draft.editor_sequence

      saved(replace(draft))
    end

    # A draft that no longer decrypts cannot be compared with its new value.
    # The page said it could not be restored and that the next change saved
    # replaces it, so this save does exactly that.
    def replace(draft)
      draft.update!(written_attributes)
      draft
    rescue ActiveRecord::Encryption::Errors::Decryption
      draft.delete
      user.translation_workspace_drafts.create!(context_key:, **written_attributes)
    end

    def written_attributes
      {
        workspace_payload: JSON.generate(payload),
        expires_at: at + TranslationWorkspaceDraft::RETENTION,
        editor_id: editor_id,
        editor_sequence: sequence
      }
    end

    def saved(draft)
      @editor.update!(sequence:) if @editor && sequence > @editor.sequence
      Result.new(draft:, conflict: false)
    end

    def rejected(draft)
      @editor.update!(sequence: [ @editor.sequence, sequence ].max, rejected: true) if @editor
      Result.new(draft:, conflict: true)
    end
  end
end
