class SourceImportsController < ApplicationController
  def new
    @source_import = SourceImport.new
  end

  def create
    @source_import = SourceImports::Create.call(
      user: current_user,
      upload: source_file_param
    )
    redirect_to new_translation_workspace_path(source_import_id: @source_import.id),
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

  def source_file_param
    submitted = params.require(:source_import)
    unless submitted.is_a?(ActionController::Parameters)
      raise ActionController::BadRequest, "source_import must be a parameter object"
    end

    upload = submitted.require(:source_file)
    unless upload.is_a?(ActionDispatch::Http::UploadedFile)
      raise ActionController::BadRequest, "source_file must be one uploaded file"
    end

    upload
  end
end
