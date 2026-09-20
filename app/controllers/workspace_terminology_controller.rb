class WorkspaceTerminologyController < ApplicationController
  ENTRY_KEYS = %w[source_term preferred_target_term note].freeze

  def panel
    render_panel(selected_revision_id: selected_revision_id_param)
  end

  def edit
    @glossary = owned_glossaries.find(glossary_id_param)
    @form_errors = []
  end

  def update
    @glossary = owned_glossaries.find(glossary_id_param)
    revision = Glossaries::Revise.call(
      glossary: @glossary,
      expected_version: expected_version_param,
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
    glossaries = current_user.glossaries.active.includes(current_revision: :entries)
      .order(updated_at: :desc, id: :desc)
    render turbo_stream: turbo_stream.replace(
      "workspace-terminology",
      partial: "workspace_terminology/panel",
      locals: { glossaries: glossaries, selected_revision_id: selected_revision_id }
    ), status: status
  end

  def revision_attributes
    revision = @glossary.current_revision
    {
      "name" => revision.name,
      "description" => revision.description,
      "source_language" => revision.source_language,
      "target_language" => revision.target_language,
      "entries" => entry_attributes
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
    end

    entries.map { |entry| entry.permit(*ENTRY_KEYS).to_h }
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
