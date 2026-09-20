module Ai
  module ProviderRun
    extend ActiveSupport::Concern

    TERMINAL_STATUSES = %w[completed failed].freeze

    included do
      include Ai::BudgetSnapshot
      include Ai::ProviderAttemptTracking

      enum :status, {
        pending: "pending",
        running: "running",
        completed: "completed",
        failed: "failed"
      }, validate: true

      validates :prompt_tokens,
                :completion_tokens,
                :total_tokens,
                :cached_tokens,
                :reasoning_tokens,
                numericality: { only_integer: true, greater_than_or_equal_to: 0 },
                allow_nil: true
      validates :cost, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
      validates :context_window_tokens_snapshot,
                numericality: { only_integer: true, in: 1_024..2_000_000 }
      validates :max_output_tokens_snapshot,
                numericality: { only_integer: true, in: 256..200_000 }
      validates :estimated_input_tokens,
                numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validates :reserved_output_tokens, :context_safety_margin_tokens,
                numericality: { only_integer: true, greater_than: 0 }
      validates :budget_policy_version, presence: true, length: { maximum: 100 }
      before_update :prevent_completed_mutation
    end

    def terminal?
      status.in?(TERMINAL_STATUSES)
    end

    private

    def prevent_completed_mutation
      return unless status_in_database == "completed"

      errors.add(:base, "Completed provider segment runs are immutable")
      throw :abort
    end
  end
end
