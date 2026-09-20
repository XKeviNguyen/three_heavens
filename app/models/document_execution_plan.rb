class DocumentExecutionPlan < ApplicationRecord
  belongs_to :experiment
  has_many :segments,
           -> { order(:position) },
           class_name: "ExperimentSegment",
           dependent: :restrict_with_error,
           inverse_of: :document_execution_plan

  validates :experiment_id, uniqueness: true
  validates :segmentation_version, :budget_policy_version, presence: true, length: { maximum: 100 }
  validates :source_sha256, format: { with: /\A\h{64}\z/ }
  validates :segment_count, numericality: { only_integer: true, greater_than: 1 }
  validates :segment_target_characters, numericality: { only_integer: true, in: 256..20_000 }

  before_update :prevent_mutation
  before_destroy :prevent_destruction

  def reconstruct_source
    segments.order(:position).pluck(:source_text).join
  end

  private

  def prevent_mutation
    errors.add(:base, "Document execution plans are immutable")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Document execution plans cannot be deleted")
    throw :abort
  end
end
