class SourceImportsController < ApplicationController
  include UploadBudgetAdmission
  before_action :admit_upload, only: :create

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
      upload: submitted.fetch(:source_file),
      request_key: submitted.fetch(:request_key)
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
      ), notice: t("source_imports.imported_notice")
    end
  rescue SourceImports::Busy => error
    # Temporary and nothing was stored, so a retry is processed afresh: the
    # workspace uploader resends the same request key after a 5xx, and the
    # upload form issues a new one.
    response.set_header("Retry-After", SourceImports::Limits::BUSY_RETRY_AFTER_SECONDS.to_s)
    refund_upload_budget
    render_import_failure(error, status: :service_unavailable)
  rescue SourceImports::Error => error
    render_import_failure(error, status: :unprocessable_content)
  rescue ActionController::ParameterMissing, ActionController::BadRequest
    @source_import = SourceImport.new
    if request.format.json?
      render json: { error: t("source_imports.invalid_request") }, status: :bad_request
    else
      flash.now[:alert] = t("source_imports.invalid_request")
      render :new, status: :bad_request
    end
  end

  def destroy
    source_import = current_user.source_imports.find(params[:id])
    SourceImport.transaction do
      source_import.lock!
      unless source_import.status.in?(%w[pending ready failed])
        if request.format.json?
          render json: { error: t("source_imports.cancel_unavailable") }, status: :conflict
        else
          redirect_to new_translation_workspace_path, alert: t("source_imports.cancel_unavailable")
        end
        return
      end
      source_import.destroy!
    end
    if request.format.json?
      head :no_content
    else
      redirect_to new_translation_workspace_path, notice: t("source_imports.canceled")
    end
  end

  private

  def render_rate_limited
    response.set_header("Retry-After", SourceImports::Limits::UPLOAD_WINDOW.to_i.to_s)
    render_import_failure_message(t("source_imports.errors.rate_limited"), status: :too_many_requests)
  end

  def render_import_failure(error, status:)
    render_import_failure_message(t("source_imports.errors.#{error.code}", default: error.message), status:)
  end

  def render_import_failure_message(message, status:)
    @source_import = SourceImport.new
    if request.format.json?
      render json: { error: message }, status:
    else
      flash.now[:alert] = message
      render :new, status:
    end
  end

  def source_import_params
    submitted = params.require(:source_import)
    unless submitted.is_a?(ActionController::Parameters)
      raise ActionController::BadRequest, "source_import must be a parameter object"
    end

    unexpected = submitted.keys - %w[source_file project_id request_key]
    raise ActionController::BadRequest, "Unexpected parameters" if unexpected.any?

    # One random key per upload action makes replayed deliveries resolvable.
    request_key = submitted[:request_key]
    unless request_key.is_a?(String) && request_key.match?(SourceImports::Limits::REQUEST_KEY_FORMAT)
      raise ActionController::BadRequest, "request_key must identify one upload action"
    end

    upload = submitted.require(:source_file)
    unless upload.is_a?(ActionDispatch::Http::UploadedFile)
      raise ActionController::BadRequest, "source_file must be one uploaded file"
    end

    project_id = submitted[:project_id]
    unless project_id.nil? || project_id.is_a?(String)
      raise ActionController::BadRequest, "project_id must be a scalar value"
    end

    { source_file: upload, project_id: project_id.presence, request_key: }
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
