module GoogleIdentity
  # Carries a Google sign-in or linking outcome to the next page without the
  # Rails session. Google's cross-site callback never receives the SameSite=Lax
  # session cookie, so writing a session there would replace (sign out) the
  # visitor's real one. Only allowlisted codes travel; messages render later
  # in the visitor's own locale.
  module Notice
    COOKIE = :google_identity_notice
    CODES = %w[failed link_failed unavailable rate_limited email_taken email_not_authoritative confirmation_required].freeze

    def self.store(cookies, code)
      cookies.signed[COOKIE] = {
        value: code.to_s.presence_in(CODES) || "failed", expires: 1.minute.from_now,
        httponly: true, same_site: :lax, secure: Rails.env.production?
      }
    end

    def self.take(cookies)
      return unless cookies[COOKIE]

      code = cookies.signed[COOKIE].to_s.presence_in(CODES)
      cookies.delete(COOKIE)
      code
    end
  end
end
