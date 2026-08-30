require "digest"

class ExperimentSegment < ApplicationRecord
  belongs_to :document_execution_plan, inverse_of: :segments

  has_many :translation_segment_runs, dependent: :restrict_with_error
  has_many :review_segment_runs, dependent: :restrict_with_error
  has_many :judge_segment_runs, dependent: :restrict_with_error
  has_many :finalization_segment_runs, dependent: :restrict_with_error

  validates :position,
            numericality: { only_integer: true, greater_than: 0 },
            uniqueness: { scope: :document_execution_plan_id }
  validates :source_text, presence: true
  validates :source_character_count, numericality: { only_integer: true, greater_than: 0 }
  validates :source_sha256, format: { with: /\A\h{64}\z/ }
  validate :source_metadata_matches

  before_update :prevent_mutation
  before_destroy :prevent_destruction

  private

  def source_metadata_matches
    errors.add(:source_character_count, "must match source text") unless source_character_count == source_text.to_s.length
    errors.add(:source_sha256, "must match source text") unless source_sha256 == Digest::SHA256.hexdigest(source_text.to_s)
  end

  def prevent_mutation
    errors.add(:base, "Experiment segments are immutable")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Experiment segments cannot be deleted")
    throw :abort
  end
end
