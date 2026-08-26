class ReviewRound < ApplicationRecord
  TERMINAL_STATUSES = %w[completed failed].freeze

  belongs_to :experiment

  has_many :review_runs, dependent: :restrict_with_error
  has_one :judge_round, dependent: :restrict_with_error

  enum :status, {
    pending: "pending",
    running: "running",
    completed: "completed",
    failed: "failed"
  }, validate: true

  validates :experiment_id, uniqueness: true
  validate :terminal_status_matches_review_runs

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  private

  def terminal_status_matches_review_runs
    return unless terminal?

    runs = review_runs.to_a
    unless runs.any? && runs.all?(&:terminal?)
      errors.add(:review_runs, "must all be terminal")
      return
    end

    if completed? && runs.any?(&:failed?)
      errors.add(:status, "cannot be completed when a reviewer failed")
    elsif failed? && runs.none?(&:failed?)
      errors.add(:status, "must reflect a failed reviewer")
    end
  end
end
