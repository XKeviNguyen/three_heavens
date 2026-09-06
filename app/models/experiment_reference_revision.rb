class ExperimentReferenceRevision < ApplicationRecord
  MAXIMUM_REFERENCES = 5

  belongs_to :experiment
  belongs_to :translation_reference_revision

  validates :position,
            numericality: {
              only_integer: true,
              greater_than: 0,
              less_than_or_equal_to: MAXIMUM_REFERENCES
            },
            uniqueness: { scope: :experiment_id }
  validates :translation_reference_revision_id, uniqueness: { scope: :experiment_id }
  validate :revision_is_launch_eligible, on: :create
  validate :selected_before_provider_work, on: :create

  before_update :prevent_mutation
  before_destroy :prevent_destruction

  private

  def revision_is_launch_eligible
    revision = translation_reference_revision
    project = experiment&.document&.project
    return unless revision && project

    reference = revision.translation_reference
    eligible = reference.user_id == project.user_id &&
      reference.active? &&
      reference.current_revision_id == revision.id &&
      revision.language_pair_matches?(
        source_language: project.source_language,
        target_language: project.target_language
      )
    errors.add(:translation_reference_revision, "is not available for this experiment") unless eligible
  end

  def selected_before_provider_work
    return unless experiment&.translation_runs&.exists?

    errors.add(:experiment, "reference snapshots must be selected before provider work starts")
  end

  def prevent_mutation
    errors.add(:base, "Experiment reference snapshots are immutable")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Experiment reference snapshots cannot be deleted")
    throw :abort
  end
end
