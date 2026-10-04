class ApplicationController < ActionController::Base
  DEFAULT_PAGE_SIZE = 25

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  # The locale wraps every other callback, so messages produced before an
  # action (such as the sign-in redirect) use the visitor's language rather
  # than whatever locale the serving thread was left with.
  around_action :with_locale
  before_action :reject_null_bytes
  before_action :require_authentication

  helper_method :current_user, :authenticated?, :current_appearance, :current_appearance_revision

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  # The rate-limit key for the client. request.remote_ip is the nearest address
  # the trusted proxies appended to X-Forwarded-For, which a client cannot
  # choose behind kamal-proxy and Thruster. An IPv6 client usually controls a
  # whole /64, so IPv6 addresses share their /64's budget.
  def client_network
    address = IPAddr.new(request.remote_ip.to_s).native
    address.ipv6? ? "#{address.mask(64)}/64" : address.to_s
  rescue IPAddr::Error
    request.remote_ip.to_s
  end

  # PostgreSQL text cannot hold U+0000 and its driver raises when asked to
  # send one, so a parameter containing it is malformed input (400) rather
  # than a server error wherever it would have reached a query.
  def reject_null_bytes
    raise ActionController::BadRequest, "Parameters contain a null byte" if contains_null_byte?(request.parameters)
  end

  def contains_null_byte?(value)
    case value
    when String then value.include?("\0")
    when Hash then value.any? { |key, nested| contains_null_byte?(key) || contains_null_byte?(nested) }
    when Array then value.any? { |nested| contains_null_byte?(nested) }
    else false
    end
  end

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

  def current_appearance_revision
    ui_preferences.appearance_revision
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

    @current_user = User.active.where.not(email_verified_at: nil).joins(:sessions).merge(Session.unexpired)
                        .find_by(sessions: { id: session[:authentication_session_id] })
  end

  def authenticated?
    current_user.present?
  end

  def require_authentication
    return if authenticated?

    # session[:user_id] is a pre-v1.1 cookie; clearing it keeps a rollback
    # from authenticating it again.
    reset_session if session[:authentication_session_id].present? || session[:user_id].present?
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
  # before the first signed-in page renders. The browser's previous server
  # session, if any, ends with its cookie, so a copy of that cookie cannot
  # authenticate after the new one is issued. Returns false, changing
  # nothing, if the account was disabled after it was authenticated;
  # otherwise the stored return path, if any.
  def start_authenticated_session!(user, preference_overrides: ui_preferences.pending_overrides)
    server_session = Session.start(user)
    return false unless server_session

    ui_preferences.apply_at_sign_in(user, preference_overrides)
    destination = session.delete(:return_to_after_authenticating)
    delete_server_session
    reset_session
    session[:authentication_session_id] = server_session.id
    SignInThrottle.remember_device(cookies, user)
    destination
  end

  # The display cookies already hold the account's preferences (written at
  # sign-in and on every change), so signing out keeps the same look without
  # rewriting them from a user that a still-saving change may have outdated.
  # Only this browser's server session ends; other devices stay signed in.
  def end_authenticated_session!
    delete_server_session
    reset_session
    GoogleIdentity::PendingLink.clear(cookies)
  end

  def delete_server_session
    session_id = session[:authentication_session_id]
    Session.where(id: session_id).delete_all if session_id
  end
end
