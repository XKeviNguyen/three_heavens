class FinalizationRound < ApplicationRecord
  TERMINAL_STATUSES = %w[completed failed].freeze

  belongs_to :final_translation
  belongs_to :base_version,
             class_name: "FinalTranslationVersion",
             foreign_key: :base_final_translation_version_id,
             inverse_of: :based_finalization_rounds

  has_many :finalization_runs, dependent: :restrict_with_error

  enum :status, {
    running: "running",
    completed: "completed",
    failed: "failed"
  }, validate: true

  validates :selection_key, presence: true, length: { is: 64 }
  validate :base_version_belongs_to_workspace
  validate :terminal_status_matches_runs

  before_destroy :prevent_destruction

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  private

  def base_version_belongs_to_workspace
    return if base_version&.final_translation_id == final_translation_id

    errors.add(:base_version, "must belong to this final translation")
  end

  def terminal_status_matches_runs
    return unless terminal?

    runs = finalization_runs.to_a
    unless runs.any? && runs.all?(&:terminal?)
      errors.add(:finalization_runs, "must all be terminal")
      return
    end

    if completed? && runs.any?(&:failed?)
      errors.add(:status, "cannot be completed when a finalizer failed")
    elsif failed? && runs.none?(&:failed?)
      errors.add(:status, "must reflect a failed finalizer")
    end
  end

  def prevent_destruction
    errors.add(:base, "Historical finalization rounds cannot be deleted")
    throw :abort
  end
end
