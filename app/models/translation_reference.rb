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

  # The edit form prefills both texts from the revision it was based on. Text
  # still equal to that revision was not supplied by the user, so an uploaded
  # file replaces it instead of conflicting with it (the controller clears it;
  # the file input only warns about text that would conflict). Browsers submit
  # a text area's line breaks as CRLF, so line endings are compared normalized.
  def prefilled_text?(expected_version, field, text)
    version = Integer(expected_version.to_s, exception: false)
    return false unless version

    revision = current_revision&.version == version ? current_revision : revisions.find_by(version:)
    revision.present? && normalize_line_endings(text) == normalize_line_endings(revision.public_send(field))
  end

  private

  def normalize_line_endings(text)
    text.to_s.gsub(/\r\n?/, "\n")
  end

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
