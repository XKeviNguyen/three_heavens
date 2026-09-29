require "test_helper"
require_relative "../../support/google_identity_test_helper"

class GoogleIdentity::AccountRulesTest < ActiveSupport::TestCase
  include GoogleIdentityTestHelper
  include ActionMailer::TestHelper

  setup do
    @ceremony = GoogleIdentity::Ceremony.resolve(GoogleIdentity::Ceremony.issue(intent: "sign_in", locale: "ja", appearance: "dark"))
  end

  test "a new Gmail identity creates a verified ordinary user with safe defaults" do
    result = nil
    assert_difference [ "User.count", "FederatedIdentity.count" ], 1 do
      assert_no_enqueued_emails { result = sign_in(google_claims(nonce: "n")) }
    end

    user = result.user
    assert result.signed_in?
    assert_equal [ "google.person@gmail.com", "user", "active", false, "ja", "dark" ],
                 [ user.email, user.role, user.status, user.managed_ai_access, user.locale, user.appearance ]
    assert user.email_verified?
    assert_not user.password_sign_in?
    assert_equal [ [ "google", "109876543210987654321" ] ], user.federated_identities.pluck(:provider, :provider_uid)
  end

  test "only addresses Google is authoritative for can create an account" do
    assert sign_in(google_claims(subject: "1", email: "person@company.example", hosted_domain: "company.example", nonce: "n")).signed_in?

    [ google_claims(subject: "2", email: "person@elsewhere.example", nonce: "n"),
      google_claims(subject: "3", email: "unverified@gmail.com", email_verified: false, nonce: "n") ].each do |claims|
      assert_no_difference [ "User.count", "FederatedIdentity.count" ] do
        assert_no_enqueued_emails { assert_equal :email_not_authoritative, sign_in(claims).status }
      end
    end
  end

  test "a linked identity with a third-party email still signs in its verified owner" do
    users(:normal).federated_identities.create!(provider: "google", provider_uid: "linked-sub")
    assert sign_in(google_claims(subject: "linked-sub", email: "person@elsewhere.example", nonce: "n")).signed_in?
  end

  test "a known identity signs in its own user even after the Google email changes" do
    user = users(:normal)
    user.federated_identities.create!(provider: "google", provider_uid: "known-sub")

    result = assert_no_difference("User.count") { sign_in(google_claims(subject: "known-sub", email: "renamed@gmail.com", nonce: "n")) }
    assert_equal user, result.user
    assert_equal "user@example.test", user.reload.email
  end

  test "Google never overrides a disabled account" do
    user = users(:normal)
    user.federated_identities.create!(provider: "google", provider_uid: "disabled-sub")
    user.update!(status: :disabled)

    assert_equal :disabled, sign_in(google_claims(subject: "disabled-sub", nonce: "n")).status
  end

  test "an existing email is never linked automatically" do
    assert_no_difference [ "User.count", "FederatedIdentity.count" ] do
      assert_equal :email_taken, sign_in(google_claims(subject: "new-sub", email: users(:normal).email, nonce: "n")).status
    end
    assert_not users(:normal).federated_identities.exists?
  end

  test "the provider subject is unique across users" do
    users(:normal).federated_identities.create!(provider: "google", provider_uid: "shared-sub")
    duplicate = users(:other).federated_identities.build(provider: "google", provider_uid: "shared-sub")

    assert_not duplicate.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
    assert_raises(ActiveRecord::StatementInvalid) do
      FederatedIdentity.insert_all!([ { user_id: users(:other).id, provider: "github", provider_uid: "x", created_at: Time.current, updated_at: Time.current } ])
    end
  end

  test "linking attaches only to the signed-in user who started it" do
    owner = users(:normal)
    pending = GoogleIdentity::PendingLink.new(user_id: owner.id, subject: "link-sub", email: "owner@gmail.com")

    assert_equal :expired, GoogleIdentity::Link.call(user: users(:other), pending: pending)
    assert_equal :expired, GoogleIdentity::Link.call(user: owner, pending: nil)
    assert_equal :connected, GoogleIdentity::Link.call(user: owner, pending: pending)
    assert_equal :already_connected, GoogleIdentity::Link.call(user: owner, pending: pending)

    other_pending = GoogleIdentity::PendingLink.new(user_id: users(:other).id, subject: "link-sub", email: "owner@gmail.com")
    assert_equal :taken, GoogleIdentity::Link.call(user: users(:other), pending: other_pending)
    second = GoogleIdentity::PendingLink.new(user_id: owner.id, subject: "second-sub", email: "second@gmail.com")
    assert_equal :other_connected, GoogleIdentity::Link.call(user: owner, pending: second)
    assert_equal [ "link-sub" ], owner.federated_identities.pluck(:provider_uid)
  end

  test "disconnect keeps at least one way to sign in" do
    password_user = users(:normal)
    password_user.federated_identities.create!(provider: "google", provider_uid: "pw-sub")
    assert_equal :disconnected, GoogleIdentity::Disconnect.call(user: password_user)
    assert_equal :not_connected, GoogleIdentity::Disconnect.call(user: password_user)

    google_only = sign_in(google_claims(subject: "only-sub", email: "only@gmail.com", nonce: "n")).user
    assert_equal :only_sign_in_method, GoogleIdentity::Disconnect.call(user: google_only)
    assert google_only.federated_identities.exists?
  end

  test "a Google-only account refuses every password and still pays for a bcrypt comparison" do
    user = sign_in(google_claims(subject: "timing-sub", email: "timing@gmail.com", nonce: "n")).user
    assert BCrypt::Password.valid_hash?(User.timing_equalizer_digest)
    assert_equal false, user.authenticate_password("")
    assert_equal false, user.authenticate_password("anything at all")
    assert_nil User.authenticate_by_email(email: "timing@gmail.com", password: "anything at all")
  end

  test "a passwordless account is invalid without a federated identity" do
    user = User.new(email: "nobody@example.test", locale: "en")
    assert_not user.valid?
    assert user.errors.added?(:password, :blank)

    user.federated_identities.build(provider: "google", provider_uid: "sub")
    assert user.valid?
  end

  private

  def sign_in(claims)
    GoogleIdentity::SignIn.call(claims: claims, ceremony: @ceremony)
  end
end
