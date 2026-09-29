require "test_helper"
require_relative "../../support/google_identity_test_helper"

class GoogleIdentity::TokenVerifierTest < ActiveSupport::TestCase
  include GoogleIdentityTestHelper

  setup do
    @verifier = GoogleIdentity::TokenVerifier.new(client_id: GoogleIdentity.client_id, key_source: google_key_source)
  end

  test "accepts a Google-signed token for this client and returns only the claims it needs" do
    claims = @verifier.verify(google_id_token("email" => " Google.Person@Gmail.com ", "nonce" => "ceremony"))

    assert_equal "109876543210987654321", claims.subject
    assert_equal "google.person@gmail.com", claims.email
    assert claims.email_verified
    assert_equal "ceremony", claims.nonce
    assert claims.google_authoritative_email?
  end

  test "rejects tokens for another audience, another issuer, or past expiry" do
    assert_rejected(:audience, google_id_token("aud" => "111111111111-other.apps.googleusercontent.com"))
    assert_rejected(:issuer, google_id_token("iss" => "https://evil.example"))
    assert_rejected(:expired, google_id_token("iat" => 2.hours.ago.to_i, "exp" => 1.hour.ago.to_i))
  end

  test "rejects forged, unsigned, and malformed credentials" do
    assert_rejected(:signature, google_id_token(key: GoogleIdentityTestHelper.attacker_key))
    header, payload, = google_id_token.split(".")
    assert_rejected(:signature, "#{header}.#{payload}.")
    unsigned = [ { alg: "none", typ: "JWT" }, JSON.parse(Base64.urlsafe_decode64(payload + "=" * (-payload.length % 4))) ]
      .map { |part| Base64.urlsafe_encode64(part.to_json, padding: false) }.join(".") + "."
    assert_rejected(:signature, unsigned)
    assert_rejected(:malformed, "not-a-jwt")
    assert_rejected(:signature, "a.b.c")
    assert_rejected(:malformed, [ google_id_token ])
    assert_rejected(:malformed, "a" * (GoogleIdentity::TokenVerifier::MAXIMUM_CREDENTIAL_LENGTH + 1))
  end

  test "requires a bounded subject, a valid email, and a nonce" do
    assert_rejected(:claims, google_id_token("sub" => nil))
    assert_rejected(:claims, google_id_token("sub" => ""))
    assert_rejected(:claims, google_id_token("sub" => "1" * 256))
    assert_rejected(:claims, google_id_token("sub" => "has space"))
    assert_rejected(:claims, google_id_token("sub" => 12345))
    assert_rejected(:claims, google_id_token("email" => nil))
    assert_rejected(:claims, google_id_token("email" => "not-an-email"))
    assert_rejected(:claims, google_id_token("nonce" => nil))
  end

  test "Google is authoritative only for verified Gmail and Workspace addresses" do
    workspace = @verifier.verify(google_id_token("email" => "person@company.example", "hd" => "company.example"))
    third_party = @verifier.verify(google_id_token("email" => "person@elsewhere.example"))
    unverified = @verifier.verify(google_id_token("email_verified" => false))
    stringly = @verifier.verify(google_id_token("email_verified" => "true", "email" => "person@elsewhere.example"))

    assert workspace.google_authoritative_email?
    assert_not third_party.google_authoritative_email?
    assert_not unverified.google_authoritative_email?
    assert_not stringly.google_authoritative_email?
  end

  test "reports unavailable Google keys and missing configuration without leaking details" do
    unavailable = Object.new
    def unavailable.current_keys = []
    def unavailable.refresh_keys = raise(Google::Auth::IDTokens::KeySourceError, "network detail")

    error = assert_raises(GoogleIdentity::VerificationFailed) do
      GoogleIdentity::TokenVerifier.new(client_id: GoogleIdentity.client_id, key_source: unavailable).verify(google_id_token)
    end
    assert_equal :keys_unavailable, error.category
    assert_not_includes error.message, "network detail"

    error = assert_raises(GoogleIdentity::VerificationFailed) do
      GoogleIdentity::TokenVerifier.new(client_id: nil, key_source: google_key_source).verify(google_id_token)
    end
    assert_equal :not_configured, error.category
  end

  test "the application verifier checks this application's configured client ID" do
    assert_equal "000000000000-threeheavenstest.apps.googleusercontent.com", GoogleIdentity.client_id
    assert_equal GoogleIdentity.client_id, GoogleIdentity.verifier.instance_variable_get(:@client_id)
    assert_kind_of GoogleIdentity::SigningKeySource, GoogleIdentity.verifier.instance_variable_get(:@key_source)
  end

  private

  def assert_rejected(category, credential)
    error = assert_raises(GoogleIdentity::VerificationFailed) { @verifier.verify(credential) }
    assert_equal category, error.category, "credential: #{credential.to_s.first(40)}"
    assert_no_match(/eyJ|google\.person/, error.message)
  end
end
