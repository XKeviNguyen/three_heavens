class TranslationWorkspaceDraftEditor < ApplicationRecord
  belongs_to :user
  attr_readonly :user_id, :context_key, :editor_id
  validates :context_key, presence: true, length: { maximum: 80 }
  validates :editor_id, format: { with: TranslationWorkspaceDraft::EDITOR_ID_FORMAT }
  validates :sequence, numericality: { only_integer: true, greater_than_or_equal_to: 0,
    less_than_or_equal_to: TranslationWorkspaceDraft::MAX_EDITOR_SEQUENCE }

  # Called inside the save/discard transaction. Inserting before locking also
  # orders a discard that reaches the server before the editor's first save.
  def self.lock_for(user:, context_key:, editor_id:)
    return unless editor_id.present?

    new(user:, context_key:, editor_id:, sequence: 0).validate!
    insert_all([ { user_id: user.id, context_key:, editor_id:, sequence: 0 } ],
      unique_by: :index_workspace_draft_editors_on_identity)
    lock.find_by!(user_id: user.id, context_key:, editor_id:)
  end
end
