class TranslationWorkspaceDraftEditor < ApplicationRecord
  class Expired < StandardError; end
  belongs_to :user
  attr_readonly :user_id, :context_key, :editor_id
  validates :context_key, presence: true, length: { maximum: 80 }
  validates :editor_id, format: { with: TranslationWorkspaceDraft::EDITOR_ID_FORMAT }
  validates :sequence, numericality: { only_integer: true, greater_than_or_equal_to: 0,
    less_than_or_equal_to: TranslationWorkspaceDraft::MAX_EDITOR_SEQUENCE }

  # Called inside the save/discard transaction. Inserting before locking also
  # orders a discard that reaches the server before the editor's first save.
  def self.lock_for(user:, context_key:, editor_id:)
    raise Expired unless editor_id.present?

    new(user:, context_key:, editor_id:, sequence: 0).validate!
    existing = find_by(user_id: user.id, context_key:, editor_id:)
    raise Expired unless ReplayIdentity.valid?(editor_id, existing:)
    unless existing && editor_id.match?(ReplayIdentity::LEGACY_FORMAT)
      raise Expired unless ReplayIdentity.complete?(editor_id, user:, context_key:)
    end
    ReplayIdentity.admit!(ledger: self, user:, identity: { context_key:, editor_id: }) unless existing

    insert_all([ { user_id: user.id, context_key:, editor_id:, sequence: 0,
      expires_at: ReplayIdentity.expires_at(editor_id) || existing.expires_at } ],
      unique_by: :index_workspace_draft_editors_on_identity)
    editor = lock.find_by!(user_id: user.id, context_key:, editor_id:)
    raise Expired unless ReplayIdentity.valid?(editor_id, existing: editor)

    editor
  end

  def self.purge_expired(at: Time.current, batch_size: 100)
    limit = Integer(batch_size).clamp(1, 100)
    transaction do
      ids = where(expires_at: ..at).order(:expires_at, :id).limit(limit).lock("FOR UPDATE SKIP LOCKED").pluck(:id)
      where(id: ids).delete_all
    end
  end
end
