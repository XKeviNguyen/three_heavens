class JudgeRun < ApplicationRecord
  TERMINAL_STATUSES = %w[completed failed].freeze

  belongs_to :judge_round
  belongs_to :judge_llm_model, class_name: "LlmModel"
  belongs_to :winner_translation_run, class_name: "TranslationRun", optional: true

  has_many :judge_evaluations, dependent: :restrict_with_error

  enum :status, {
    pending: "pending",
    running: "running",
    completed: "completed",
    failed: "failed"
  }, validate: true

  validates :judge_llm_model_id, uniqueness: { scope: :judge_round_id }
  validates :judge_llm_model, presence: true
  validates :confidence_score,
            numericality: { only_integer: true, in: 1..100 },
            allow_nil: true
  validates :winner_rationale, length: { maximum: 5_000 }, allow_nil: true
  validates :prompt_tokens,
            :completion_tokens,
            :total_tokens,
            :cached_tokens,
            :reasoning_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true
  validates :cost, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :judge_is_active_openrouter, on: :create
  validate :completed_run_has_complete_ranking

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  private

  def judge_is_active_openrouter
    return if judge_llm_model&.active? && judge_llm_model.gateway == "openrouter"

    errors.add(:judge_llm_model, "must be an active OpenRouter model")
  end

  def completed_run_has_complete_ranking
    return unless completed?

    evaluations = judge_evaluations.reload.to_a
    expected_ranks = (1..evaluations.size).to_a
    complete = evaluations.any? && evaluations.all?(&:complete?) &&
      evaluations.map(&:rank).sort == expected_ranks
    unless complete
      errors.add(:judge_evaluations, "must contain one complete ranking")
      return
    end

    rank_one = evaluations.find { |evaluation| evaluation.rank == 1 }
    unless winner_translation_run_id == rank_one&.translation_run_id
      errors.add(:winner_translation_run, "must be the candidate ranked first")
    end
    errors.add(:winner_rationale, "must be present") if winner_rationale.blank?
    errors.add(:confidence_score, "must be present") if confidence_score.nil?
  end
end
