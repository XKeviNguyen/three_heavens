# Sign in with Google (Google Identity Services, ID-token sign-in). This module
# authenticates identity only: it never requests Google API scopes, never uses
# a client secret, and never stores Google tokens.
module GoogleIdentity
  PROVIDER = "google".freeze
  CLIENT_ID_PATTERN = /\A[0-9]+-[0-9a-z]+\.apps\.googleusercontent\.com\z/

  # Raised for any credential that must not authenticate. The category is safe
  # to log; library messages are not, because they can echo token claims.
  class VerificationFailed < StandardError
    attr_reader :category

    def initialize(category)
      @category = category
      super("Google credential rejected (#{category})")
    end
  end

  class << self
    attr_writer :verifier

    def client_id
      configured = Rails.configuration.x.google_identity.client_id.to_s
      configured if configured.match?(CLIENT_ID_PATTERN)
    end

    def enabled?
      client_id.present?
    end

    def verifier
      @verifier ||= TokenVerifier.new(client_id: client_id, key_source: SigningKeySource.new)
    end
  end
end
