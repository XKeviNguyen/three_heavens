class TranslationReferenceRevision < ApplicationRecord
  MAXIMUM_SOURCE_CHARACTERS = Ai::UsageLimits::MAX_SOURCE_CHARACTERS
  MAXIMUM_TRANSLATION_CHARACTERS = FinalTranslationVersion::MAX_CONTENT_LENGTH

  belongs_to :translation_reference, inverse_of: :revisions
  has_one :current_for_reference,
          class_name: "TranslationReference",
          foreign_key: :current_revision_id,
          dependent: :restrict_with_error,
          inverse_of: :current_revision
  has_many :experiment_reference_revisions, dependent: :restrict_with_error
  has_many :experiments, through: :experiment_reference_revisions

  validates :version,
            numericality: { only_integer: true, greater_than: 0 },
            uniqueness: { scope: :translation_reference_id }
  validates :title, presence: true, length: { maximum: 150 }
  validates :source_language, :target_language, presence: true, length: { maximum: 100 }
  validates :source_text, presence: true, length: { maximum: MAXIMUM_SOURCE_CHARACTERS }
  validates :approved_translation,
            presence: true,
            length: { maximum: MAXIMUM_TRANSLATION_CHARACTERS }
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
    self.title = title.to_s.strip
    self.source_language = source_language.to_s.strip
    self.target_language = target_language.to_s.strip
    self.source_text = source_text.to_s.strip
    self.approved_translation = approved_translation.to_s.strip
  end

  def assign_configuration_digest
    self.configuration_digest = TranslationReferences::ConfigurationDigest.call(self)
  end

  def prevent_mutation
    errors.add(:base, "Translation reference revisions are immutable")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Translation reference revisions cannot be deleted")
    throw :abort
  end
end
