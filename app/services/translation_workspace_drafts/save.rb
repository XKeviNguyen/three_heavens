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
  # Saves without an editor identity (pages loaded before this protocol) keep
  # the plain optimistic-concurrency behaviour.
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
        # A concurrent first save created the draft; resolve against it.
        attempts += 1
        retry if attempts == 1
        raise
      end
    end

    private

    attr_reader :at, :context_key, :draft_id, :editor_id, :payload, :sequence, :user, :version

    def save_locked
      draft = user.translation_workspace_drafts.lock.find_by(context_key:)
      if draft && draft.expires_at <= at
        draft.delete
        draft = nil
      end

      if draft.nil?
        raise ActiveRecord::RecordNotFound, "The saved draft no longer exists" if draft_id

        return saved(user.translation_workspace_drafts.create!(context_key:, **written_attributes))
      end
      return Result.new(draft:, conflict: true) unless draft.writable_by?(editor_id:, public_id: draft_id, version:)
      return saved(draft) if editor_id && draft.editor_id == editor_id && sequence <= draft.editor_sequence

      draft.update!(written_attributes)
      saved(draft)
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
      Result.new(draft:, conflict: false)
    end
  end
end
