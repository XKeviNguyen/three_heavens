class WorkflowProfileRevision < ApplicationRecord
  COMPLETION_MODES = %w[winner_draft refinement_proposals].freeze

  belongs_to :workflow_profile, inverse_of: :revisions
  has_one :current_for_profile,
          class_name: "WorkflowProfile",
          foreign_key: :current_revision_id,
          dependent: :restrict_with_error,
          inverse_of: :current_revision
  has_many :model_selections,
           -> { order(:role, :position) },
           class_name: "WorkflowProfileModelSelection",
           dependent: :restrict_with_error,
           inverse_of: :workflow_profile_revision
  has_many :pipeline_runs, dependent: :restrict_with_error

  enum :completion_mode,
       { winner_draft: "winner_draft", refinement_proposals: "refinement_proposals" },
       validate: true

  validates :version, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :workflow_profile_id }
  validates :name, presence: true, length: { maximum: 150 }
  validates :description, length: { maximum: 500 }, allow_blank: true
  validates :configuration_digest, presence: true, length: { is: 64 }
  validates_associated :model_selections
  validate :valid_role_counts

  before_validation :normalize_snapshots
  before_validation :assign_configuration_digest
  before_update :prevent_mutation
  before_destroy :prevent_destruction

  def selections_for(role)
    model_selections.select { |selection| selection.role == role.to_s }.sort_by(&:position)
  end

  def role_count(role)
    selections_for(role).size
  end

  def authorized_initial_provider_run_count
    model_selections.size
  end

  def routing_eligible?(role: nil)
    selected = role ? selections_for(role) : model_selections
    selected.all?(&:routing_identity_available?)
  end

  private

  ROLE_LIMITS = {
    "translator" => (2..Ai::UsageLimits::MAX_TRANSLATION_MODELS),
    "reviewer" => (1..Ai::UsageLimits::MAX_REVIEWERS),
    "judge" => (1..Ai::UsageLimits::MAX_JUDGES)
  }.freeze

  def normalize_snapshots
    self.name = name.to_s.strip
    self.description = description.to_s.strip.presence
  end

  def assign_configuration_digest
    return if model_selections.empty?

    self.configuration_digest = WorkflowProfiles::ConfigurationDigest.call(self)
  end

  def valid_role_counts
    ROLE_LIMITS.each do |role, allowed|
      count = role_count(role)
      errors.add(:model_selections, "must include #{allowed.min}-#{allowed.max} #{role} models") unless allowed.cover?(count)
    end

    finalizer_count = role_count("finalizer")
    if winner_draft? && finalizer_count.positive?
      errors.add(:model_selections, "cannot include finalizers in winner draft mode")
    elsif refinement_proposals? && !(1..Ai::UsageLimits::MAX_FINALIZERS).cover?(finalizer_count)
      errors.add(:model_selections, "must include 1-#{Ai::UsageLimits::MAX_FINALIZERS} finalizer models")
    end
  end

  def prevent_mutation
    errors.add(:base, "Workflow profile revisions are immutable")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Workflow profile revisions cannot be deleted")
    throw :abort
  end
end
