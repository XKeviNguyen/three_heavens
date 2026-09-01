class MethodologyProfile < ApplicationRecord
  belongs_to :user
  belongs_to :current_revision,
             class_name: "MethodologyProfileRevision",
             optional: true,
             inverse_of: :current_for_profile

  has_many :revisions,
           -> { order(version: :desc) },
           class_name: "MethodologyProfileRevision",
           dependent: :restrict_with_error,
           inverse_of: :methodology_profile

  scope :active, -> { where(active: true) }

  validates :current_revision, presence: true, on: :update
  validate :current_revision_belongs_to_profile

  before_destroy :prevent_destruction

  delegate :name, :description, :source_language, :target_language,
           :guidance, :configuration_digest,
           to: :current_revision, allow_nil: true

  private

  def current_revision_belongs_to_profile
    return unless current_revision
    return if current_revision.methodology_profile_id == id

    errors.add(:current_revision, "must belong to this methodology profile")
  end

  def prevent_destruction
    errors.add(:base, "Methodology profiles are archived instead of deleted")
    throw :abort
  end
end
