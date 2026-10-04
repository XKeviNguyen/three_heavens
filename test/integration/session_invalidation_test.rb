require "test_helper"
require_relative "../support/google_identity_test_helper"

class SessionInvalidationTest < ActionDispatch::IntegrationTest
  include GoogleIdentityTestHelper

  CROSS_SITE_WITHHELD = %w[_three_heavens_session ui_locale ui_appearance ui_locale_override ui_appearance_override].freeze

  test "a session cookie copied before sign-out stops authenticating after sign-out" do
    sign_in_as users(:normal)
    copied_cookie = session_cookie

    assert_cookie_authenticates copied_cookie

    sign_out
    assert_redirected_to login_path

    assert_cookie_does_not_authenticate copied_cookie
    assert_not users(:normal).sessions.exists?
  end

  test "signing out one browser leaves the account's other browsers signed in" do
    laptop = open_session
    phone = open_session
    [ laptop, phone ].each do |device|
      device.post session_path,
                  params: { session: { email: "user@example.test", password: "correct horse battery staple" } },
                  headers: { "REMOTE_ADDR" => "2001:db8::1" }
      device.assert_redirected_to new_translation_workspace_path
    end
    assert_equal 2, users(:normal).sessions.count

    laptop.delete session_path

    laptop.get history_path
    laptop.assert_redirected_to login_path
    phone.get history_path
    phone.assert_response :success
    assert_equal 1, users(:normal).sessions.count
  end

  test "signing in again rotates the cookie and ends the replaced server session" do
    sign_in_as users(:normal)
    first_cookie = session_cookie

    sign_in_as users(:other)

    assert_not_equal first_cookie, session_cookie
    assert_equal users(:other).id, signed_in_user_id
    assert_not users(:normal).sessions.exists?
    assert_cookie_does_not_authenticate first_cookie
  end

  test "a cookie whose server session is gone is cleared on the next request" do
    sign_in_as users(:normal)
    users(:normal).sessions.delete_all

    get history_path

    assert_redirected_to login_path
    assert_nil session[:authentication_session_id]
  end

  test "a disabled account's sessions end and do not return when it is re-enabled" do
    sign_in_as users(:normal)
    copied_cookie = session_cookie

    users(:normal).update!(status: "disabled")
    get history_path
    assert_redirected_to login_path
    assert_not users(:normal).sessions.exists?

    users(:normal).update!(status: "active")
    assert_cookie_does_not_authenticate copied_cookie
  end

  test "a session stops authenticating once its lifetime has passed" do
    sign_in_as users(:normal)
    copied_cookie = session_cookie

    travel(Session::LIFETIME - 1.minute) { assert_cookie_authenticates copied_cookie }
    travel(Session::LIFETIME + 1.minute) { assert_cookie_does_not_authenticate copied_cookie }
  end

  test "Google sign-in in a signed-in browser ends the session it replaces" do
    users(:normal).federated_identities.create!(provider: "google", provider_uid: "replacing-sub")
    sign_in_as users(:normal)
    password_session_cookie = session_cookie

    google_sign_in_cross_site(subject: "replacing-sub")

    assert_redirected_to new_translation_workspace_path
    assert_equal users(:normal).id, signed_in_user_id
    assert_equal 1, users(:normal).sessions.count
    assert_cookie_does_not_authenticate password_session_cookie

    sign_out
    assert_not users(:normal).sessions.exists?
    assert_cookie_does_not_authenticate password_session_cookie
  end

  test "a ceremony minted before a password sign-in still ends that session when Google completes" do
    users(:normal).federated_identities.create!(provider: "google", provider_uid: "stale-sub")
    stale_ceremony = mint_sign_in_ceremony
    sign_in_as users(:normal)
    password_session_cookie = session_cookie

    google_sign_in_cross_site(subject: "stale-sub", ceremony: stale_ceremony)

    assert_equal 1, users(:normal).sessions.count
    assert_cookie_does_not_authenticate password_session_cookie
  end

  test "a sign-in that the account's disabling overtakes leaves no session for a later re-enable" do
    with_account_disabled_after_password_check(users(:normal)) do
      post session_path, params: { session: { email: "user@example.test", password: "correct horse battery staple" } },
                         headers: { "REMOTE_ADDR" => "203.0.113.70" }
    end
    assert_response :unprocessable_content
    copied_cookie = session_cookie

    assert_not users(:normal).sessions.exists?
    users(:normal).update!(status: "active")
    assert_cookie_does_not_authenticate copied_cookie
  end

  test "a pending Google sign-in completes once, before it expires, and only for an active account" do
    users(:normal).federated_identities.create!(provider: "google", provider_uid: "pending-sub")

    google_sign_in_cross_site(subject: "pending-sub", complete: false)
    pending_cookie = cookies["google_identity_pending_sign_in"]
    get google_identity_completion_path
    assert_redirected_to new_translation_workspace_path
    sign_out

    cookies["google_identity_pending_sign_in"] = pending_cookie
    get google_identity_completion_path
    assert_redirected_to login_path
    assert_nil signed_in_user_id

    google_sign_in_cross_site(subject: "pending-sub", complete: false)
    travel(GoogleIdentity::PendingSignIn::TTL + 1.second) { get google_identity_completion_path }
    assert_redirected_to login_path
    assert_nil signed_in_user_id

    google_sign_in_cross_site(subject: "pending-sub", complete: false)
    users(:normal).update!(status: "disabled")
    get google_identity_completion_path
    assert_redirected_to login_path
    assert_nil signed_in_user_id
    assert_not users(:normal).sessions.exists?

    get google_identity_completion_path
    assert_redirected_to login_path
  end

  test "reaching the Google completion without a pending sign-in keeps a signed-in visitor signed in" do
    sign_in_as users(:normal)

    get google_identity_completion_path

    assert_redirected_to new_translation_workspace_path
    assert_equal "Google sign-in could not be completed. Please try again.", flash[:alert]
    assert_equal users(:normal).id, signed_in_user_id
  end

  test "a pre-v1.1 user_id session cookie does not authenticate and is cleared" do
    legacy_jar = ActionDispatch::Request.new(Rails.application.env_config.dup).cookie_jar
    legacy_jar.encrypted[session_cookie_name] = { value: { "session_id" => SecureRandom.hex(16), "user_id" => users(:normal).id } }
    cookies[session_cookie_name] = legacy_jar[session_cookie_name]

    get history_path

    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  test "the cleanup job deletes only expired sessions" do
    expired = users(:normal).sessions.create!(created_at: (Session::LIFETIME + 1.hour).ago)
    current = users(:normal).sessions.create!

    SessionCleanupJob.perform_now

    assert_not Session.exists?(expired.id)
    assert Session.exists?(current.id)
  end

  private

  # The password check passes, then an administrator's disable commits
  # before the session row is written.
  def with_account_disabled_after_password_check(user)
    original = User.method(:authenticate_by_email)
    User.define_singleton_method(:authenticate_by_email) do |**credentials|
      original.call(**credentials).tap { User.find(user.id).update!(status: "disabled") }
    end
    yield
  ensure
    User.singleton_class.define_method(:authenticate_by_email, original.unbind)
  end

  def session_cookie
    cookies[session_cookie_name]
  end

  def assert_cookie_authenticates(cookie_value)
    replay = replay_session(cookie_value)
    replay.get history_path
    replay.assert_response :success
  end

  def assert_cookie_does_not_authenticate(cookie_value)
    replay = replay_session(cookie_value)
    replay.get history_path
    replay.assert_redirected_to login_path
  end

  def replay_session(cookie_value)
    open_session.tap { |replay| replay.cookies[session_cookie_name] = cookie_value }
  end

  def session_cookie_name
    Rails.application.config.session_options.fetch(:key)
  end

  def mint_sign_in_ceremony
    post google_identity_ceremony_path, params: { intent: "sign_in" }, as: :json
    response.parsed_body.fetch("nonce")
  end

  # Google's POST is cross-site, so the browser withholds its SameSite=Lax
  # cookies but keeps them; the completion is a same-site GET that sends them.
  def google_sign_in_cross_site(subject:, ceremony: mint_sign_in_ceremony, complete: true)
    held = CROSS_SITE_WITHHELD.to_h { |name| [ name, cookies[name] ] }
    CROSS_SITE_WITHHELD.each { |name| cookies.delete(name) }
    cookies[:g_csrf_token] = "csrf"
    with_google_verifier(FakeVerifier.new(claims: google_claims(subject: subject, email: users(:normal).email, nonce: ceremony))) do
      post google_identity_callback_path, params: { credential: "a.b.c", g_csrf_token: "csrf" }, headers: login_rate_limit_headers
    end
    held.each { |name, value| cookies[name] = value if value }
    assert_redirected_to google_identity_completion_path
    follow_redirect! if complete
  end
end
