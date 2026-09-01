class MethodologyProfileRevision < ApplicationRecord
  MAXIMUM_GUIDANCE_CHARACTERS = 10_000

  belongs_to :methodology_profile, inverse_of: :revisions
  has_one :current_for_profile,
          class_name: "MethodologyProfile",
          foreign_key: :current_revision_id,
          dependent: :restrict_with_error,
          inverse_of: :current_revision
  has_many :experiments, dependent: :restrict_with_error

  validates :version,
            numericality: { only_integer: true, greater_than: 0 },
            uniqueness: { scope: :methodology_profile_id }
  validates :name, presence: true, length: { maximum: 150 }
  validates :description, length: { maximum: 500 }, allow_blank: true
  validates :source_language, :target_language, presence: true, length: { maximum: 100 }
  validates :guidance, presence: true, length: { maximum: MAXIMUM_GUIDANCE_CHARACTERS }
  validates :configuration_digest, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }

  before_validation :normalize_values
  before_validation :assign_configuration_digest
  before_update :prevent_mutation
  before_destroy :prevent_destruction

  def language_pair_matches?(source_language:, target_language:)
    TranslationLanguagePair.matches?(self, source_language:, target_language:)
  end

  private

  def normalize_values
    self.name = name.to_s.strip
    self.description = description.to_s.strip.presence
    self.source_language = source_language.to_s.strip
    self.target_language = target_language.to_s.strip
    self.guidance = guidance.to_s.strip
  end

  def assign_configuration_digest
    self.configuration_digest = MethodologyProfiles::ConfigurationDigest.call(self)
  end

  def prevent_mutation
    errors.add(:base, "Methodology profile revisions are immutable")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Methodology profile revisions cannot be deleted")
    throw :abort
  end
end
