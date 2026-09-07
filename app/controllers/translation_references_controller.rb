class TranslationReferencesController < ApplicationController
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

  def index
    @translation_references = current_user.translation_references.includes(:current_revision)
      .order(active: :desc, updated_at: :desc, id: :desc)
  end

  def new
    @form_values = {}
  end

  def create
    attributes = TranslationReferences::AuthoringAttributes.call(
      exact_reference_parameters!(include_expected_version: false)
    )
    reference = TranslationReferences::Create.call(user: current_user, attributes: attributes)
    redirect_to reference, notice: "Translation reference created."
  rescue TranslationReferences::AuthoringAttributes::Error, ActiveRecord::RecordInvalid => error
    @form_values = safe_submitted_values.merge(attributes || {})
    @form_values.merge!(error.resolved_attributes) if error.is_a?(TranslationReferences::AuthoringAttributes::Error)
    @form_errors = error_messages(error)
    render :new, status: :unprocessable_content
  end

  def show
    @translation_reference = current_user.translation_references.includes(revisions: :experiments)
      .find(@translation_reference.id)
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
    redirect_to @translation_reference, notice: "Translation reference revision #{revision.version} created."
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
    redirect_to @translation_reference, notice: "Translation reference activated."
  end

  def deactivate
    reject_unexpected_parameters!
    TranslationReferences::ChangeStatus.deactivate(translation_reference: @translation_reference)
    redirect_to @translation_reference,
                notice: "Translation reference archived. Historical experiment snapshots remain available."
  end

  private

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
