class ApplicationController < ActionController::Base
  DEFAULT_PAGE_SIZE = 25

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  before_action :require_authentication

  helper_method :current_user, :authenticated?

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  def paginate(scope, per_page: DEFAULT_PAGE_SIZE)
    total_count = scope.count
    total_pages = [ (total_count.to_f / per_page).ceil, 1 ].max
    current_page = normalized_page(total_pages)
    @pagination = {
      current_page: current_page,
      total_pages: total_pages,
      total_count: total_count
    }
    scope.offset((current_page - 1) * per_page).limit(per_page)
  end

  def normalized_page(total_pages)
    requested = Integer(params[:page].presence || 1, 10)
    requested.clamp(1, total_pages)
  rescue ArgumentError, TypeError
    1
  end

  def render_not_found
    respond_to do |format|
      format.html { render "errors/not_found", status: :not_found }
      format.any { head :not_found }
    end
  end

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = User.active.find_by(id: session[:user_id])
  end

  def authenticated?
    current_user.present?
  end

  def require_authentication
    return if authenticated?

    reset_session if session[:user_id].present?
    session[:return_to_after_authenticating] = request.fullpath if request.get? && request.format.html?
    redirect_to login_path, alert: "Please sign in to continue."
  end

  def require_admin
    return if current_user&.admin?

    redirect_to root_path, alert: "You are not authorized to access administration settings."
  end

  def find_owned_project(id)
    return if id.blank?

    raise ActionController::BadRequest, "project_id is invalid" unless id.to_s.match?(/\A[1-9]\d*\z/)

    current_user.projects.find(id)
  end

  def start_authenticated_session!(user)
    destination = session.delete(:return_to_after_authenticating)
    reset_session
    session[:user_id] = user.id
    destination
  end

  def end_authenticated_session!
    reset_session
  end
end
