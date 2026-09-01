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
    redirect_to new_translation_workspace_path(source_import_id: @source_import.id, project_id: @project&.id),
                notice: "Source text extracted. Review and edit it before starting translation."
  rescue SourceImports::Error => error
    @source_import = SourceImport.new
    flash.now[:alert] = error.message
    render :new, status: :unprocessable_content
  rescue ActionController::ParameterMissing, ActionController::BadRequest
    @source_import = SourceImport.new
    flash.now[:alert] = "The upload request is invalid. Choose one source file and try again."
    render :new, status: :bad_request
  end

  def destroy
    source_import = current_user.source_imports.find(params[:id])
    SourceImport.transaction do
      source_import.lock!
      unless source_import.status.in?(%w[pending ready failed])
        redirect_to root_path, alert: "This source import can no longer be canceled."
        return
      end
      source_import.destroy!
    end
    redirect_to root_path, notice: "Source import canceled."
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
