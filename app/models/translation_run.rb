class TranslationRun < ApplicationRecord
  TERMINAL_STATUSES = %w[completed failed].freeze

  belongs_to :experiment
  belongs_to :llm_model

  has_many :review_evaluations, dependent: :restrict_with_error

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

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end
end
