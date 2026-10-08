class GlossariesController < ApplicationController
  SCALAR_KEYS = %w[name description source_language target_language expected_version].freeze
  ENTRY_KEYS = %w[source_term preferred_target_term note].freeze

  before_action :set_glossary, only: %i[show edit update activate deactivate]

  def index
    @glossaries = paginate(
      current_user.glossaries.includes(current_revision: :entries).order(active: :desc, updated_at: :desc, id: :desc)
    )
  end

  def new
    @form_values = default_form_values
  end

  def create
    glossary = Glossaries::Create.call(user: current_user, attributes: exact_glossary_parameters!(include_expected_version: false))
    redirect_to glossary, notice: t("flash_ui.glossary.created")
  rescue Glossaries::BuildRevision::Error, ActiveRecord::RecordInvalid => error
    @form_values = safe_submitted_values
    @form_errors = error_messages(error)
    render :new, status: :unprocessable_content
  end

  def show
    @glossary = current_user.glossaries.find(@glossary.id)
    @revisions = paginate(@glossary.revisions.includes(:entries, :experiments))
  end

  def edit
    @form_values = revision_form_values(@glossary.current_revision)
  end

  def update
    attributes = exact_glossary_parameters!(include_expected_version: true)
    revision = Glossaries::Revise.call(glossary: @glossary, expected_version: attributes.delete("expected_version"), attributes: attributes)
    redirect_to @glossary, notice: t("flash_ui.glossary.revision", version: revision.version)
  rescue Glossaries::Revise::StaleRevisionError => error
    @form_values = safe_submitted_values
    @form_errors = [ error.message ]
    render :edit, status: :conflict
  rescue Glossaries::BuildRevision::Error, ActiveRecord::RecordInvalid => error
    @form_values = safe_submitted_values
    @form_errors = error_messages(error)
    render :edit, status: :unprocessable_content
  end

  def activate
    reject_unexpected_parameters!
    Glossaries::ChangeStatus.activate(glossary: @glossary)
    redirect_to @glossary, notice: t("flash_ui.glossary.activated")
  end

  def deactivate
    reject_unexpected_parameters!
    Glossaries::ChangeStatus.deactivate(glossary: @glossary)
    redirect_to @glossary, notice: t("flash_ui.glossary.archived")
  end

  private

  def set_glossary
    @glossary = current_user.glossaries.includes(current_revision: :entries).find(params[:id])
  end

  def exact_glossary_parameters!(include_expected_version:)
    submitted = params.require(:glossary)
    raise ActionController::BadRequest, "glossary must be an object" unless submitted.is_a?(ActionController::Parameters)

    scalar_keys = include_expected_version ? SCALAR_KEYS : SCALAR_KEYS - [ "expected_version" ]
    allowed = scalar_keys + [ "entries" ]
    raise ActionController::BadRequest, "Unexpected parameters" if (submitted.keys - allowed).any?
    scalar_keys.each do |key|
      value = submitted[key]
      raise ActionController::BadRequest, "#{key} must be a scalar" unless value.nil? || value.is_a?(String)
    end

    entries = submitted["entries"]
    unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(ActionController::Parameters) }
      raise ActionController::BadRequest, "entries must be a list of objects"
    end
    raise ActionController::BadRequest, "Too many entries" if entries.size > GlossaryRevision::MAXIMUM_ENTRIES
    entries.each do |entry|
      raise ActionController::BadRequest, "Unexpected entry parameters" if (entry.keys - ENTRY_KEYS).any?
      ENTRY_KEYS.each do |key|
        value = entry[key]
        raise ActionController::BadRequest, "#{key} must be a scalar" unless value.nil? || value.is_a?(String)
      end
    end

    submitted.permit(*scalar_keys, entries: ENTRY_KEYS).to_h
  end

  def reject_unexpected_parameters!
    submitted = params[:glossary]
    return if submitted.nil? || (submitted.is_a?(ActionController::Parameters) && submitted.empty?)

    raise ActionController::BadRequest, "Unexpected parameters"
  end

  def default_form_values
    { "entries" => [ { "source_term" => "", "preferred_target_term" => "", "note" => "" } ] }
  end

  def revision_form_values(revision)
    {
      "name" => revision.name,
      "description" => revision.description,
      "source_language" => revision.source_language,
      "target_language" => revision.target_language,
      "expected_version" => revision.version.to_s,
      "entries" => revision.entries.map { |entry| entry.slice("source_term", "preferred_target_term", "note") }
    }
  end

  def safe_submitted_values
    submitted = params[:glossary]
    return default_form_values unless submitted.is_a?(ActionController::Parameters)

    values = submitted.to_unsafe_h.slice(*SCALAR_KEYS, "entries")
    values["entries"] = default_form_values["entries"] unless values["entries"].is_a?(Array)
    values
  end

  def error_messages(error)
    return error.record.errors.full_messages if error.respond_to?(:record)

    [ error.message ]
  end
end
