require "openssl"

# Builds real RS256 Google-shaped ID tokens signed by local test keys, and fake
# verifiers for controller tests. Nothing here contacts Google.
module GoogleIdentityTestHelper
  TEST_KEY_ID = "three-heavens-test-key".freeze

  # Stands in for the Google verifier in controller and system tests.
  class FakeVerifier
    attr_reader :credentials

    def initialize(claims: nil, error: nil)
      @claims = claims
      @error = error
      @credentials = []
    end

    def verify(credential)
      @credentials << credential
      raise GoogleIdentity::VerificationFailed, @error if @error

      @claims
    end
  end

  def self.google_key
    @google_key ||= OpenSSL::PKey::RSA.generate(2048)
  end

  def self.attacker_key
    @attacker_key ||= OpenSSL::PKey::RSA.generate(2048)
  end

  def google_key_source
    key = Google::Auth::IDTokens::KeyInfo.new(id: TEST_KEY_ID, key: GoogleIdentityTestHelper.google_key.public_key, algorithm: "RS256")
    Google::Auth::IDTokens::StaticKeySource.new([ key ])
  end

  def google_id_token(key: GoogleIdentityTestHelper.google_key, kid: TEST_KEY_ID, **overrides)
    now = Time.current.to_i
    payload = {
      "iss" => "https://accounts.google.com",
      "aud" => GoogleIdentity.client_id,
      "azp" => GoogleIdentity.client_id,
      "sub" => "109876543210987654321",
      "email" => "google.person@gmail.com",
      "email_verified" => true,
      "nonce" => "test-nonce",
      "iat" => now,
      "exp" => now + 3600
    }.merge(overrides.transform_keys(&:to_s)).compact
    JWT.encode(payload, key, "RS256", { kid: kid })
  end

  def google_claims(subject: "109876543210987654321", email: "google.person@gmail.com", email_verified: true, hosted_domain: nil, nonce:)
    GoogleIdentity::TokenVerifier::Claims.new(subject:, email:, email_verified:, hosted_domain:, nonce:)
  end

  def with_google_verifier(verifier)
    original = GoogleIdentity.verifier
    GoogleIdentity.verifier = verifier
    yield verifier
  ensure
    GoogleIdentity.verifier = original
  end

  # The test environment uses a null cache store; replay protection needs a real one.
  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end
end
