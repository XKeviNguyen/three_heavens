class SourceImportsController < ApplicationController
  def new
    @project = find_owned_project(project_id_param)
    @source_import = SourceImport.new
  rescue ActionController::BadRequest
    head :bad_request
  end

  def create
    submitted = source_import_params
    @project = find_owned_project(submitted[:project_id])
    @source_import = SourceImports::Create.call(
      user: current_user,
      upload: submitted.fetch(:source_file)
    )
    project_binding = SourceImports::ProjectBinding.issue(source_import: @source_import, project: @project)
    if request.format.json?
      render json: {
        id: @source_import.id,
        original_filename: @source_import.original_filename,
        imported_format: @source_import.imported_format,
        byte_size: @source_import.byte_size,
        extracted_text: @source_import.extracted_text,
        project_binding: project_binding
      }, status: :created
    else
      redirect_to new_translation_workspace_path(
        source_import_id: @source_import.id,
        project_id: @project&.id,
        source_import_project_token: project_binding
      ), notice: "Source text extracted. Review and edit it before starting translation."
    end
  rescue SourceImports::Error => error
    @source_import = SourceImport.new
    if request.format.json?
      render json: { error: error.message }, status: :unprocessable_content
    else
      flash.now[:alert] = error.message
      render :new, status: :unprocessable_content
    end
  rescue ActionController::ParameterMissing, ActionController::BadRequest
    @source_import = SourceImport.new
    if request.format.json?
      render json: { error: "The upload request is invalid. Choose one source file and try again." }, status: :bad_request
    else
      flash.now[:alert] = "The upload request is invalid. Choose one source file and try again."
      render :new, status: :bad_request
    end
  end

  def destroy
    source_import = current_user.source_imports.find(params[:id])
    SourceImport.transaction do
      source_import.lock!
      unless source_import.status.in?(%w[pending ready failed])
        if request.format.json?
          render json: { error: "This source import can no longer be canceled." }, status: :conflict
        else
          redirect_to root_path, alert: "This source import can no longer be canceled."
        end
        return
      end
      source_import.destroy!
    end
    if request.format.json?
      head :no_content
    else
      redirect_to root_path, notice: "Source import canceled."
    end
  end

  private

  def source_import_params
    submitted = params.require(:source_import)
    unless submitted.is_a?(ActionController::Parameters)
      raise ActionController::BadRequest, "source_import must be a parameter object"
    end

    unexpected = submitted.keys - %w[source_file project_id]
    raise ActionController::BadRequest, "Unexpected parameters" if unexpected.any?

    upload = submitted.require(:source_file)
    unless upload.is_a?(ActionDispatch::Http::UploadedFile)
      raise ActionController::BadRequest, "source_file must be one uploaded file"
    end

    project_id = submitted[:project_id]
    unless project_id.nil? || project_id.is_a?(String)
      raise ActionController::BadRequest, "project_id must be a scalar value"
    end

    { source_file: upload, project_id: project_id.presence }
  end

  def project_id_param
    value = params[:project_id]
    return if value.nil?
    unless value.is_a?(String)
      raise ActionController::BadRequest, "project_id must be a scalar value"
    end

    value.presence
  end
end
