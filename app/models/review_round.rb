class ReviewRound < ApplicationRecord
  TERMINAL_STATUSES = %w[completed failed].freeze

  belongs_to :experiment

  # The reviewers that count: a failed reviewer replaced by another model
  # (BlindReviews::ReplaceFailed) stays in all_review_runs with its own attempts
  # and cost, but no longer decides the round's status or feeds judging.
  has_many :review_runs, -> { where(superseded_at: nil) }, dependent: :restrict_with_error
  has_many :all_review_runs, class_name: "ReviewRun", dependent: :restrict_with_error
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
