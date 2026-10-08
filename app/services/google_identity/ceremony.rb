module GoogleIdentity
  # Server-signed context for one Sign in with Google attempt, sent to Google as
  # the ID-token nonce and returned inside the Google-signed credential.
  #
  # Google posts the credential cross-site, so the SameSite=Lax session cookie is
  # not available in the callback. The ceremony carries what the callback needs
  # (intent, the linking user, interface preferences, a safe return path) and
  # binds the credential to a sign-in page this server rendered. It is single-use.
  class Ceremony
    INTENTS = %w[sign_in link].freeze
    TTL = 10.minutes
    PURPOSE = :google_identity_ceremony
    MAXIMUM_RETURN_PATH_LENGTH = 200

    attr_reader :id, :intent, :user_id, :locale, :appearance, :preference_overrides, :return_path

    # locale/appearance are the page's effective values (initial preferences
    # for a new account); preference_overrides are only the values the visitor
    # explicitly chose while signed out, which an existing account adopts.
    def self.issue(intent:, locale:, appearance:, user: nil, preference_overrides: nil, return_path: nil)
      raise ArgumentError, "unknown intent" unless INTENTS.include?(intent)
      raise ArgumentError, "linking requires a user" if intent == "link" && user.nil?

      payload = {
        "n" => SecureRandom.urlsafe_base64(16),
        "i" => intent,
        "u" => user&.id,
        "l" => locale.to_s,
        "a" => appearance.to_s,
        "o" => UiPreferences.sanitize(preference_overrides).presence,
        "r" => safe_return_path(return_path)
      }.compact
      verifier.generate(payload, expires_in: TTL, purpose: PURPOSE)
    end

    def self.resolve(token)
      payload = verifier.verified(token.to_s, purpose: PURPOSE)
      new(payload) if payload.is_a?(Hash) && valid_payload?(payload)
    end

    # The shared validation, with a tighter length so the nonce stays small.
    def self.safe_return_path(path)
      SafeReturnPath.call(path) if path.to_s.length <= MAXIMUM_RETURN_PATH_LENGTH
    end

    def self.valid_payload?(payload)
      payload["n"].is_a?(String) && INTENTS.include?(payload["i"]) &&
        (payload["i"] != "link" || payload["u"].is_a?(Integer))
    end

    def self.verifier
      Rails.application.message_verifier(PURPOSE)
    end
    private_class_method :verifier, :valid_payload?

    def initialize(payload)
      @id = payload["n"]
      @intent = payload["i"]
      @user_id = payload["u"]
      @locale = payload["l"].presence_in(User::SUPPORTED_LOCALES)
      @appearance = payload["a"].presence_in(User::APPEARANCES)
      @preference_overrides = UiPreferences.sanitize(payload["o"])
      @return_path = self.class.safe_return_path(payload["r"])
    end

    def link?
      intent == "link"
    end

    # True only for the first caller; a replayed credential carries a used nonce.
    def consume!
      ConsumedNonce.consume("google_identity/ceremony", id, expires_at: TTL.from_now)
    end
  end
end
