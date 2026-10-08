module GoogleIdentity
  # Verifies a Google ID token with googleauth (signature against Google's
  # rotating keys, Google issuer, audience == our client ID, expiry) and then
  # validates the claims this application relies on.
  class TokenVerifier
    MAXIMUM_CREDENTIAL_LENGTH = 4096
    SUBJECT_PATTERN = /\A[\x21-\x7e]{1,#{FederatedIdentity::MAXIMUM_PROVIDER_UID_LENGTH}}\z/
    GMAIL_DOMAIN = "gmail.com".freeze

    Claims = Data.define(:subject, :email, :email_verified, :hosted_domain, :nonce) do
      # Google's documented rule: Google is authoritative for the address when it
      # is a Gmail address, or when it is verified and the account is a Google
      # Workspace account (hd present). Other verified addresses may no longer be
      # controlled by the Google Account owner.
      def google_authoritative_email?
        email_verified && (email.end_with?("@#{GMAIL_DOMAIN}") || hosted_domain.present?)
      end
    end

    def initialize(client_id:, key_source:)
      @client_id = client_id
      @key_source = key_source
    end

    def verify(credential)
      raise VerificationFailed, :not_configured if @client_id.blank?
      raise VerificationFailed, :malformed unless well_formed?(credential)

      claims_from(verified_payload(credential))
    end

    private

    def well_formed?(credential)
      credential.is_a?(String) && credential.length.between?(1, MAXIMUM_CREDENTIAL_LENGTH) &&
        credential.count(".") == 2
    end

    def verified_payload(credential)
      Google::Auth::IDTokens::Verifier.new(
        key_source: @key_source,
        aud: @client_id,
        iss: Google::Auth::IDTokens::OIDC_ISSUERS
      ).verify(credential)
    rescue Google::Auth::IDTokens::ExpiredTokenError
      raise VerificationFailed, :expired
    rescue Google::Auth::IDTokens::AudienceMismatchError
      raise VerificationFailed, :audience
    rescue Google::Auth::IDTokens::IssuerMismatchError
      raise VerificationFailed, :issuer
    rescue Google::Auth::IDTokens::VerificationError
      raise VerificationFailed, :signature
    rescue Google::Auth::IDTokens::KeySourceError
      raise VerificationFailed, :keys_unavailable
    rescue JWT::DecodeError, ArgumentError, TypeError
      raise VerificationFailed, :malformed
    end

    def claims_from(payload)
      subject = payload["sub"]
      email = payload["email"]
      nonce = payload["nonce"]
      raise VerificationFailed, :claims unless subject.is_a?(String) && subject.match?(SUBJECT_PATTERN)
      raise VerificationFailed, :claims unless email.is_a?(String) && email.length <= User::MAXIMUM_EMAIL_LENGTH
      raise VerificationFailed, :claims unless nonce.is_a?(String) && nonce.present?

      normalized_email = User.normalize_value_for(:email, email)
      raise VerificationFailed, :claims unless normalized_email.match?(User::EMAIL_PATTERN)

      hosted_domain = payload["hd"]
      Claims.new(
        subject: subject,
        email: normalized_email,
        email_verified: payload["email_verified"] == true,
        hosted_domain: hosted_domain.is_a?(String) ? hosted_domain.downcase : nil,
        nonce: nonce
      )
    end
  end
end
