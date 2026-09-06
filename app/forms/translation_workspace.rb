class TranslationWorkspace
  include ActiveModel::Model

  attr_accessor :project_name,
                :project_id,
                :user,
                :source_language,
                :target_language,
                :document_title,
                :source_text,
                :source_import,
                :source_import_id,
                :source_import_project_token,
                :experiment_name,
                :instruction_prompt,
                :model_ids,
                :workflow_mode,
                :workflow_profile_revision_id,
                :glossary_revision_id,
                :methodology_profile_revision_id,
                :translation_reference_revision_ids,
                :guidance_preference,
                :automatic_confirmation,
                :automatic_plan_digest,
                :submission_token

  attr_reader :document, :experiment, :pipeline_run, :project, :provider_work_plan_preview

  validate :validate_workspace_records
  validate :validate_model_selection
  validate :validate_source_import
  validate :validate_glossary_selection
  validate :validate_methodology_selection
  validate :validate_reference_selection

  def initialize(attributes = {}, start_service: TranslationExperiments::Start, clock: -> { Time.current }, existing_project: nil)
    @start_service = start_service
    @clock = clock
    @existing_project = existing_project
    @project = existing_project
    super(attributes)
    self.project_id ||= existing_project&.id
    apply_authoritative_project_attributes(existing_project) if existing_project
    self.model_ids = [] if model_ids.nil?
    self.translation_reference_revision_ids = [] if translation_reference_revision_ids.nil?
    self.guidance_preference = "reference_examples" if guidance_preference.blank?
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
      next false unless lock_existing_project
      next false unless valid?
      next false unless lock_methodology_selection
      next false unless lock_reference_selections

      project.save! if project.new_record?
      locked_import = lock_source_import
      if locked_import
        SourceImports::Consume.apply!(source_import: locked_import, document: document, at: current_time)
      end
      document.save!
      experiment.save!
      snapshot_reference_revisions!
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
    message = if error.message == TranslationReferences::ContextBudgetMessage::MESSAGE
      error.message
    else
      "The translation experiment could not be started. Please review the form and try again."
    end
    errors.add(:base, message)
    false
  end

  def replayed?
    @replayed == true
  end

  def existing_project?
    project_id.present?
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
      instruction_prompt: :instruction_prompt,
      methodology_profile_revision: :methodology_profile_revision_id,
      guidance_preference: :guidance_preference
    }
  }.freeze

  def build_workspace_records
    @project = @existing_project || Project.new(
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
      instruction_prompt: instruction_prompt,
      glossary_revision: @glossary_revision,
      methodology_profile_revision: @methodology_profile_revision,
      guidance_preference: guidance_preference
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

  def lock_existing_project
    return true unless existing_project?

    unless project_id.to_s.match?(/\A[1-9]\d*\z/)
      errors.add(:project_id, "is not valid")
      return false
    end

    locked_project = user.projects.lock.find_by(id: project_id)
    unless locked_project
      errors.add(:project_id, "is not available")
      return false
    end

    @existing_project = locked_project
    @project = locked_project
    apply_authoritative_project_attributes(locked_project)
    true
  end

  def apply_authoritative_project_attributes(existing_project)
    self.project_name = existing_project.name
    self.source_language = existing_project.source_language
    self.target_language = existing_project.target_language
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
    if source_import_id.blank?
      errors.add(:source_import_project_token, "is unexpected") if source_import_project_token.present?
      return
    end

    if source_import.nil? || source_import.user_id != user&.id
      errors.add(:source_import_id, "is not available")
    elsif !source_import.available?(at: current_time)
      errors.add(:source_import_id, "is no longer available")
    elsif !SourceImports::ProjectBinding.valid?(
      token: source_import_project_token,
      source_import:,
      project: binding_project
    )
      errors.add(:source_import_id, "is not available for this workspace")
    end
  end

  def validate_glossary_selection
    return if glossary_revision_id.blank?

    unless glossary_revision_id.to_s.match?(/\A[1-9]\d*\z/)
      errors.add(:glossary_revision_id, "is not a valid glossary revision")
      return
    end
    @glossary_revision = GlossaryRevision.includes(:glossary).joins(:glossary)
      .where(glossaries: { user_id: user.id, active: true }).find_by(id: glossary_revision_id)
    unless @glossary_revision
      errors.add(:glossary_revision_id, "is not available")
      return
    end
    unless @glossary_revision.glossary.current_revision_id == @glossary_revision.id
      errors.add(:glossary_revision_id, "is stale; select the current glossary revision")
      return
    end
    unless @glossary_revision.language_pair_matches?(source_language: source_language, target_language: target_language)
      errors.add(:glossary_revision_id, "must match the project's source and target languages")
      return
    end

    @experiment.glossary_revision = @glossary_revision
  end

  def validate_methodology_selection
    return if methodology_profile_revision_id.blank?

    unless methodology_profile_revision_id.to_s.match?(/\A[1-9]\d*\z/)
      errors.add(:methodology_profile_revision_id, "is not a valid methodology revision")
      return
    end
    @methodology_profile_revision = MethodologyProfileRevision.includes(:methodology_profile)
      .joins(:methodology_profile)
      .where(methodology_profiles: { user_id: user.id, active: true })
      .find_by(id: methodology_profile_revision_id)
    unless @methodology_profile_revision
      errors.add(:methodology_profile_revision_id, "is not available")
      return
    end
    unless @methodology_profile_revision.methodology_profile.current_revision_id == @methodology_profile_revision.id
      errors.add(:methodology_profile_revision_id, "is stale; select the current methodology revision")
      return
    end
    unless @methodology_profile_revision.language_pair_matches?(
      source_language: source_language,
      target_language: target_language
    )
      errors.add(:methodology_profile_revision_id, "must match the project's source and target languages")
      return
    end

    @experiment.methodology_profile_revision = @methodology_profile_revision
  end

  def validate_reference_selection
    ids = translation_reference_revision_ids
    unless ids.is_a?(Array)
      errors.add(:translation_reference_revision_ids, "must be a list")
      return
    end
    submitted = ids.map(&:to_s)
    if submitted.length > ExperimentReferenceRevision::MAXIMUM_REFERENCES
      errors.add(:translation_reference_revision_ids, "cannot include more than 5 references")
      return
    end
    unless submitted.all? { |id| id.match?(/\A[1-9]\d*\z/) }
      errors.add(:translation_reference_revision_ids, "contain an invalid reference selection")
      return
    end
    if submitted.uniq.length != submitted.length
      errors.add(:translation_reference_revision_ids, "cannot contain duplicates")
      return
    end

    selected_ids = submitted.map(&:to_i).sort
    @selected_reference_revisions = TranslationReferenceRevision.includes(:translation_reference)
      .joins(:translation_reference)
      .where(
        id: selected_ids,
        translation_references: { user_id: user.id, active: true }
      ).order(:id).to_a
    unless @selected_reference_revisions.map(&:id) == selected_ids
      errors.add(:translation_reference_revision_ids, "contain an unavailable reference")
      return
    end

    @selected_reference_revisions.each do |revision|
      reference = revision.translation_reference
      unless reference.current_revision_id == revision.id
        errors.add(:translation_reference_revision_ids, "contain a stale reference revision")
        next
      end
      unless revision.language_pair_matches?(source_language: source_language, target_language: target_language)
        errors.add(:translation_reference_revision_ids, "must match the project's source and target languages")
      end
    end
  end

  def lock_source_import
    return if source_import_id.blank?

    locked_import = user.source_imports.lock.find(source_import_id)
    SourceImports::ProjectBinding.verify!(
      token: source_import_project_token,
      source_import: locked_import,
      project: binding_project
    )
    locked_import
  end

  def binding_project
    project if existing_project?
  end

  def lock_methodology_selection
    return true unless @methodology_profile_revision

    profile = MethodologyProfile.lock.find_by(
      id: @methodology_profile_revision.methodology_profile_id,
      user_id: user.id
    )
    if profile&.active? && profile.current_revision_id == @methodology_profile_revision.id
      @methodology_profile_revision.association(:methodology_profile).target = profile
      return true
    end

    errors.add(:methodology_profile_revision_id, "is no longer the active current methodology revision")
    false
  end

  def lock_reference_selections
    return true if @selected_reference_revisions.blank?

    references_by_id = TranslationReference.lock.where(
      id: @selected_reference_revisions.map(&:translation_reference_id),
      user_id: user.id
    ).order(:id).index_by(&:id)
    eligible = @selected_reference_revisions.all? do |revision|
      reference = references_by_id[revision.translation_reference_id]
      reference&.active? && reference.current_revision_id == revision.id &&
        revision.language_pair_matches?(
          source_language: project.source_language,
          target_language: project.target_language
        )
    end
    return true if eligible

    errors.add(:translation_reference_revision_ids, "are no longer active current references for this project")
    false
  end

  def snapshot_reference_revisions!
    Array(@selected_reference_revisions).each_with_index do |revision, index|
      experiment.experiment_reference_revisions.create!(
        translation_reference_revision: revision,
        position: index + 1
      )
    end
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
