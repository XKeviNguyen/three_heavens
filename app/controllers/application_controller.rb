class ApplicationController < ActionController::Base
  DEFAULT_PAGE_SIZE = 25

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  # The locale wraps every other callback, so messages produced before an
  # action (such as the sign-in redirect) use the visitor's language rather
  # than whatever locale the serving thread was left with.
  around_action :with_locale
  before_action :require_authentication

  helper_method :current_user, :authenticated?, :current_appearance

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  def with_locale(&action)
    I18n.with_locale(current_user&.locale || preferred_public_locale, &action)
  end

  def ui_preferences
    @ui_preferences ||= UiPreferences.new(cookies)
  end

  def preferred_public_locale
    return ui_preferences.locale if ui_preferences.locale

    request.headers["Accept-Language"].to_s.split(",").each do |part|
      language = part.split(";", 2).first.to_s.strip.downcase.split("-", 2).first
      return language if User::SUPPORTED_LOCALES.include?(language)
    end
    "en"
  end

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
    I18n.with_locale(current_user&.locale || preferred_public_locale) do
      respond_to do |format|
        format.html { render "errors/not_found", status: :not_found }
        format.any { head :not_found }
      end
    end
  end

  def current_appearance
    return current_user.appearance if current_user

    ui_preferences.appearance || "system"
  end

  def google_identity_ceremony(intent)
    GoogleIdentity::Ceremony.issue(
      intent: intent,
      user: (current_user if intent == "link"),
      locale: I18n.locale,
      appearance: current_appearance,
      preference_overrides: (ui_preferences.pending_overrides if intent == "sign_in"),
      return_path: session[:return_to_after_authenticating]
    )
  end

  # Returns to the page the form was on: its explicit return_to (needed on
  # no-referrer pages such as email confirmation), else a same-host Referer,
  # else home. Both candidates go through SafeReturnPath.
  def redirect_back_to_same_origin
    path = SafeReturnPath.call(params[:return_to]) || same_origin_referer_path || root_path
    redirect_to path, allow_other_host: false, status: :see_other
  end

  def same_origin_referer_path
    uri = URI.parse(request.referer.to_s)
    SafeReturnPath.call(uri.request_uri) if uri.host == request.host && uri.port == request.port
  rescue URI::InvalidURIError
    nil
  end

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = User.active.where.not(email_verified_at: nil).find_by(id: session[:user_id])
  end

  def authenticated?
    current_user.present?
  end

  def require_authentication
    return if authenticated?

    reset_session if session[:user_id].present?
    session[:return_to_after_authenticating] = request.fullpath if request.get? && request.format.html?
    redirect_to login_path, alert: I18n.t("authentication.sign_in_required")
  end

  def require_managed_ai_access
    return if Ai::ManagedAccess.allowed?(current_user)

    redirect_to new_translation_workspace_path, alert: I18n.t("managed_ai.unavailable")
  end

  def require_admin
    return if current_user&.admin?

    redirect_to root_path, alert: I18n.t("authentication.admin_required")
  end

  def localized_retry_notice(result, kind:)
    base = "retry_feedback.#{kind}"
    return I18n.t("#{base}.none") if result.retried_count.zero?

    failed_count = result.retried_count - result.enqueued_count
    return I18n.t("#{base}.queue_failed") if result.enqueued_count.zero?
    if failed_count.positive?
      return I18n.t("#{base}.partial", queued: result.enqueued_count, failed: failed_count)
    end

    I18n.t("#{base}.queued", count: result.retried_count)
  end

  def find_owned_project(id)
    return if id.blank?

    raise ActionController::BadRequest, "project_id is invalid" unless id.to_s.match?(/\A[1-9]\d*\z/)

    current_user.projects.find(id)
  end

  # Every sign-in (password or Google) reconciles interface preferences here,
  # before the first signed-in page renders.
  def start_authenticated_session!(user, preference_overrides: ui_preferences.pending_overrides)
    ui_preferences.apply_at_sign_in(user, preference_overrides)
    destination = session.delete(:return_to_after_authenticating)
    reset_session
    session[:user_id] = user.id
    destination
  end

  def end_authenticated_session!
    ui_preferences.mirror(current_user) if current_user
    reset_session
    GoogleIdentity::PendingLink.clear(cookies)
  end
end
