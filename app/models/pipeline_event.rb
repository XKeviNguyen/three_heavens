class PipelineEvent < ApplicationRecord
  MAX_METADATA_BYTES = 2_048

  belongs_to :pipeline_run, inverse_of: :events

  validates :sequence_number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :pipeline_run_id }
  validates :event_key, presence: true, length: { maximum: 120 }, uniqueness: { scope: :pipeline_run_id }
  validates :event_type, presence: true, length: { maximum: 80 }
  validates :from_stage, :to_stage, inclusion: { in: PipelineRun::STAGES }, allow_nil: true
  validates :reason_code, length: { maximum: 80 }, allow_nil: true
  validate :metadata_is_small_object

  before_update :prevent_mutation
  before_destroy :prevent_destruction

  private

  def metadata_is_small_object
    unless metadata.is_a?(Hash)
      errors.add(:metadata, "must be an object")
      return
    end
    errors.add(:metadata, "is too large") if metadata.to_json.bytesize > MAX_METADATA_BYTES
  end

  def prevent_mutation
    errors.add(:base, "Pipeline events are append-only")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Pipeline events are append-only")
    throw :abort
  end
end
