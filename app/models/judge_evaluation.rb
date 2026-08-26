class JudgeEvaluation < ApplicationRecord
  SCORE_RANGE = 1..100
  TEXT_ATTRIBUTES = %i[rationale strengths risks].freeze

  belongs_to :judge_run
  belongs_to :translation_run

  validates :translation_run_id, uniqueness: { scope: :judge_run_id }
  validates :anonymous_label,
            presence: true,
            format: { with: /\ACandidate [A-Z]+\z/ },
            uniqueness: { scope: :judge_run_id }
  validates :rank, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :rank, uniqueness: { scope: :judge_run_id }, allow_nil: true
  validates :overall_score,
            numericality: { only_integer: true, in: SCORE_RANGE },
            allow_nil: true
  validates(*TEXT_ATTRIBUTES, length: { maximum: 5_000 }, allow_nil: true)
  validate :evaluation_fields_are_all_present_or_all_blank
  validate :translation_belongs_to_judged_experiment

  def complete?
    rank.present? && overall_score.present? &&
      TEXT_ATTRIBUTES.all? { |attribute| public_send(attribute).present? }
  end

  private

  def evaluation_fields_are_all_present_or_all_blank
    fields = [ :rank, :overall_score, *TEXT_ATTRIBUTES ]
    return if fields.all? { |attribute| public_send(attribute).nil? }
    return if complete?

    errors.add(:base, "Evaluation fields must be either complete or blank")
  end

  def translation_belongs_to_judged_experiment
    judged_experiment_id = judge_run&.judge_round&.review_round&.experiment_id
    return if translation_run&.experiment_id == judged_experiment_id

    errors.add(:translation_run, "must belong to the judged experiment")
  end
end
