class FinalizationRun < ApplicationRecord
  include Ai::BudgetSnapshot
  include Ai::ProviderAttemptTracking

  TERMINAL_STATUSES = %w[completed failed].freeze
  LIST_ATTRIBUTES = %i[change_summary terminology_notes warnings].freeze

  belongs_to :finalization_round
  belongs_to :finalizer_llm_model, class_name: "LlmModel"

  has_many :finalization_segment_runs,
           -> { joins(:experiment_segment).order("experiment_segments.position") },
           dependent: :restrict_with_error

  has_many :applied_versions,
           class_name: "FinalTranslationVersion",
           foreign_key: :source_finalization_run_id,
           inverse_of: :source_finalization_run,
           dependent: :restrict_with_error

  enum :status, {
    pending: "pending",
    running: "running",
    completed: "completed",
    failed: "failed"
  }, validate: true

  validates :finalizer_llm_model_id, uniqueness: { scope: :finalization_round_id }
  validates :proposed_translation,
            length: { maximum: FinalTranslationVersion::MAX_CONTENT_LENGTH },
            allow_nil: true
  validates :prompt_tokens,
            :completion_tokens,
            :total_tokens,
            :cached_tokens,
            :reasoning_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true
  validates :cost, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :list_attributes_are_arrays
  validate :completed_run_has_valid_proposal
  validate :finalizer_is_openrouter

  before_destroy :prevent_destruction

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def segmented?
    finalization_segment_runs.exists?
  end

  private

  def list_attributes_are_arrays
    LIST_ATTRIBUTES.each do |attribute|
      value = public_send(attribute)
      errors.add(attribute, "must be an array") unless value.is_a?(Array)
    end
  end

  def completed_run_has_valid_proposal
    return unless completed?

    errors.add(:proposed_translation, "must be present") if proposed_translation.blank?
    LIST_ATTRIBUTES.each do |attribute|
      value = public_send(attribute)
      next unless value.is_a?(Array)

      unless value.all? { |item| item.is_a?(String) }
        errors.add(attribute, "must contain strings only")
      end
    end
  end

  def finalizer_is_openrouter
    return if finalizer_llm_model&.gateway == "openrouter"

    errors.add(:finalizer_llm_model, "must be an OpenRouter model")
  end

  def prevent_destruction
    errors.add(:base, "Historical finalization runs cannot be deleted")
    throw :abort
  end
end
