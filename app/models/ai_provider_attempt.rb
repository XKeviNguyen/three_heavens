class AiProviderAttempt < ApplicationRecord
  RUN_TYPES = %w[
    TranslationRun
    TranslationSegmentRun
    ReviewRun
    ReviewSegmentRun
    JudgeRun
    JudgeSegmentRun
    FinalizationRun
    FinalizationSegmentRun
  ].freeze
  STAGES = %w[translation review judge finalization].freeze
  RUN_STAGES = {
    "TranslationRun" => "translation", "TranslationSegmentRun" => "translation",
    "ReviewRun" => "review", "ReviewSegmentRun" => "review",
    "JudgeRun" => "judge", "JudgeSegmentRun" => "judge",
    "FinalizationRun" => "finalization", "FinalizationSegmentRun" => "finalization"
  }.freeze
  STATUSES = %w[running completed failed].freeze
  TOKEN_FIELDS = %i[prompt_tokens completion_tokens total_tokens cached_tokens reasoning_tokens].freeze

  belongs_to :provider_run, polymorphic: true

  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :provider_run_type, inclusion: { in: RUN_TYPES }
  validates :attempt_number,
            numericality: { only_integer: true, greater_than: 0 },
            uniqueness: { scope: %i[provider_run_type provider_run_id] }
  validates :stage, inclusion: { in: STAGES }
  validates :gateway_snapshot, presence: true, length: { maximum: 50 }
  validates :provider_snapshot, presence: true, length: { maximum: 100 }
  validates :model_identifier_snapshot, presence: true, length: { maximum: 255 }
  validates :display_name_snapshot, presence: true, length: { maximum: 150 }
  validates :started_at, presence: true
  validates :error_code, length: { maximum: 80 }, format: { with: /\A[a-z0-9_.:-]+\z/ }, allow_nil: true
  validates(*TOKEN_FIELDS, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true)
  validates :cost, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :lifecycle_is_consistent
  validate :stage_matches_provider_run
  validate :token_components_fit_total

  before_update :prevent_terminal_mutation
  before_destroy :prevent_destruction

  def terminal?
    completed? || failed?
  end

  private

  def lifecycle_is_consistent
    valid = if running?
      completed_at.nil? && error_code.nil?
    elsif completed?
      completed_at.present? && error_code.nil?
    else
      completed_at.present? && error_code.present?
    end
    errors.add(:status, "must match completion and failure details") unless valid
    errors.add(:completed_at, "must not precede the start") if completed_at && started_at && completed_at < started_at
  end

  def stage_matches_provider_run
    return if stage == RUN_STAGES[provider_run_type]

    errors.add(:stage, "must match the provider run type")
  end

  def token_components_fit_total
    return if total_tokens.nil?

    TOKEN_FIELDS.excluding(:total_tokens).each do |field|
      value = public_send(field)
      errors.add(field, "cannot exceed total tokens") if value && value > total_tokens
    end
  end

  def prevent_terminal_mutation
    return unless status_in_database.in?(%w[completed failed])

    errors.add(:base, "Historical provider attempts are immutable")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Historical provider attempts cannot be deleted")
    throw :abort
  end
end
