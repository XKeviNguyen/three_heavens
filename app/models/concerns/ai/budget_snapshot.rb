module Ai
  module BudgetSnapshot
    extend ActiveSupport::Concern

    ATTRIBUTES = %i[
      context_window_tokens_snapshot
      max_output_tokens_snapshot
      estimated_input_tokens
      reserved_output_tokens
      context_safety_margin_tokens
      budget_policy_version
    ].freeze

    included do
      validate :budget_snapshot_is_complete_and_safe
    end

    private

    def budget_snapshot_is_complete_and_safe
      values = ATTRIBUTES.map { |attribute| public_send(attribute) }
      return if values.all?(&:nil?)

      unless values.none?(&:nil?)
        errors.add(:base, "Context budget snapshot must be either complete or absent")
        return
      end

      unless budget_policy_version.to_s.length.between?(1, 100)
        errors.add(:budget_policy_version, "must contain 1 to 100 characters")
      end
      return unless values.first(5).all? { |value| value.is_a?(Numeric) }

      unless context_window_tokens_snapshot.between?(1_024, 2_000_000)
        errors.add(:context_window_tokens_snapshot, "is outside the supported range")
      end
      unless max_output_tokens_snapshot.between?(256, 200_000)
        errors.add(:max_output_tokens_snapshot, "is outside the supported range")
      end
      errors.add(:estimated_input_tokens, "must not be negative") if estimated_input_tokens.negative?
      errors.add(:reserved_output_tokens, "must be positive") unless reserved_output_tokens.positive?
      errors.add(:context_safety_margin_tokens, "must be positive") unless context_safety_margin_tokens.positive?

      if reserved_output_tokens > max_output_tokens_snapshot
        errors.add(:reserved_output_tokens, "must not exceed the model output capability")
      end
      if estimated_input_tokens + reserved_output_tokens + context_safety_margin_tokens > context_window_tokens_snapshot
        errors.add(:base, "Context budget snapshot exceeds the context window")
      end
    end
  end
end
