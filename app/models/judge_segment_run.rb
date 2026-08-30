class JudgeSegmentRun < ApplicationRecord
  include Ai::ProviderRun

  belongs_to :judge_run
  belongs_to :experiment_segment

  validates :experiment_segment_id, uniqueness: { scope: :judge_run_id }
  validate :judgment_is_bounded_object
  validate :segment_belongs_to_judged_experiment

  private

  def judgment_is_bounded_object
    errors.add(:judgment, "must be an object") unless judgment.is_a?(Hash)
    errors.add(:judgment, "is too large") if judgment.to_json.bytesize > 100_000
  end

  def segment_belongs_to_judged_experiment
    experiment_id = judge_run&.judge_round&.experiment&.id
    return if experiment_segment&.document_execution_plan&.experiment_id == experiment_id

    errors.add(:experiment_segment, "must belong to the judged experiment plan")
  end
end
