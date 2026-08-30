class FinalTranslationVersionSegment < ApplicationRecord
  belongs_to :final_translation_version
  belongs_to :experiment_segment

  validates :experiment_segment_id, uniqueness: { scope: :final_translation_version_id }
  validates :content, presence: true, length: { maximum: FinalizationSegmentRun::MAX_OUTPUT_CHARACTERS }
  validate :segment_belongs_to_version_experiment

  before_update :prevent_mutation
  before_destroy :prevent_destruction

  private

  def prevent_mutation
    errors.add(:base, "Final translation version segments are immutable")
    throw :abort
  end

  def segment_belongs_to_version_experiment
    experiment_id = final_translation_version&.final_translation&.experiment_id
    return if experiment_segment&.document_execution_plan&.experiment_id == experiment_id

    errors.add(:experiment_segment, "must belong to the final translation experiment plan")
  end

  def prevent_destruction
    errors.add(:base, "Final translation version segments cannot be deleted")
    throw :abort
  end
end
