class TranslationReference < ApplicationRecord
  belongs_to :user
  belongs_to :current_revision,
             class_name: "TranslationReferenceRevision",
             optional: true,
             inverse_of: :current_for_reference

  has_many :revisions,
           -> { order(version: :desc) },
           class_name: "TranslationReferenceRevision",
           dependent: :restrict_with_error,
           inverse_of: :translation_reference

  scope :active, -> { where(active: true) }

  validates :current_revision, presence: true, on: :update
  validate :current_revision_belongs_to_reference

  before_destroy :prevent_destruction

  delegate :title, :source_language, :target_language, :source_text,
           :approved_translation, :configuration_digest,
           to: :current_revision, allow_nil: true

  private

  def current_revision_belongs_to_reference
    return unless current_revision
    return if current_revision.translation_reference_id == id

    errors.add(:current_revision, "must belong to this reference")
  end

  def prevent_destruction
    errors.add(:base, "Translation references are archived instead of deleted")
    throw :abort
  end
end
