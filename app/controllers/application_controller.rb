class ApplicationController < ActionController::Base
  before_action :require_authentication

  helper_method :current_user, :authenticated?

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

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
