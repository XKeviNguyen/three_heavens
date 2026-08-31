class Glossary < ApplicationRecord
  belongs_to :user
  belongs_to :current_revision, class_name: "GlossaryRevision", optional: true, inverse_of: :current_for_glossary

  has_many :revisions, -> { order(version: :desc) }, class_name: "GlossaryRevision", dependent: :restrict_with_error, inverse_of: :glossary

  scope :active, -> { where(active: true) }

  validates :current_revision, presence: true, on: :update
  validate :current_revision_belongs_to_glossary

  before_destroy :prevent_destruction

  delegate :name, :description, :source_language, :target_language, :configuration_digest, to: :current_revision, allow_nil: true

  private

  def current_revision_belongs_to_glossary
    return unless current_revision
    return if current_revision.glossary_id == id

    errors.add(:current_revision, "must belong to this glossary")
  end

  def prevent_destruction
    errors.add(:base, "Glossaries are archived instead of deleted")
    throw :abort
  end
end
