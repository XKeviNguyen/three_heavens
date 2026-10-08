module GoogleIdentity
  # A verified Google identity waiting for its signed-in owner to confirm the
  # connection. Google's cross-site callback cannot see the session, so the
  # callback stores this (encrypted, short-lived) and the account page completes
  # the link through a same-origin, CSRF-protected request bound to current_user.
  class PendingLink
    COOKIE = :google_identity_pending_link
    COOKIE_PATH = "/settings/account".freeze
    TTL = 5.minutes

    attr_reader :user_id, :subject, :email

    def self.store(cookies, user_id:, claims:)
      payload = { "u" => user_id, "s" => claims.subject, "e" => claims.email, "x" => TTL.from_now.to_i }
      cookies.encrypted[COOKIE] = {
        value: payload.to_json, expires: TTL.from_now, path: COOKIE_PATH,
        httponly: true, same_site: :lax, secure: Rails.env.production?
      }
    end

    def self.fetch(cookies)
      payload = JSON.parse(cookies.encrypted[COOKIE].to_s)
      return unless payload.is_a?(Hash) && payload["x"].is_a?(Integer) && payload["x"] > Time.current.to_i
      return unless payload["u"].is_a?(Integer) && payload["s"].is_a?(String) && payload["e"].is_a?(String)

      new(user_id: payload["u"], subject: payload["s"], email: payload["e"])
    rescue JSON::ParserError
      nil
    end

    # Written unconditionally: cookies.delete is a no-op when the request did not
    # carry the cookie, which is always the case outside COOKIE_PATH (e.g. sign-out).
    def self.clear(cookies)
      cookies[COOKIE] = { value: "", expires: Time.at(0), path: COOKIE_PATH, httponly: true, same_site: :lax, secure: Rails.env.production? }
    end

    def initialize(user_id:, subject:, email:)
      @user_id = user_id
      @subject = subject
      @email = email
    end

    def for?(user)
      user.present? && user.id == user_id
    end
  end
end
