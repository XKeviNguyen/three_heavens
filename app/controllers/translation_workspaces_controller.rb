class TranslationWorkspacesController < ApplicationController
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
    automatic_confirmation
    automatic_plan_digest
    submission_token
  ].freeze

  def new
    project = find_owned_project(project_id_param)
    source_import = load_source_import(source_import_id_param)
    project_binding = source_import_project_token_param
    validate_source_import_project_binding!(source_import:, project:, token: project_binding)
    load_available_models(project:)
    @translation_workspace = TranslationWorkspace.new({
      user: current_user,
      source_import: source_import,
      source_import_project_token: project_binding,
      source_text: source_import&.extracted_text,
      document_title: source_import && File.basename(source_import.original_filename, ".*")
    }, existing_project: project)
    if source_import && !source_import.available?
      @translation_workspace.errors.add(:source_import_id, "is no longer available")
    end
  rescue ActionController::BadRequest
    head :bad_request
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
    load_available_models(project:)
    @translation_workspace = TranslationWorkspace.new(
      attributes.merge(user: current_user, source_import:),
      existing_project: project
    )

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

  def operational_request_id
    request.request_id.to_s.gsub(/[^A-Za-z0-9_-]/, "").first(100).presence || SecureRandom.uuid
  end

  def load_available_models(project: nil)
    @available_models = LlmModel.active_openrouter.order(:display_name, :id)
    @workflow_profiles = current_user.workflow_profiles.active.includes(
      current_revision: { model_selections: :llm_model }
    ).order(updated_at: :desc, id: :desc)
    glossary_scope = current_user.glossaries.active
    methodology_scope = current_user.methodology_profiles.active
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
    end
    @glossaries = glossary_scope.includes(current_revision: :entries).order(updated_at: :desc, id: :desc)
    @methodology_profiles = methodology_scope.includes(:current_revision)
      .order(updated_at: :desc, id: :desc)
  end

  def translation_workspace_params
    submitted = params.require(:translation_workspace)
    unless submitted.is_a?(ActionController::Parameters)
      raise ActionController::BadRequest, "translation_workspace must be a parameter object"
    end
    # The legacy form object exposes a virtual `user` attribute. Ignore it at
    # this boundary and always inject current_user server-side.
    unexpected = submitted.keys - (SCALAR_ATTRIBUTES + [ "model_ids", "user" ])
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

    submitted.permit(*SCALAR_ATTRIBUTES, model_ids: [])
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
    if source_import && project
      return if SourceImports::ProjectBinding.valid?(token:, source_import:, project:)

      raise ActiveRecord::RecordNotFound
    end
    return if token.blank?

    raise ActionController::BadRequest, "source_import_project_token is unexpected"
  end
end
