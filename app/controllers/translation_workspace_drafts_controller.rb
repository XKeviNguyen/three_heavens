class TranslationWorkspaceDraftsController < ApplicationController
  REQUEST_KEYS = %w[controller action format authenticity_token project_id draft_id version workspace translation_workspace_draft].freeze

  before_action :set_no_store
  before_action :validate_request_shape

  def create
    project = find_owned_project(params[:project_id])
    context_key = TranslationWorkspaceDraft.context_key(project)
    payload = draft_payload
    supplied_id = params[:draft_id]
    supplied_version = params[:version]

    if supplied_id.present?
      draft = current_user.translation_workspace_drafts.current.find_by!(public_id: supplied_id, context_key:)
      raise ActionController::BadRequest unless supplied_version.to_s.match?(/\A\d+\z/)

      draft.with_lock do
        return render_conflict(draft) unless draft.lock_version == supplied_version.to_i

        draft.update!(workspace_payload: JSON.generate(payload), expires_at: Time.current + TranslationWorkspaceDraft::RETENTION)
      end
    else
      current_user.translation_workspace_drafts.where(context_key:, expires_at: ..Time.current).delete_all
      return render_conflict if current_user.translation_workspace_drafts.current.exists?(context_key:)

      draft = current_user.translation_workspace_drafts.create!(
        context_key:,
        workspace_payload: JSON.generate(payload),
        expires_at: Time.current + TranslationWorkspaceDraft::RETENTION
      )
    end

    render json: { id: draft.public_id, version: draft.lock_version, saved_at: draft.updated_at.iso8601 }
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
    render_conflict
  rescue ArgumentError, ActionController::ParameterMissing, ActionController::BadRequest
    head :bad_request
  end

  def destroy
    project = find_owned_project(params[:project_id])
    draft = current_user.translation_workspace_drafts.current.find_by!(
      public_id: params[:draft_id], context_key: TranslationWorkspaceDraft.context_key(project)
    )
    raise ActionController::BadRequest unless params[:version].to_s.match?(/\A\d+\z/)

    draft.with_lock do
      return render_conflict(draft) unless draft.lock_version == params[:version].to_i

      draft.destroy!
    end
    head :no_content
  rescue ActiveRecord::StaleObjectError
    render_conflict
  end

  private

  def validate_request_shape
    raise ActionController::BadRequest if (params.keys - REQUEST_KEYS).any?
    raise ActionController::BadRequest unless params[:project_id].nil? || params[:project_id].is_a?(String)
    raise ActionController::BadRequest unless params[:draft_id].nil? || params[:draft_id].is_a?(String)
    unless params[:version].nil? || params[:version].is_a?(String) || params[:version].is_a?(Integer)
      raise ActionController::BadRequest
    end
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
