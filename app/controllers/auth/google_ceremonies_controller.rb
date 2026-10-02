module Auth
  # Issues a fresh sign-in ceremony just before the Google button is shown, so
  # a page left open or restored from Turbo's cache never offers an expired one.
  # All context (user, locale, appearance, return path) is taken from the server.
  class GoogleCeremoniesController < ApplicationController
    RATE_LIMIT = 30
    RATE_LIMIT_WINDOW = 1.minute

    # Fetched in the background: it reads the session but must never write one,
    # or a late response could overwrite a sign-in completed meanwhile.
    before_action { request.session_options[:skip] = true }
    skip_before_action :require_authentication
    rate_limit to: RATE_LIMIT, within: RATE_LIMIT_WINDOW, by: :client_network, with: -> { head :too_many_requests }

    def create
      intent = params[:intent].to_s
      return head :not_found unless GoogleIdentity.enabled?
      return head :bad_request unless GoogleIdentity::Ceremony::INTENTS.include?(intent)
      return head :forbidden if intent == "link" && !authenticated?

      response.headers["Cache-Control"] = "no-store"
      render json: { nonce: google_identity_ceremony(intent), expires_in: GoogleIdentity::Ceremony::TTL.to_i }
    end
  end
end
