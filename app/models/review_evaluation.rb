class ReviewEvaluation < ApplicationRecord
  SCORE_RANGE = 1..10
  SCORE_ATTRIBUTES = %i[
    faithfulness_score
    naturalness_score
    terminology_score
    instruction_adherence_score
    overall_score
  ].freeze
  FEEDBACK_ATTRIBUTES = %i[
    strengths
    issues
    recommended_corrections
  ].freeze

  belongs_to :review_run
  belongs_to :translation_run

  validates :translation_run_id, uniqueness: { scope: :review_run_id }
  validates :anonymous_label,
            presence: true,
            format: { with: /\ACandidate [A-Z]+\z/ },
            uniqueness: { scope: :review_run_id }
  validates(*SCORE_ATTRIBUTES,
            numericality: { only_integer: true, in: SCORE_RANGE },
            allow_nil: true)
  validates(*FEEDBACK_ATTRIBUTES, length: { maximum: 5_000 }, allow_nil: true)
  validates :suggested_translation, length: { maximum: 50_000 }, allow_nil: true
  validate :evaluation_fields_are_all_present_or_all_blank

  def complete?
    SCORE_ATTRIBUTES.all? { |attribute| public_send(attribute).present? } &&
      FEEDBACK_ATTRIBUTES.all? { |attribute| !public_send(attribute).nil? }
  end

  private

  def evaluation_fields_are_all_present_or_all_blank
    fields = SCORE_ATTRIBUTES + FEEDBACK_ATTRIBUTES + [ :suggested_translation ]
    return if fields.all? { |attribute| public_send(attribute).nil? }
    return if complete?

    errors.add(:base, "Evaluation fields must be either complete or blank")
  end
end
