class TranslationSegmentRun < ApplicationRecord
  include Ai::ProviderRun

  MAX_OUTPUT_CHARACTERS = 20_000

  belongs_to :translation_run
  belongs_to :experiment_segment

  validates :experiment_segment_id, uniqueness: { scope: :translation_run_id }
  validates :translated_text, length: { maximum: MAX_OUTPUT_CHARACTERS }, allow_nil: true
  validate :segment_belongs_to_translation_experiment

  private

  def segment_belongs_to_translation_experiment
    return if experiment_segment&.document_execution_plan&.experiment_id == translation_run&.experiment_id

    errors.add(:experiment_segment, "must belong to the translation experiment plan")
  end
end
