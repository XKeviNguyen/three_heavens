class TranslationWorkspaceDraftsController < ApplicationController
  REQUEST_KEYS = %w[
    controller action format authenticity_token project_id draft_id version editor_id sequence
    workspace translation_workspace_draft
  ].freeze

  before_action :set_no_store
  before_action :validate_request_shape

  def create
    project = find_owned_project(params[:project_id])
    result = TranslationWorkspaceDrafts::Save.call(
      user: current_user,
      context_key: TranslationWorkspaceDraft.context_key(project),
      payload: draft_payload,
      draft_id: params[:draft_id],
      version: supplied_version,
      **editor_identity
    )
    return render_conflict(result.draft) if result.conflict?

    draft = result.draft
    render json: { id: draft.public_id, version: draft.lock_version, sequence: draft.editor_sequence,
                   saved_at: draft.updated_at.iso8601 }
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
    render_conflict
  rescue ArgumentError, ActionController::ParameterMissing, ActionController::BadRequest
    head :bad_request
  end

  # Discarding is idempotent: nothing to discard succeeds, and the editor that
  # wrote the draft last may discard it without knowing its latest version.
  def destroy
    project = find_owned_project(params[:project_id])
    identity = params[:sequence].present? ? editor_identity(allow_zero: true) : { editor_id: params[:editor_id].presence }
    conflict = TranslationWorkspaceDrafts::Discard.call(
      user: current_user, context_key: TranslationWorkspaceDraft.context_key(project),
      draft_id: params[:draft_id], version: params[:version].nil? ? nil : supplied_version, **identity
    )
    conflict ? render_conflict(conflict) : head(:no_content)
  rescue ActiveRecord::StaleObjectError
    render_conflict
  rescue ArgumentError, ActionController::BadRequest
    head :bad_request
  end

  private

  def validate_request_shape
    raise ActionController::BadRequest if (params.keys - REQUEST_KEYS).any?
    %i[project_id draft_id editor_id].each do |key|
      raise ActionController::BadRequest unless params[key].nil? || params[key].is_a?(String)
    end
    %i[version sequence].each do |key|
      raise ActionController::BadRequest unless params[key].nil? || params[key].is_a?(String) || params[key].is_a?(Integer)
    end
    if params[:editor_id].present? && !params[:editor_id].match?(TranslationWorkspaceDraft::EDITOR_ID_FORMAT)
      raise ActionController::BadRequest
    end
  end

  # A version is only meaningful together with the draft identity it names.
  def supplied_version
    return if params[:draft_id].blank?
    raise ActionController::BadRequest unless params[:version].to_s.match?(/\A\d{1,9}\z/)

    params[:version].to_i
  end

  def editor_identity(allow_zero: false)
    return {} if params[:editor_id].blank? && params[:sequence].blank?
    pattern = allow_zero ? /\A(?:0|[1-9]\d{0,15})\z/ : /\A[1-9]\d{0,15}\z/
    raise ActionController::BadRequest if params[:editor_id].blank? || !params[:sequence].to_s.match?(pattern)

    sequence = params[:sequence].to_i
    raise ActionController::BadRequest if sequence > TranslationWorkspaceDraft::MAX_EDITOR_SEQUENCE

    { editor_id: params[:editor_id], sequence: }
  end

  def draft_payload
    submitted = params.require(:workspace)
    raise ActionController::BadRequest unless submitted.is_a?(ActionController::Parameters)

    TranslationWorkspaceDraft.validate_payload!(submitted.to_unsafe_h)
  end

  def render_conflict(draft = nil)
    render json: { error: "This draft was changed in another tab. Reload to see the newer version.",
                   version: draft&.lock_version }, status: :conflict
  end

  def set_no_store
    response.headers["Cache-Control"] = "no-store"
  end
end
