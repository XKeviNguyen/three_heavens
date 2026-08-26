class JudgeRound < ApplicationRecord
  TERMINAL_STATUSES = %w[completed failed].freeze

  belongs_to :review_round
  belongs_to :winner_translation_run, class_name: "TranslationRun", optional: true

  has_many :judge_runs, dependent: :restrict_with_error

  enum :status, {
    pending: "pending",
    running: "running",
    completed: "completed",
    failed: "failed"
  }, validate: true

  validates :review_round_id, uniqueness: true
  validate :aggregate_rankings_is_an_array
  validates :aggregation_explanation, length: { maximum: 10_000 }, allow_nil: true
  validate :terminal_status_matches_judge_runs
  validate :winner_belongs_to_experiment
  validate :winner_is_a_ranked_candidate
  validate :winner_matches_completed_status

  def experiment
    review_round.experiment
  end

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  private

  def aggregate_rankings_is_an_array
    errors.add(:aggregate_rankings, "must be an array") unless aggregate_rankings.is_a?(Array)
  end

  def terminal_status_matches_judge_runs
    return unless terminal?

    runs = judge_runs.to_a
    unless runs.any? && runs.all?(&:terminal?)
      errors.add(:judge_runs, "must all be terminal")
      return
    end

    if completed? && runs.any?(&:failed?)
      errors.add(:status, "cannot be completed when a judge failed")
    elsif failed? && runs.none?(&:failed?)
      errors.add(:status, "must reflect a failed judge")
    end
  end

  def winner_belongs_to_experiment
    return unless winner_translation_run
    return if winner_translation_run.experiment_id == review_round&.experiment_id

    errors.add(:winner_translation_run, "must belong to the judged experiment")
  end

  def winner_is_a_ranked_candidate
    return unless completed? && winner_translation_run_id

    ranked_candidate_ids = judge_runs.flat_map do |judge_run|
      judge_run.judge_evaluations.map(&:translation_run_id)
    end.uniq
    return if ranked_candidate_ids.include?(winner_translation_run_id)

    errors.add(:winner_translation_run, "must be a ranked candidate")
  end

  def winner_matches_completed_status
    if completed? && winner_translation_run.nil?
      errors.add(:winner_translation_run, "must be present for a completed round")
    elsif !completed? && winner_translation_run.present?
      errors.add(:winner_translation_run, "is only allowed for a completed round")
    end
  end
end
