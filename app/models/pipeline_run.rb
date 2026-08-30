class PipelineRun < ApplicationRecord
  STATUSES = %w[running blocked ready_for_editor stopped].freeze
  STAGES = %w[translation review judge finalization editor].freeze

  belongs_to :experiment
  belongs_to :workflow_profile_revision
  belongs_to :finalization_round, optional: true
  has_many :events,
           -> { order(:sequence_number) },
           class_name: "PipelineEvent",
           dependent: :restrict_with_error,
           inverse_of: :pipeline_run

  enum :status, STATUSES.index_with(&:itself), validate: true
  enum :current_stage, STAGES.index_with(&:itself), prefix: true, validate: true

  validates :experiment_id, uniqueness: true
  validates :completion_mode, inclusion: { in: WorkflowProfileRevision::COMPLETION_MODES }
  validates :configuration_digest, presence: true, length: { is: 64 }
  validates :translator_count, inclusion: { in: 2..Ai::UsageLimits::MAX_TRANSLATION_MODELS }
  validates :reviewer_count, inclusion: { in: 1..Ai::UsageLimits::MAX_REVIEWERS }
  validates :judge_count, inclusion: { in: 1..Ai::UsageLimits::MAX_JUDGES }
  validates :finalizer_count, inclusion: { in: 0..Ai::UsageLimits::MAX_FINALIZERS }
  validates :authorized_initial_provider_run_count, numericality: { only_integer: true, greater_than: 0 }
  validates :confirmed_at, :started_at, presence: true
  validates :blocked_message, length: { maximum: 500 }, allow_nil: true
  validates :blocked_reason_code, length: { maximum: 80 }, allow_nil: true
  validate :provider_work_plan_is_bounded_object
  validate :authorization_counts_match
  validate :terminal_timestamps_match

  scope :reconcilable, -> { where(status: %w[running blocked]) }

  delegate :workflow_profile, to: :workflow_profile_revision

  def append_event!(event_key:, event_type:, from_stage: nil, to_stage: nil, reason_code: nil, metadata: {})
    with_lock do
      events.find_by(event_key: event_key) || events.create!(
        sequence_number: events.maximum(:sequence_number).to_i + 1,
        event_key: event_key,
        event_type: event_type,
        from_stage: from_stage,
        to_stage: to_stage,
        reason_code: reason_code,
        metadata: metadata
      )
    end
  end

  private

  def authorization_counts_match
    expected = if provider_work_plan.present?
      provider_work_plan["authorized_initial_provider_request_slots"]
    else
      translator_count.to_i + reviewer_count.to_i + judge_count.to_i + finalizer_count.to_i
    end
    unless authorized_initial_provider_run_count == expected
      errors.add(:authorized_initial_provider_run_count, "must equal all configured initial provider run slots")
    end
    if completion_mode == "winner_draft" && finalizer_count.to_i.positive?
      errors.add(:finalizer_count, "must be zero in winner draft mode")
    elsif completion_mode == "refinement_proposals" && finalizer_count.to_i.zero?
      errors.add(:finalizer_count, "must be positive in refinement proposals mode")
    end
  end

  def terminal_timestamps_match
    errors.add(:ready_for_editor_at, "must match ready status") unless ready_for_editor? == ready_for_editor_at.present?
    errors.add(:stopped_at, "must match stopped status") unless stopped? == stopped_at.present?
    if blocked? != (blocked_stage.present? && blocked_reason_code.present?)
      errors.add(:blocked_stage, "and reason must match blocked status")
    end
  end

  def provider_work_plan_is_bounded_object
    errors.add(:provider_work_plan, "must be an object") unless provider_work_plan.is_a?(Hash)
    errors.add(:provider_work_plan, "is too large") if provider_work_plan.to_json.bytesize > 16_384
  end
end
