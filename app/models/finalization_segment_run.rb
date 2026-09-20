class FinalizationSegmentRun < ApplicationRecord
  include Ai::ProviderRun

  MAX_OUTPUT_CHARACTERS = 20_000

  belongs_to :finalization_run
  belongs_to :experiment_segment

  validates :experiment_segment_id, uniqueness: { scope: :finalization_run_id }
  validates :proposed_translation, length: { maximum: MAX_OUTPUT_CHARACTERS }, allow_nil: true
  validate :lists_are_bounded
  validate :segment_belongs_to_finalized_experiment

  private

  def lists_are_bounded
    %i[change_summary terminology_notes warnings].each do |attribute|
      value = public_send(attribute)
      errors.add(attribute, "must be an array") unless value.is_a?(Array)
      errors.add(attribute, "is too large") if value.to_json.bytesize > 50_000
    end
  end

  def segment_belongs_to_finalized_experiment
    experiment_id = finalization_run&.finalization_round&.final_translation&.experiment_id
    return if experiment_segment&.document_execution_plan&.experiment_id == experiment_id

    errors.add(:experiment_segment, "must belong to the finalized experiment plan")
  end
end
