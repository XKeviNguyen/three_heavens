class TranslationRun < ApplicationRecord
  include Ai::BudgetSnapshot
  include Ai::ProviderAttemptTracking

  TERMINAL_STATUSES = %w[completed failed].freeze

  belongs_to :experiment
  belongs_to :llm_model

  has_many :translation_segment_runs,
           -> { joins(:experiment_segment).order("experiment_segments.position") },
           dependent: :restrict_with_error

  has_many :review_evaluations, dependent: :restrict_with_error
  has_many :judge_evaluations, dependent: :restrict_with_error
  has_many :winning_judge_runs,
           class_name: "JudgeRun",
           foreign_key: :winner_translation_run_id,
           inverse_of: :winner_translation_run,
           dependent: :restrict_with_error
  has_many :winning_judge_rounds,
           class_name: "JudgeRound",
           foreign_key: :winner_translation_run_id,
           inverse_of: :winner_translation_run,
           dependent: :restrict_with_error
  has_many :seeded_final_translations,
           class_name: "FinalTranslation",
           foreign_key: :source_winner_translation_run_id,
           inverse_of: :source_winner_translation_run,
           dependent: :restrict_with_error

  enum :status, {
    pending: "pending",
    running: "running",
    completed: "completed",
    failed: "failed"
  }, validate: true

  validates :llm_model_id, uniqueness: { scope: :experiment_id }
  validates :prompt_tokens,
            :completion_tokens,
            :total_tokens,
            :cached_tokens,
            :reasoning_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true
  validates :cost,
            numericality: { greater_than_or_equal_to: 0 },
            allow_nil: true
  validates :translated_text,
            length: { maximum: Ai::UsageLimits::MAX_SOURCE_CHARACTERS },
            allow_nil: true

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def segmented?
    translation_segment_runs.exists?
  end
end
