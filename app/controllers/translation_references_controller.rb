class TranslationReferencesController < ApplicationController
  include UploadBudgetAdmission
  SCALAR_KEYS = %w[
    title
    source_language
    target_language
    source_text
    approved_translation
    expected_version
  ].freeze
  FILE_KEYS = %w[source_file approved_translation_file].freeze

  before_action :set_translation_reference, only: %i[show edit update activate deactivate]
  # Requests that carry files share the account's upload budget with source
  # imports (SourceImports::Limits::UPLOADS_PER_WINDOW); text-only edits do not.
  before_action :admit_upload, only: %i[create update], if: :uploading_files?

  def index
    @translation_references = paginate(
      current_user.translation_references.includes(:current_revision)
        .order(active: :desc, updated_at: :desc, id: :desc)
    )
  end

  def new
    @form_values = {}
  end

  def create
    attributes = TranslationReferences::AuthoringAttributes.call(
      exact_reference_parameters!(include_expected_version: false)
    )
    reference = TranslationReferences::Create.call(user: current_user, attributes: attributes)
    redirect_to reference, notice: t("flash_ui.reference.created")
  rescue TranslationReferences::AuthoringAttributes::Busy => error
    render_busy(error)
  rescue TranslationReferences::AuthoringAttributes::Error, ActiveRecord::RecordInvalid => error
    @form_values = safe_submitted_values.merge(attributes || {})
    @form_values.merge!(error.resolved_attributes) if error.is_a?(TranslationReferences::AuthoringAttributes::Error)
    @form_errors = error_messages(error)
    render :new, status: :unprocessable_content
  end

  def show
    @translation_reference = current_user.translation_references.find(@translation_reference.id)
    @revisions = paginate(@translation_reference.revisions.includes(:experiments))
  end

  def edit
    @form_values = revision_form_values(@translation_reference.current_revision)
  end

  def update
    submitted = exact_reference_parameters!(include_expected_version: true)
    expected_version = submitted.delete("expected_version")
    replace_prefilled_text_with_upload!(submitted, expected_version: expected_version)
    attributes = TranslationReferences::AuthoringAttributes.call(submitted)
    revision = TranslationReferences::Revise.call(
      translation_reference: @translation_reference,
      expected_version: expected_version,
      attributes: attributes
    )
    redirect_to @translation_reference, notice: t("flash_ui.reference.revision", version: revision.version)
  rescue TranslationReferences::AuthoringAttributes::Busy => error
    render_busy(error)
  rescue TranslationReferences::Revise::StaleRevisionError => error
    @current_revision = @translation_reference.reload.current_revision
    @form_values = attributes.merge(
      "expected_version" => @current_revision.version.to_s
    )
    @form_errors = [ error.message ]
    render :edit, status: :conflict
  rescue TranslationReferences::AuthoringAttributes::Error, ActiveRecord::RecordInvalid => error
    @form_values = safe_submitted_values.merge(attributes || {})
    @form_values.merge!(error.resolved_attributes) if error.is_a?(TranslationReferences::AuthoringAttributes::Error)
    @form_errors = error_messages(error)
    render :edit, status: :unprocessable_content
  end

  def activate
    reject_unexpected_parameters!
    TranslationReferences::ChangeStatus.activate(translation_reference: @translation_reference)
    redirect_to @translation_reference, notice: t("flash_ui.reference.activated")
  end

  def deactivate
    reject_unexpected_parameters!
    TranslationReferences::ChangeStatus.deactivate(translation_reference: @translation_reference)
    redirect_to @translation_reference,
                notice: t("flash_ui.reference.archived")
  end

  private

  def render_busy(error)
    refund_upload_budget unless error.work_consumed
    response.set_header("Retry-After", SourceImports::Limits::BUSY_RETRY_AFTER_SECONDS.to_s)
    @form_values = safe_submitted_values.merge(error.resolved_attributes)
    @form_errors = [ t("source_imports.errors.#{error.code}", default: error.message) ]
    render(action_name == "create" ? :new : :edit, status: :service_unavailable)
  end

  def render_rate_limited
    response.set_header("Retry-After", SourceImports::Limits::UPLOAD_WINDOW.to_i.to_s)
    @form_values = safe_submitted_values
    @form_errors = [ t("source_imports.errors.rate_limited") ]
    render(action_name == "create" ? :new : :edit, status: :too_many_requests)
  end

  def uploading_files?
    submitted = params[:translation_reference]
    submitted.is_a?(ActionController::Parameters) && FILE_KEYS.any? { |key| submitted[key].present? }
  end

  def set_translation_reference
    @translation_reference = current_user.translation_references.includes(:current_revision).find(params[:id])
  end

  def exact_reference_parameters!(include_expected_version:)
    submitted = params.require(:translation_reference)
    unless submitted.is_a?(ActionController::Parameters)
      raise ActionController::BadRequest, "translation_reference must be an object"
    end

    scalar_keys = include_expected_version ? SCALAR_KEYS : SCALAR_KEYS - [ "expected_version" ]
    allowed = scalar_keys + FILE_KEYS
    raise ActionController::BadRequest, "Unexpected parameters" if (submitted.keys - allowed).any?
    scalar_keys.each do |key|
      value = submitted[key]
      raise ActionController::BadRequest, "#{key} must be a scalar" unless value.nil? || value.is_a?(String)
    end
    FILE_KEYS.each do |key|
      value = submitted[key]
      next if value.nil? || value.is_a?(ActionDispatch::Http::UploadedFile)

      raise ActionController::BadRequest, "#{key} must be an uploaded file"
    end

    submitted.permit(*scalar_keys, *FILE_KEYS).to_h
  end

  def reject_unexpected_parameters!
    submitted = params[:translation_reference]
    return if submitted.nil? || (submitted.is_a?(ActionController::Parameters) && submitted.empty?)

    raise ActionController::BadRequest, "Unexpected parameters"
  end

  def revision_form_values(revision)
    revision.slice(
      "title",
      "source_language",
      "target_language",
      "source_text",
      "approved_translation"
    ).merge("expected_version" => revision.version.to_s)
  end

  def safe_submitted_values
    submitted = params[:translation_reference]
    return {} unless submitted.is_a?(ActionController::Parameters)

    submitted.to_unsafe_h.slice(*SCALAR_KEYS)
  end

  def replace_prefilled_text_with_upload!(submitted, expected_version:)
    revision = @translation_reference.revisions.find_by(version: Integer(expected_version, exception: false))
    return unless revision

    {
      "source_text" => "source_file",
      "approved_translation" => "approved_translation_file"
    }.each do |text_key, file_key|
      next unless submitted[file_key].present?
      next unless submitted[text_key] == revision.public_send(text_key)

      submitted[text_key] = ""
    end
  end

  def error_messages(error)
    return error.record.errors.full_messages if error.respond_to?(:record)

    [ error.message ]
  end
end
