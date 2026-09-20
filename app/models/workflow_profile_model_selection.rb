class WorkflowProfileModelSelection < ApplicationRecord
  ROLES = %w[translator reviewer judge finalizer].freeze

  belongs_to :workflow_profile_revision, inverse_of: :model_selections
  belongs_to :llm_model

  enum :role, ROLES.index_with(&:itself), validate: true

  validates :position,
            numericality: { only_integer: true, greater_than: 0 },
            uniqueness: { scope: [ :workflow_profile_revision_id, :role ] }
  validates :llm_model_id, uniqueness: { scope: [ :workflow_profile_revision_id, :role ] }
  validates :gateway_snapshot, presence: true, length: { maximum: 50 }
  validates :provider_snapshot, presence: true, length: { maximum: 100 }
  validates :model_identifier_snapshot, presence: true, length: { maximum: 255 }
  validates :display_name_snapshot, presence: true, length: { maximum: 150 }

  before_update :prevent_mutation
  before_destroy :prevent_destruction

  def routing_identity_available?
    llm_model&.active? &&
      llm_model.gateway == "openrouter" &&
      llm_model.gateway == gateway_snapshot &&
      llm_model.provider == provider_snapshot &&
      llm_model.model_identifier == model_identifier_snapshot
  end

  private

  def prevent_mutation
    errors.add(:base, "Workflow profile model selections are immutable")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Workflow profile model selections cannot be deleted")
    throw :abort
  end
end
