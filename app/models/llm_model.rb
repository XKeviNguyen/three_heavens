class LlmModel < ApplicationRecord
  PROVIDER_MAX_LENGTH = 100
  MODEL_IDENTIFIER_MAX_LENGTH = 255
  DISPLAY_NAME_MAX_LENGTH = 150
  MIN_CONTEXT_WINDOW_TOKENS = 1_024
  MAX_CONTEXT_WINDOW_TOKENS = 2_000_000
  MIN_OUTPUT_TOKENS = 256
  MAX_OUTPUT_TOKENS = 200_000
  OPENROUTER_IDENTIFIER_FORMAT = /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\/[a-zA-Z0-9][a-zA-Z0-9._:-]*\z/
  CREDENTIAL_LIKE_PATTERN = /(?:sk-(?:or-)?[a-zA-Z0-9_-]{12,}|(?:api[_-]?key|bearer|password|secret|token)[=:])/i

  has_many :translation_runs, dependent: :restrict_with_error
  has_many :review_runs,
           foreign_key: :reviewer_llm_model_id,
           inverse_of: :reviewer_llm_model,
           dependent: :restrict_with_error
  has_many :judge_runs,
           foreign_key: :judge_llm_model_id,
           inverse_of: :judge_llm_model,
           dependent: :restrict_with_error
  has_many :finalization_runs,
           foreign_key: :finalizer_llm_model_id,
           inverse_of: :finalizer_llm_model,
           dependent: :restrict_with_error
  has_many :workflow_profile_model_selections, dependent: :restrict_with_error

  scope :active_openrouter, -> { where(active: true, gateway: "openrouter") }

  before_validation :strip_catalog_metadata

  validates :gateway, presence: true
  validates :provider,
            presence: true,
            length: { maximum: PROVIDER_MAX_LENGTH }
  validates :model_identifier,
            presence: true,
            length: { maximum: MODEL_IDENTIFIER_MAX_LENGTH },
            uniqueness: { scope: :gateway }
  validates :display_name,
            presence: true,
            length: { maximum: DISPLAY_NAME_MAX_LENGTH }
  validates :context_window_tokens,
            numericality: {
              only_integer: true,
              in: MIN_CONTEXT_WINDOW_TOKENS..MAX_CONTEXT_WINDOW_TOKENS
            },
            allow_nil: true
  validates :max_output_tokens,
            numericality: {
              only_integer: true,
              in: MIN_OUTPUT_TOKENS..MAX_OUTPUT_TOKENS
            },
            allow_nil: true
  validate :output_budget_is_below_context_window
  validate :context_capabilities_are_complete
  validate :openrouter_identifier_is_safe
  validate :model_identifier_is_immutable_after_historical_usage, on: :update

  def historical_usage?
    translation_runs.exists? || review_runs.exists? || judge_runs.exists? || finalization_runs.exists?
  end

  private

  def strip_catalog_metadata
    self.provider = provider.strip if provider.respond_to?(:strip)
    self.model_identifier = model_identifier.strip if model_identifier.respond_to?(:strip)
    self.display_name = display_name.strip if display_name.respond_to?(:strip)
  end

  def openrouter_identifier_is_safe
    return unless gateway == "openrouter" && model_identifier.present?

    unless model_identifier.match?(OPENROUTER_IDENTIFIER_FORMAT)
      errors.add(:model_identifier, "must be an OpenRouter identifier such as provider/model")
    end
    if model_identifier.match?(CREDENTIAL_LIKE_PATTERN)
      errors.add(:model_identifier, "must not contain credentials")
    end
  end

  def model_identifier_is_immutable_after_historical_usage
    return unless will_save_change_to_model_identifier? && historical_usage?

    errors.add(:model_identifier, "cannot be changed after the model has historical usage")
  end

  def output_budget_is_below_context_window
    return unless context_window_tokens && max_output_tokens
    return if max_output_tokens < context_window_tokens

    errors.add(:max_output_tokens, "must be smaller than the context window")
  end

  def context_capabilities_are_complete
    return if context_window_tokens.nil? == max_output_tokens.nil?

    errors.add(:base, "Context window and maximum output tokens must be configured together")
  end
end
