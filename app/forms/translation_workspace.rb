class TranslationWorkspace
  include ActiveModel::Model

  attr_accessor :project_name,
                :user,
                :source_language,
                :target_language,
                :document_title,
                :source_text,
                :source_import,
                :source_import_id,
                :experiment_name,
                :instruction_prompt,
                :model_ids,
                :workflow_mode,
                :workflow_profile_revision_id,
                :automatic_confirmation,
                :automatic_plan_digest,
                :submission_token

  attr_reader :document, :experiment, :pipeline_run, :project, :provider_work_plan_preview

  validate :validate_workspace_records
  validate :validate_model_selection
  validate :validate_source_import

  def initialize(attributes = {}, start_service: TranslationExperiments::Start, clock: -> { Time.current })
    @start_service = start_service
    @clock = clock
    super(attributes)
    self.model_ids = [] if model_ids.nil?
    self.workflow_mode = "manual" if workflow_mode.blank?
    self.source_import_id ||= source_import&.id
    issue_submission_token if submission_token.blank? && user&.persisted?
  end

  def submit
    submission = TranslationWorkspaceSubmission.find_owned_by_token!(user: user, token: submission_token)
    submission.with_lock do
      next replay!(submission) if submission.consumed?
      if submission.expired?
        errors.add(:submission_token, "has expired. Reload the workspace and try again.")
        next false
      end
      next false unless valid?

      project.save!
      locked_import = lock_source_import
      if locked_import
        SourceImports::Consume.apply!(source_import: locked_import, document: document, at: current_time)
      end
      document.save!
      experiment.save!
      SourceImports::Consume.finish!(source_import: locked_import, document: document) if locked_import
      if automatic_mode?
        @pipeline_run = Pipelines::Start.call(
          experiment: experiment,
          user: user,
          workflow_profile_revision: @workflow_profile_revision,
          confirmation: automatic_confirmation,
          expected_provider_work_plan_digest: automatic_plan_digest
        )
      else
        @start_service.call(experiment: experiment, llm_models: @llm_models)
      end
      submission.update!(
        status: :consumed,
        consumed_at: Time.current,
        experiment: experiment
      )
      true
    end
  rescue ActiveRecord::RecordInvalid,
         TranslationExperiments::Start::Error,
         Pipelines::Start::Error,
         SourceImports::Error => error
    if error.is_a?(SourceImports::Error)
      errors.add(:source_import_id, error.message)
      return false
    end
    errors.add(:base, "The translation experiment could not be started. Please review the form and try again.")
    false
  end

  def replayed?
    @replayed == true
  end

  private

  RECORD_ATTRIBUTE_MAPPINGS = {
    project: {
      name: :project_name,
      source_language: :source_language,
      target_language: :target_language
    },
    document: {
      title: :document_title,
      source_text: :source_text
    },
    experiment: {
      name: :experiment_name,
      instruction_prompt: :instruction_prompt
    }
  }.freeze

  def build_workspace_records
    @project = Project.new(
      user: user,
      name: project_name,
      source_language: source_language,
      target_language: target_language
    )
    @document = @project.documents.build(
      title: document_title,
      source_text: source_text
    )
    @experiment = @document.experiments.build(
      name: experiment_name,
      instruction_prompt: instruction_prompt
    )
  end

  def validate_workspace_records
    build_workspace_records

    RECORD_ATTRIBUTE_MAPPINGS.each do |record_name, attribute_mapping|
      record = public_send(record_name)
      next if record.valid?

      record.errors.each do |error|
        form_attribute = attribute_mapping.fetch(error.attribute, :base)
        errors.add(form_attribute, error.message)
      end
    end
  end

  def validate_model_selection
    unless workflow_mode.in?(%w[manual automatic])
      errors.add(:workflow_mode, "must be manual or automatic")
      return
    end

    if automatic_mode?
      validate_automatic_selection
    else
      validate_manual_selection
    end
  end

  def validate_manual_selection
    if workflow_profile_revision_id.present? || automatic_confirmation == "1"
      errors.add(:workflow_mode, "cannot mix manual models with automatic pipeline settings")
      return
    end

    selected_ids = Ai::UsageLimits.normalize_model_ids(
      model_ids,
      maximum: Ai::UsageLimits::MAX_TRANSLATION_MODELS,
      label: "Translation models"
    )
    @llm_models = LlmModel.active_openrouter.where(id: selected_ids).order(:id).to_a

    return if @llm_models.map(&:id) == selected_ids.sort

    errors.add(:model_ids, "contain an inactive or unsupported model")
  rescue Ai::UsageLimits::InvalidSelection => error
    errors.add(:model_ids, error.message)
  end

  def validate_automatic_selection
    if model_ids.any?(&:present?)
      errors.add(:workflow_mode, "cannot mix automatic pipeline settings with manual model IDs")
      return
    end
    unless workflow_profile_revision_id.to_s.match?(/\A[1-9]\d*\z/)
      errors.add(:workflow_profile_revision_id, "is not a valid profile revision")
      return
    end

    @workflow_profile_revision = WorkflowProfileRevision.includes(
      :workflow_profile,
      model_selections: :llm_model
    ).joins(:workflow_profile).where(workflow_profiles: { user_id: user.id }).find_by(id: workflow_profile_revision_id)
    unless @workflow_profile_revision
      errors.add(:workflow_profile_revision_id, "is not available")
      return
    end
    profile = @workflow_profile_revision.workflow_profile
    errors.add(:workflow_profile_revision_id, "is stale; review the latest profile revision") unless profile.current_revision_id == @workflow_profile_revision.id
    errors.add(:workflow_profile_revision_id, "belongs to an inactive profile") unless profile.active?
    errors.add(:automatic_confirmation, "must be accepted for each launch") unless automatic_confirmation == Pipelines::Start::CONFIRMATION_VALUE
    unless @workflow_profile_revision.routing_eligible?
      errors.add(:workflow_profile_revision_id, "references unavailable or changed model routing")
    end
    validate_automatic_provider_plan
  end

  def validate_automatic_provider_plan
    return unless source_text.present? && @workflow_profile_revision&.routing_eligible?

    segment_count = if source_text.length > LongDocuments::Segmenter::TARGET_CHARACTERS
      LongDocuments::Segmenter.call(source_text).size
    else
      1
    end
    return if segment_count == 1

    role_models = WorkflowProfileModelSelection::ROLES.to_h do |role|
      [ role, @workflow_profile_revision.selections_for(role).map(&:llm_model) ]
    end
    preview = LongDocuments::ProviderWorkPlan.call(
      execution_plan: LongDocuments::ProviderWorkPlan::Preview.new(segment_count: segment_count),
      role_models: role_models,
      source_character_count: source_text.length
    )
    @provider_work_plan_preview = preview
    expected_digest = LongDocuments::ProviderWorkPlan.digest(preview)
    supplied = automatic_plan_digest.to_s
    return if supplied.length == expected_digest.length &&
              ActiveSupport::SecurityUtils.secure_compare(supplied, expected_digest)

    self.automatic_plan_digest = expected_digest
    self.automatic_confirmation = "0"
    errors.add(
      :automatic_confirmation,
      "must confirm the exact segmented provider-work plan shown below, then submit again"
    )
  rescue Ai::ContextBudget::Error => error
    errors.add(:workflow_profile_revision_id, error.message)
  end

  def automatic_mode?
    workflow_mode == "automatic"
  end

  def validate_source_import
    return if source_import_id.blank?

    if source_import.nil? || source_import.user_id != user&.id
      errors.add(:source_import_id, "is not available")
    elsif !source_import.available?(at: current_time)
      errors.add(:source_import_id, "is no longer available")
    end
  end

  def lock_source_import
    return if source_import_id.blank?

    user.source_imports.lock.find(source_import_id)
  end

  def current_time
    @clock.call
  end

  def issue_submission_token
    self.submission_token = TranslationWorkspaceSubmission.issue!(user: user).public_token
  end

  def replay!(submission)
    @experiment = submission.experiment
    @document = experiment.document
    @project = document.project
    @pipeline_run = experiment.pipeline_run
    @replayed = true
    true
  end
end
