class TranslationWorkspacesController < ApplicationController
  SCALAR_ATTRIBUTES = %w[
    project_name
    source_language
    target_language
    document_title
    source_text
    source_import_id
    experiment_name
    instruction_prompt
    workflow_mode
    workflow_profile_revision_id
    automatic_confirmation
  ].freeze

  before_action :load_available_models

  def new
    source_import = load_source_import(source_import_id_param)
    @translation_workspace = TranslationWorkspace.new({
      user: current_user,
      source_import: source_import,
      source_text: source_import&.extracted_text,
      document_title: source_import && File.basename(source_import.original_filename, ".*")
    })
    if source_import && !source_import.available?
      @translation_workspace.errors.add(:source_import_id, "is no longer available")
    end
  rescue ActionController::BadRequest
    head :bad_request
  end

  def create
    attributes = translation_workspace_params
    source_import = load_source_import(attributes[:source_import_id])
    @translation_workspace = TranslationWorkspace.new(
      attributes.merge(user: current_user, source_import:)
    )

    if @translation_workspace.submit
      destination = @translation_workspace.pipeline_run || @translation_workspace.experiment
      redirect_to destination, notice: @translation_workspace.pipeline_run ? "Automatic translation pipeline started." : "Translation experiment started."
    else
      render :new, status: :unprocessable_content
    end
  rescue ActionController::ParameterMissing, ActionController::BadRequest
    head :bad_request
  end

  private

  def load_available_models
    @available_models = LlmModel.active_openrouter.order(:display_name, :id)
    @workflow_profiles = current_user.workflow_profiles.active.includes(
      current_revision: { model_selections: :llm_model }
    ).order(updated_at: :desc, id: :desc)
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
end
