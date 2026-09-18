class TranslationWorkspacesController < ApplicationController
  CONFIGURATION_OPTION_LIMIT = 100
  SCALAR_ATTRIBUTES = %w[
    project_id
    project_name
    source_language
    target_language
    document_title
    source_text
    source_import_id
    source_import_project_token
    experiment_name
    instruction_prompt
    workflow_mode
    workflow_profile_revision_id
    glossary_revision_id
    methodology_profile_revision_id
    guidance_preference
    automatic_confirmation
    automatic_plan_digest
    submission_token
  ].freeze

  def new
    attributes = pagination_workspace_params
    project = find_owned_project(attributes ? attributes[:project_id] : project_id_param)
    source_import = load_source_import(attributes ? attributes[:source_import_id] : source_import_id_param)
    project_binding = attributes ? attributes[:source_import_project_token] : source_import_project_token_param
    validate_source_import_project_binding!(source_import:, project:, token: project_binding)
    workspace_attributes = attributes || {
      source_import_project_token: project_binding,
      source_text: source_import&.extracted_text,
      document_title: source_import && File.basename(source_import.original_filename, ".*")
    }
    @translation_workspace = TranslationWorkspace.new(
      workspace_attributes.merge(user: current_user, source_import: source_import),
      existing_project: project
    )
    load_available_models(project:, workspace: @translation_workspace)
    if source_import && !source_import.available?
      @translation_workspace.errors.add(:source_import_id, source_import.availability_message)
    end
  rescue ActionController::BadRequest
    head :bad_request
  end

  def options
    new
    render :new unless performed?
  end

  def repeat
    historical = current_user.experiments.includes(
      { glossary_revision: :glossary },
      { methodology_profile_revision: :methodology_profile },
      { pipeline_run: { workflow_profile_revision: [ :workflow_profile, { model_selections: :llm_model } ] } },
      { experiment_reference_revisions: { translation_reference_revision: :translation_reference } },
      { translation_runs: :llm_model },
      document: :project
    ).find(params[:experiment_id])
    @repeated_from_experiment = historical
    project = historical.document.project
    attributes = repeat_attributes(historical)
    @translation_workspace = TranslationWorkspace.new(
      attributes.merge(user: current_user),
      existing_project: project
    )
    load_available_models(project: project, workspace: @translation_workspace)
    revision = repeatable_pipeline_revision(historical)
    prepare_repeat_preview(revision, historical) if revision
    render :new
  end

  def create
    attributes = translation_workspace_params
    project = find_owned_project(attributes[:project_id])
    source_import = load_source_import(attributes[:source_import_id])
    validate_source_import_project_binding!(
      source_import:,
      project:,
      token: attributes[:source_import_project_token]
    )
    @translation_workspace = TranslationWorkspace.new(
      attributes.merge(user: current_user, source_import:),
      existing_project: project
    )
    load_available_models(project:, workspace: @translation_workspace)

    if @translation_workspace.submit
      destination = @translation_workspace.pipeline_run || @translation_workspace.experiment
      Operations::EventLogger.emit(
        @translation_workspace.replayed? ? "workspace_launch_replayed" : "workspace_launch_succeeded",
        request_id: operational_request_id,
        experiment_id: @translation_workspace.experiment.id,
        pipeline_run_id: @translation_workspace.pipeline_run&.id,
        run_type: @translation_workspace.pipeline_run ? "automatic" : "manual",
        outcome: @translation_workspace.replayed? ? "replayed" : "success"
      )
      notice = if @translation_workspace.replayed?
        "This translation launch was already completed; showing its existing result."
      elsif @translation_workspace.pipeline_run
        "Automatic translation pipeline started."
      else
        "Translation experiment started."
      end
      redirect_to destination, notice: notice
    else
      render :new, status: :unprocessable_content
    end
  rescue ActionController::ParameterMissing, ActionController::BadRequest
    head :bad_request
  end

  private

  def prepare_repeat_preview(revision, historical)
    @translation_workspace.prepare_provider_work_plan_preview(revision: revision)
  rescue Ai::ContextBudget::Error
    @repeat_configuration_notice =
      "The historical automatic profile no longer has the model capability data required for this source. " \
      "A manual launch has been prefilled with its currently active translation models; review or replace them before authorizing work."
    @translation_workspace.workflow_mode = "manual"
    @translation_workspace.workflow_profile_revision_id = nil
    @translation_workspace.automatic_plan_digest = nil
    @translation_workspace.model_ids = repeatable_translation_model_ids(historical)
  end

  def repeat_attributes(historical)
    revision = repeatable_pipeline_revision(historical)
    {
      document_title: historical.document.title,
      source_text: historical.document.source_text,
      experiment_name: "Repeat of #{historical.name.presence || historical.document.title}".first(150),
      instruction_prompt: historical.instruction_prompt,
      glossary_revision_id: repeatable_glossary_revision_id(historical),
      methodology_profile_revision_id: repeatable_methodology_revision_id(historical),
      translation_reference_revision_ids: repeatable_reference_revision_ids(historical),
      guidance_preference: historical.guidance_preference,
      workflow_mode: revision ? "automatic" : "manual",
      workflow_profile_revision_id: revision&.id,
      model_ids: revision ? [] : repeatable_translation_model_ids(historical),
      automatic_confirmation: "0"
    }
  end

  def repeatable_pipeline_revision(historical)
    revision = historical.pipeline_run&.workflow_profile_revision
    profile = revision&.workflow_profile
    revision if profile&.active? && profile.current_revision_id == revision.id && revision.routing_eligible?
  end

  def repeatable_translation_model_ids(historical)
    historical.translation_runs.filter_map do |run|
      model = run.llm_model
      model.id if model.active? && model.gateway == "openrouter"
    end
  end

  def repeatable_glossary_revision_id(historical)
    revision = historical.glossary_revision
    glossary = revision&.glossary
    revision.id if glossary&.active? && glossary.current_revision_id == revision.id
  end

  def repeatable_methodology_revision_id(historical)
    revision = historical.methodology_profile_revision
    profile = revision&.methodology_profile
    revision.id if profile&.active? && profile.current_revision_id == revision.id
  end

  def repeatable_reference_revision_ids(historical)
    historical.experiment_reference_revisions.filter_map do |snapshot|
      revision = snapshot.translation_reference_revision
      reference = revision.translation_reference
      revision.id.to_s if reference.active? && reference.current_revision_id == revision.id
    end
  end

  def operational_request_id
    request.request_id.to_s.gsub(/[^A-Za-z0-9_-]/, "").first(100).presence || SecureRandom.uuid
  end

  def load_available_models(project: nil, workspace: nil)
    @available_models = LlmModel.active_openrouter.order(:display_name, :id)
    workflow_scope = current_user.workflow_profiles.active.includes(
      current_revision: { model_selections: :llm_model }
    )
    glossary_scope = current_user.glossaries.active
    methodology_scope = current_user.methodology_profiles.active
    reference_scope = current_user.translation_references.active
    if project
      source_language = TranslationLanguagePair.normalize(project.source_language)
      target_language = TranslationLanguagePair.normalize(project.target_language)
      glossary_scope = glossary_scope.joins(:current_revision).where(
        "LOWER(BTRIM(glossary_revisions.source_language, " \
          "CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) = :source_language AND " \
          "LOWER(BTRIM(glossary_revisions.target_language, " \
          "CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) = :target_language",
        source_language:,
        target_language:
      )
      methodology_scope = methodology_scope.joins(:current_revision).where(
        "LOWER(BTRIM(methodology_profile_revisions.source_language, " \
          "CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) = :source_language AND " \
          "LOWER(BTRIM(methodology_profile_revisions.target_language, " \
          "CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) = :target_language",
        source_language:,
        target_language:
      )
      reference_scope = reference_scope.joins(:current_revision).where(
        "LOWER(BTRIM(translation_reference_revisions.source_language, " \
          "CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) = :source_language AND " \
          "LOWER(BTRIM(translation_reference_revisions.target_language, " \
          "CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' ')) = :target_language",
        source_language:,
        target_language:
      )
    end
    @workflow_profiles, @workflow_profiles_pagination = paginated_configuration_options(
      workflow_scope,
      selected_revision_ids: workspace&.workflow_profile_revision_id,
      selected_limit: 1,
      page_param: :workflow_profile_page
    )
    @glossaries, @glossaries_pagination = paginated_configuration_options(
      glossary_scope.includes(current_revision: :entries),
      selected_revision_ids: workspace&.glossary_revision_id,
      selected_limit: 1,
      page_param: :glossary_page
    )
    @methodology_profiles, @methodology_profiles_pagination = paginated_configuration_options(
      methodology_scope.includes(:current_revision),
      selected_revision_ids: workspace&.methodology_profile_revision_id,
      selected_limit: 1,
      page_param: :methodology_profile_page
    )
    @translation_references, @translation_references_pagination = paginated_configuration_options(
      reference_scope.includes(:current_revision),
      selected_revision_ids: workspace&.translation_reference_revision_ids,
      selected_limit: ExperimentReferenceRevision::MAXIMUM_REFERENCES,
      page_param: :translation_reference_page
    )
  end

  def paginated_configuration_options(scope, selected_revision_ids:, selected_limit:, page_param:)
    total_count = scope.count
    total_pages = [ (total_count.to_f / CONFIGURATION_OPTION_LIMIT).ceil, 1 ].max
    current_page = normalized_configuration_page(params[page_param], total_pages)
    page = scope.order(updated_at: :desc, id: :desc)
      .offset((current_page - 1) * CONFIGURATION_OPTION_LIMIT)
      .limit(CONFIGURATION_OPTION_LIMIT)
      .to_a
    revision_ids = Array(selected_revision_ids).filter_map do |value|
      value.to_i if value.to_s.match?(/\A[1-9]\d*\z/)
    end.uniq.first(selected_limit)
    if revision_ids.any?
      selected = scope.where(current_revision_id: revision_ids)
        .where.not(id: page.map(&:id))
        .order(updated_at: :desc, id: :desc)
        .limit(selected_limit)
        .to_a
      page = (page + selected).sort_by { |record| [ record.updated_at, record.id ] }.reverse
    end
    pagination = { current_page: current_page, total_pages: total_pages, total_count: total_count }
    [ page, pagination ]
  end

  def normalized_configuration_page(value, total_pages)
    requested = Integer(value.presence || 1, 10)
    requested.clamp(1, total_pages)
  rescue ArgumentError, TypeError
    1
  end

  def pagination_workspace_params
    return unless params[:translation_workspace].present?

    translation_workspace_params
  end

  def translation_workspace_params
    submitted = params.require(:translation_workspace)
    unless submitted.is_a?(ActionController::Parameters)
      raise ActionController::BadRequest, "translation_workspace must be a parameter object"
    end
    # The legacy form object exposes a virtual `user` attribute. Ignore it at
    # this boundary and always inject current_user server-side.
    unexpected = submitted.keys - (SCALAR_ATTRIBUTES + [ "model_ids", "translation_reference_revision_ids", "user" ])
    raise ActionController::BadRequest, "Unexpected parameters" if unexpected.any?

    SCALAR_ATTRIBUTES.each do |attribute|
      value = submitted[attribute]
      unless value.nil? || value.is_a?(String)
        raise ActionController::BadRequest, "#{attribute} must be a scalar value"
      end
    end

    unless TranslationWorkspaceSubmission.valid_public_token?(submitted[:submission_token])
      raise ActionController::BadRequest, "submission_token is invalid"
    end

    model_ids = submitted[:model_ids]
    unless model_ids.nil? || (model_ids.is_a?(Array) && model_ids.all? { |id| id.is_a?(String) })
      raise ActionController::BadRequest, "model_ids must be a list of scalar values"
    end


    reference_ids = submitted[:translation_reference_revision_ids]
    unless reference_ids.nil? || (reference_ids.is_a?(Array) && reference_ids.all? { |id| id.is_a?(String) })
      raise ActionController::BadRequest, "translation_reference_revision_ids must be a list of scalar values"
    end

    submitted.permit(*SCALAR_ATTRIBUTES, model_ids: [], translation_reference_revision_ids: [])
  end

  def load_source_import(id)
    return if id.blank?

    current_user.source_imports.find(id)
  end

  def source_import_id_param
    value = params[:source_import_id]
    return if value.nil?
    unless value.is_a?(String)
      raise ActionController::BadRequest, "source_import_id must be a scalar value"
    end

    value.presence
  end

  def project_id_param
    value = params[:project_id]
    return if value.nil?
    unless value.is_a?(String)
      raise ActionController::BadRequest, "project_id must be a scalar value"
    end

    value.presence
  end

  def source_import_project_token_param
    value = params[:source_import_project_token]
    return if value.nil?
    unless value.is_a?(String)
      raise ActionController::BadRequest, "source_import_project_token must be a scalar value"
    end

    value.presence
  end

  def validate_source_import_project_binding!(source_import:, project:, token:)
    if source_import
      return if SourceImports::ProjectBinding.valid?(token:, source_import:, project:)

      raise ActiveRecord::RecordNotFound
    end
    return if token.blank?

    raise ActionController::BadRequest, "source_import_project_token is unexpected"
  end
end
