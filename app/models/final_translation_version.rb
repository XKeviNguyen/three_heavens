class FinalTranslationVersion < ApplicationRecord
  MAX_CONTENT_LENGTH = Ai::UsageLimits::MAX_SOURCE_CHARACTERS
  MAX_CHANGE_NOTE_LENGTH = 500

  belongs_to :final_translation, inverse_of: :versions
  belongs_to :source_finalization_run, class_name: "FinalizationRun", optional: true

  has_many :based_finalization_rounds,
           class_name: "FinalizationRound",
           foreign_key: :base_final_translation_version_id,
           inverse_of: :base_version,
           dependent: :restrict_with_error
  has_many :current_final_translations,
           class_name: "FinalTranslation",
           foreign_key: :current_version_id,
           inverse_of: :current_version,
           dependent: :restrict_with_error

  enum :origin, {
    seed: "seed",
    manual: "manual",
    ai_applied: "ai_applied",
    restored: "restored"
  }, validate: true

  validates :version_number,
            numericality: { only_integer: true, greater_than: 0 },
            uniqueness: { scope: :final_translation_id }
  validates :content, presence: true, length: { maximum: MAX_CONTENT_LENGTH }
  validates :change_note, length: { maximum: MAX_CHANGE_NOTE_LENGTH }, allow_nil: true
  validate :source_run_matches_origin
  validate :source_run_belongs_to_workspace
  validate :seed_origin_matches_first_version

  before_update :prevent_mutation
  before_destroy :prevent_destruction

  private

  def source_run_matches_origin
    if ai_applied? && source_finalization_run.nil?
      errors.add(:source_finalization_run, "must be present for an applied AI proposal")
    elsif !ai_applied? && source_finalization_run.present?
      errors.add(:source_finalization_run, "is only allowed for an applied AI proposal")
    end
  end

  def source_run_belongs_to_workspace
    return unless source_finalization_run && final_translation
    return if source_finalization_run.finalization_round.final_translation_id == final_translation_id

    errors.add(:source_finalization_run, "must belong to this final translation")
  end

  def seed_origin_matches_first_version
    return if seed? == (version_number == 1)

    errors.add(:origin, "must be seed only for version 1")
  end

  def prevent_mutation
    errors.add(:base, "Historical final translation versions are immutable")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Historical final translation versions cannot be deleted")
    throw :abort
  end
end
