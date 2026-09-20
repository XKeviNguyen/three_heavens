module Ai
  module ProviderAttemptTracking
    extend ActiveSupport::Concern

    included do
      has_many :provider_attempts,
               as: :provider_run,
               class_name: "AiProviderAttempt",
               dependent: :restrict_with_error

      after_update :sync_terminal_provider_attempt,
                   if: -> { saved_change_to_status? && terminal? && execution_attempt.to_i.positive? }
    end

    private

    def sync_terminal_provider_attempt
      Ai::ProviderAttempts.sync_terminal!(self)
    end
  end
end
