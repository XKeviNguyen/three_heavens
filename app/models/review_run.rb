class ReviewRun < ApplicationRecord
  include Ai::BudgetSnapshot
  include Ai::ProviderAttemptTracking

  TERMINAL_STATUSES = %w[completed failed].freeze

  belongs_to :review_round
  belongs_to :reviewer_llm_model, class_name: "LlmModel"

  has_many :review_evaluations, dependent: :restrict_with_error
  has_many :review_segment_runs,
           -> { joins(:experiment_segment).order("experiment_segments.position") },
           dependent: :restrict_with_error

  enum :status, {
    pending: "pending",
    running: "running",
    completed: "completed",
    failed: "failed"
  }, validate: true

  validates :reviewer_llm_model_id, uniqueness: { scope: :review_round_id }
  validates :prompt_tokens,
            :completion_tokens,
            :total_tokens,
            :cached_tokens,
            :reasoning_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true
  validates :cost, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :completed_run_has_complete_evaluations

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def segmented?
    review_segment_runs.exists?
  end

  private

  def completed_run_has_complete_evaluations
    return unless completed?

    evaluations = review_evaluations.to_a
    return if evaluations.any? && evaluations.all?(&:complete?)

    errors.add(:review_evaluations, "must all be complete")
  end
end
