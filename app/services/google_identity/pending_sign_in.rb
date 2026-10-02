module GoogleIdentity
  # A verified Google sign-in waiting for the browser's next request. Google's
  # cross-site callback never receives the SameSite=Lax session cookie, so a
  # session started there could not end the browser's previous server session,
  # and a copy of the replaced cookie would keep authenticating. The callback
  # stores this (encrypted, short-lived, single-use) and redirects; the
  # completion is a top-level same-site GET that carries the session cookie.
  class PendingSignIn
    COOKIE = :google_identity_pending_sign_in
    COOKIE_PATH = "/auth/google/complete".freeze
    TTL = 2.minutes

    attr_reader :user_id, :preference_overrides, :return_path

    def self.store(cookies, user:, ceremony:)
      payload = {
        "n" => SecureRandom.urlsafe_base64(16), "u" => user.id, "x" => TTL.from_now.to_i,
        "o" => ceremony.preference_overrides.presence, "r" => ceremony.return_path
      }.compact
      cookies.encrypted[COOKIE] = {
        value: payload.to_json, expires: TTL.from_now, path: COOKIE_PATH,
        httponly: true, same_site: :lax, secure: Rails.env.production?
      }
    end

    # Reads and clears the cookie. Returns nil unless the pending sign-in is
    # well-formed, unexpired and used here for the first time.
    def self.take(cookies)
      payload = JSON.parse(cookies.encrypted[COOKIE].to_s)
      cookies.delete(COOKIE, path: COOKIE_PATH)
      return unless payload.is_a?(Hash) && payload["n"].is_a?(String) && payload["u"].is_a?(Integer)
      return unless payload["x"].is_a?(Integer) && payload["x"] > Time.current.to_i
      return unless Rails.cache.write("google_identity/pending_sign_in/#{payload["n"]}", true, unless_exist: true, expires_in: TTL + 1.minute)

      new(payload)
    rescue JSON::ParserError
      cookies.delete(COOKIE, path: COOKIE_PATH)
      nil
    end

    def initialize(payload)
      @user_id = payload["u"]
      @preference_overrides = UiPreferences.sanitize(payload["o"])
      @return_path = Ceremony.safe_return_path(payload["r"])
    end
  end
end
