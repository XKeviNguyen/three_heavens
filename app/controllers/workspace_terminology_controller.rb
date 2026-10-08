class WorkspaceTerminologyController < ApplicationController
  SCALAR_KEYS = %w[name description source_language target_language].freeze
  ENTRY_KEYS = %w[source_term preferred_target_term note].freeze

  def panel
    render partial: "workspace_terminology/panel",
           locals: {
             glossaries: active_glossaries,
             selected_revision_id: selected_revision_id_param
           }
  end

  def new
    @form_values = default_form_values
    @form_errors = []
  end

  def create
    glossary = Glossaries::Create.call(user: current_user, attributes: create_attributes)
    render_panel(selected_revision_id: glossary.current_revision_id, status: :created)
  rescue Glossaries::BuildRevision::Error, ActiveRecord::RecordInvalid => error
    @form_values = safe_submitted_values
    @form_errors = error_messages(error)
    render :new, status: :unprocessable_content
  end

  def edit
    @glossary = owned_glossaries.find(glossary_id_param)
    @form_errors = []
    @append_entry = params[:add].to_s == "1"
  end

  def update
    @glossary = owned_glossaries.find(glossary_id_param)
    @submitted_entries = entry_attributes
    @expected_version = expected_version_param
    revision = Glossaries::Revise.call(
      glossary: @glossary,
      expected_version: @expected_version,
      attributes: revision_attributes
    )
    render_panel(selected_revision_id: revision.id, status: :ok)
  rescue Glossaries::Revise::StaleRevisionError => error
    @form_errors = [ error.message ]
    render :edit, status: :conflict
  rescue Glossaries::BuildRevision::Error, ActiveRecord::RecordInvalid => error
    @form_errors = error_messages(error)
    render :edit, status: :unprocessable_content
  end

  private

  def owned_glossaries
    current_user.glossaries.includes(current_revision: :entries)
  end

  def render_panel(selected_revision_id:, status: :ok)
    glossaries = active_glossaries
    render turbo_stream: [
      turbo_stream.replace(
        "workspace-terminology",
        partial: "workspace_terminology/panel",
        locals: { glossaries: glossaries, selected_revision_id: selected_revision_id }
      ),
      turbo_stream.update("workspace-terminology-editor", "")
    ], status: status
  end

  def active_glossaries
    current_user.glossaries.active.includes(current_revision: :entries)
      .order(updated_at: :desc, id: :desc)
  end

  def revision_attributes
    revision = @glossary.current_revision
    {
      "name" => revision.name,
      "description" => revision.description,
      "source_language" => revision.source_language,
      "target_language" => revision.target_language,
      "entries" => @submitted_entries
    }
  end

  def entry_attributes
    submitted = params.require(:glossary)
    raise ActionController::BadRequest, "glossary must be an object" unless submitted.is_a?(ActionController::Parameters)

    allowed = %w[expected_version entries]
    raise ActionController::BadRequest, "Unexpected parameters" if (submitted.keys - allowed).any?

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

    entries.map { |entry| entry.permit(*ENTRY_KEYS).to_h }
  end

  def create_attributes
    submitted = params.require(:glossary)
    raise ActionController::BadRequest, "glossary must be an object" unless submitted.is_a?(ActionController::Parameters)

    allowed = SCALAR_KEYS + [ "entries" ]
    raise ActionController::BadRequest, "Unexpected parameters" if (submitted.keys - allowed).any?
    SCALAR_KEYS.each do |key|
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

    submitted.permit(*SCALAR_KEYS, entries: ENTRY_KEYS).to_h
  end

  def default_form_values
    {
      "source_language" => params[:source_language].to_s.first(100),
      "target_language" => params[:target_language].to_s.first(100),
      "entries" => [ { "source_term" => "", "preferred_target_term" => "", "note" => "" } ]
    }
  end

  def safe_submitted_values
    submitted = params[:glossary]
    return default_form_values unless submitted.is_a?(ActionController::Parameters)

    values = submitted.to_unsafe_h.slice(*SCALAR_KEYS, "entries")
    values["entries"] = default_form_values["entries"] unless values["entries"].is_a?(Array)
    values
  end

  def glossary_id_param
    value = params[:glossary_id]
    raise ActiveRecord::RecordNotFound unless value.to_s.match?(/\A[1-9]\d*\z/)

    value
  end

  def selected_revision_id_param
    value = params[:selected_revision_id]
    return unless value.to_s.match?(/\A[1-9]\d*\z/)

    value.to_i
  end

  def expected_version_param
    params.require(:glossary).require(:expected_version)
  end

  def error_messages(error)
    return error.record.errors.full_messages if error.respond_to?(:record)

    [ error.message ]
  end
end
