module Auth
  # Receives the Sign in with Google (GIS redirect mode) credential POST.
  # Google posts cross-site, so neither the Rails authenticity token nor the
  # SameSite=Lax session cookie arrives here; Google's g_csrf_token
  # double-submit check replaces the authenticity token for this action only,
  # and the signed ceremony in the ID-token nonce replaces session context.
  # For the same reason this action never writes a session cookie unless it
  # completes a sign-in: a new cookie would replace, and so sign out, the
  # browser's existing session (e.g. a signed-in user linking Google).
  class GoogleCallbacksController < ApplicationController
    CSRF_TOKEN_NAME = "g_csrf_token".freeze
    MAXIMUM_CSRF_TOKEN_LENGTH = 256
    MAXIMUM_BODY_BYTES = RequestBodyLimit::PUBLIC_FORM_MAX_BYTES
    RATE_LIMIT = 10
    RATE_LIMIT_WINDOW = 3.minutes
    # Categories collapse to a few user-facing messages; details stay in logs.
    USER_MESSAGES = {
      email_not_authoritative: "email_not_authoritative",
      confirmation_required: "confirmation_required",
      email_taken: "email_taken",
      rate_limited: "rate_limited",
      not_configured: "unavailable",
      keys_unavailable: "unavailable"
    }.freeze

    prepend_before_action { request.session_options[:skip] = true }
    skip_before_action :require_authentication
    skip_forgery_protection only: :create
    rate_limit to: RATE_LIMIT, within: RATE_LIMIT_WINDOW, only: :create, with: -> { reject(:rate_limited) }
    before_action :reject_unexpected_request, :verify_google_csrf_token

    def create
      claims = GoogleIdentity.verifier.verify(params[:credential])
      ceremony = GoogleIdentity::Ceremony.resolve(claims.nonce)
      return reject(:ceremony) unless ceremony
      return reject(:replayed, link: ceremony.link?) unless ceremony.consume!

      I18n.with_locale(ceremony.locale || I18n.locale) do
        ceremony.link? ? stage_link(claims, ceremony) : sign_in(claims, ceremony)
      end
    rescue GoogleIdentity::VerificationFailed => error
      reject(error.category)
    end

    private

    def sign_in(claims, ceremony)
      result = GoogleIdentity::SignIn.call(claims: claims, ceremony: ceremony)
      return reject(result.status) unless result.signed_in?

      request.session_options[:skip] = false
      start_authenticated_session!(result.user)
      I18n.with_locale(result.user.locale) do
        redirect_to ceremony.return_path || new_translation_workspace_path,
                    notice: t("authentication.signed_in"), status: :see_other
      end
    end

    # Linking finishes on the account page, where the session proves which
    # user is signed in; the ceremony only records who started it.
    def stage_link(claims, ceremony)
      GoogleIdentity::PendingLink.store(cookies, user_id: ceremony.user_id, claims: claims)
      redirect_to settings_account_path, status: :see_other
    end

    def reject_unexpected_request
      return if request.media_type == "application/x-www-form-urlencoded" &&
        request.content_length.to_i.between?(1, MAXIMUM_BODY_BYTES)

      reject(:malformed_request)
    end

    def verify_google_csrf_token
      cookie_token = cookies[CSRF_TOKEN_NAME]
      body_token = params[CSRF_TOKEN_NAME]
      valid = [ cookie_token, body_token ].all? { |token| token.is_a?(String) && token.length.between?(1, MAXIMUM_CSRF_TOKEN_LENGTH) } &&
        ActiveSupport::SecurityUtils.secure_compare(cookie_token, body_token)
      reject(:csrf) unless valid
    end

    # Before the credential is verified the intent is unknown, so failures go
    # to the login page, which forwards a signed-in visitor to Account.
    def reject(category, link: false)
      Rails.logger.warn("[google_identity] #{link ? "link" : "sign-in"} rejected category=#{category}")
      GoogleIdentity::Notice.store(cookies, link ? "link_failed" : USER_MESSAGES.fetch(category, "failed"))
      redirect_to link ? settings_account_path : login_path, status: :see_other
    end
  end
end
