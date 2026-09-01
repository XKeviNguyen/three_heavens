class Experiment < ApplicationRecord
  belongs_to :document
  belongs_to :glossary_revision, optional: true
  belongs_to :methodology_profile_revision, optional: true

  has_many :translation_runs, dependent: :restrict_with_error
  has_one :document_execution_plan, dependent: :restrict_with_error
  has_one :review_round, dependent: :restrict_with_error
  has_one :judge_round, through: :review_round
  has_one :final_translation, dependent: :restrict_with_error
  has_one :pipeline_run, dependent: :restrict_with_error
  has_one :translation_workspace_submission, dependent: :restrict_with_error

  enum :status, {
    pending: "pending",
    running: "running",
    completed: "completed",
    failed: "failed"
  }, validate: true

  validates :name, length: { maximum: 150 }, allow_blank: true
  validates :instruction_prompt,
            presence: true,
            length: { maximum: Ai::UsageLimits::MAX_INSTRUCTION_CHARACTERS }
  validate :glossary_revision_matches_project_language_pair
  validate :glossary_revision_belongs_to_project_owner
  validate :glossary_revision_is_immutable, on: :update
  validate :methodology_revision_matches_project_language_pair
  validate :methodology_revision_belongs_to_project_owner
  validate :methodology_revision_is_immutable, on: :update

  private

  def glossary_revision_matches_project_language_pair
    return unless glossary_revision && document&.project
    return if glossary_revision.language_pair_matches?(source_language: document.project.source_language, target_language: document.project.target_language)

    errors.add(:glossary_revision, "must match the project's source and target languages")
  end

  def glossary_revision_belongs_to_project_owner
    return unless glossary_revision && document&.project
    return if glossary_revision.glossary.user_id == document.project.user_id

    errors.add(:glossary_revision, "is not available for this experiment")
  end

  def glossary_revision_is_immutable
    return unless will_save_change_to_glossary_revision_id?

    errors.add(:glossary_revision, "cannot change after experiment creation")
  end

  def methodology_revision_matches_project_language_pair
    return unless methodology_profile_revision && document&.project
    return if methodology_profile_revision.language_pair_matches?(
      source_language: document.project.source_language,
      target_language: document.project.target_language
    )

    errors.add(:methodology_profile_revision, "must match the project's source and target languages")
  end

  def methodology_revision_belongs_to_project_owner
    return unless methodology_profile_revision && document&.project
    return if methodology_profile_revision.methodology_profile.user_id == document.project.user_id

    errors.add(:methodology_profile_revision, "is not available for this experiment")
  end

  def methodology_revision_is_immutable
    return unless will_save_change_to_methodology_profile_revision_id?

    errors.add(:methodology_profile_revision, "cannot change after experiment creation")
  end
end
