class ReviewSegmentRun < ApplicationRecord
  include Ai::ProviderRun

  belongs_to :review_run
  belongs_to :experiment_segment

  validates :experiment_segment_id, uniqueness: { scope: :review_run_id }
  validate :evaluations_are_bounded_array
  validate :segment_belongs_to_review_experiment

  private

  def evaluations_are_bounded_array
    errors.add(:evaluations, "must be an array") unless evaluations.is_a?(Array)
    errors.add(:evaluations, "is too large") if evaluations.to_json.bytesize > 100_000
  end

  def segment_belongs_to_review_experiment
    experiment_id = review_run&.review_round&.experiment_id
    return if experiment_segment&.document_execution_plan&.experiment_id == experiment_id

    errors.add(:experiment_segment, "must belong to the reviewed experiment plan")
  end
end
