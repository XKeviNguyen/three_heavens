class FinalTranslation < ApplicationRecord
  belongs_to :experiment
  belongs_to :judge_round
  belongs_to :source_winner_translation_run, class_name: "TranslationRun"
  belongs_to :current_version, class_name: "FinalTranslationVersion"

  has_many :versions,
           -> { order(version_number: :desc) },
           class_name: "FinalTranslationVersion",
           inverse_of: :final_translation,
           dependent: :restrict_with_error
  has_many :finalization_rounds, dependent: :restrict_with_error

  enum :status, { draft: "draft", finalized: "finalized" }, validate: true

  validates :judge_round_id, uniqueness: true
  validate :judge_round_belongs_to_experiment
  validate :source_winner_is_valid
  validate :current_version_belongs_to_workspace
  validate :finalized_at_matches_status

  private

  def judge_round_belongs_to_experiment
    return if judge_round&.experiment&.id == experiment_id

    errors.add(:judge_round, "must belong to the final translation experiment")
  end

  def source_winner_is_valid
    return unless source_winner_translation_run && judge_round

    if source_winner_translation_run.experiment_id != experiment_id
      errors.add(:source_winner_translation_run, "must belong to the final translation experiment")
    end
    unless source_winner_translation_run_id == judge_round.winner_translation_run_id
      errors.add(:source_winner_translation_run, "must be the judge round official winner")
    end
  end

  def current_version_belongs_to_workspace
    return unless current_version
    return if current_version.final_translation_id == id

    errors.add(:current_version, "must belong to this final translation")
  end

  def finalized_at_matches_status
    if finalized? && finalized_at.nil?
      errors.add(:finalized_at, "must be present when finalized")
    elsif draft? && finalized_at.present?
      errors.add(:finalized_at, "must be blank while draft")
    end
  end
end
