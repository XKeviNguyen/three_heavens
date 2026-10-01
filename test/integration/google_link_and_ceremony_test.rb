require "test_helper"
require_relative "../support/google_identity_test_helper"

class GoogleLinkAndCeremonyTest < ActionDispatch::IntegrationTest
  include GoogleIdentityTestHelper

  CSRF = "csrf-token-from-google".freeze
  SESSION_COOKIE = "_three_heavens_session".freeze

  setup do
    @owner = users(:normal)
    sign_in_as @owner
  end

  test "a failed link keeps the signed-in session and returns to Account with a sanitized message" do
    failures = {
      "invalid JWT" => -> { FakeVerifier.new(error: :signature) },
      "wrong audience" => -> { FakeVerifier.new(error: :audience) },
      "expired JWT" => -> { FakeVerifier.new(error: :expired) },
      "invalid ceremony" => -> { FakeVerifier.new(claims: google_claims(nonce: "not-issued-by-us")) },
      "expired ceremony" => -> { FakeVerifier.new(claims: google_claims(nonce: travel_past_ceremony)) }
    }

    failures.each do |label, verifier|
      assert_no_difference [ "User.count", "FederatedIdentity.count" ], label do
        with_google_verifier(verifier.call) { post_cross_site_callback(credential: "eyJsecret.eyJpayload.sig") }
      end
      assert_link_failure_kept_session(label)
    end

    [ { csrf_param: "mismatch" }, { csrf_cookie: nil } ].each do |malformed|
      with_google_verifier(FakeVerifier.new(error: :signature)) { post_cross_site_callback(**malformed) }
      assert_link_failure_kept_session("malformed #{malformed.keys.first}")
    end
  end

  test "a replayed link ceremony keeps the session and links nothing twice" do
    with_memory_cache do
      claims = google_claims(subject: "replay-sub", nonce: link_ceremony)
      with_google_verifier(FakeVerifier.new(claims: claims)) do
        post_cross_site_callback
        assert_redirected_to settings_account_path
        post settings_account_google_identity_path
        post_cross_site_callback
      end
    end

    assert_link_failure_kept_session("replay")
    assert_equal [ "replay-sub" ], @owner.federated_identities.pluck(:provider_uid)
  end

  test "a successful cross-site link staging keeps the session and completes on Account" do
    with_google_verifier(FakeVerifier.new(claims: google_claims(subject: "new-sub", email: "owner@gmail.com", nonce: link_ceremony))) do
      post_cross_site_callback
    end
    assert_redirected_to settings_account_path
    follow_redirect!
    assert_response :success
    assert_equal @owner.id, session[:user_id]
    assert_select "[role='status']", text: /owner@gmail\.com/

    post settings_account_google_identity_path
    assert_equal [ "new-sub" ], @owner.federated_identities.pluck(:provider_uid)
  end

  test "an identity owned by another account is refused on Account without signing out" do
    users(:other).federated_identities.create!(provider: "google", provider_uid: "owned-sub")
    with_google_verifier(FakeVerifier.new(claims: google_claims(subject: "owned-sub", nonce: link_ceremony))) { post_cross_site_callback }
    follow_redirect!
    post settings_account_google_identity_path
    follow_redirect!

    assert_equal @owner.id, session[:user_id]
    assert_select "[role='alert']", text: "This Google account is already connected to another account."
    assert_not @owner.federated_identities.exists?
  end

  test "sign-in failures authenticate no one and write no session" do
    delete session_path
    with_google_verifier(FakeVerifier.new(error: :signature)) { post_cross_site_callback }
    assert_redirected_to login_path
    follow_redirect!
    assert_nil session[:user_id]
    assert_select "[role='alert']", text: "Google sign-in could not be completed. Please try again."
  end

  test "fresh ceremonies are issued on demand, bound to their intent, and bounded" do
    post google_identity_ceremony_path, params: { intent: "link" }, as: :json
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    ceremony = GoogleIdentity::Ceremony.resolve(response.parsed_body.fetch("nonce"))
    assert ceremony.link?
    assert_equal @owner.id, ceremony.user_id
    assert_equal GoogleIdentity::Ceremony::TTL.to_i, response.parsed_body.fetch("expires_in")

    post google_identity_ceremony_path, params: { intent: "admin", user_id: users(:admin).id }, as: :json
    assert_response :bad_request

    delete session_path
    post google_identity_ceremony_path, params: { intent: "link" }, as: :json
    assert_response :forbidden
    post google_identity_ceremony_path, params: { intent: "sign_in", user_id: @owner.id, locale: "xx" }, as: :json
    sign_in = GoogleIdentity::Ceremony.resolve(response.parsed_body.fetch("nonce"))
    assert_equal [ "sign_in", nil, "en" ], [ sign_in.intent, sign_in.user_id, sign_in.locale ]
  end

  test "background ceremony and appearance requests never write a session cookie" do
    # sign_in_as leaves a displayed flash; sweeping it would otherwise rewrite the
    # session, and a late background response would then overwrite a newer one.
    post google_identity_ceremony_path, params: { intent: "link" }, as: :json
    assert_response :success
    assert_no_session_cookie_written
    patch appearance_path, params: { appearance: "dark" }, as: :json
    assert_response :success
    assert_no_session_cookie_written
    patch appearance_path, params: { appearance: "light", return_to: "/projects" }
    assert_redirected_to "/projects"
    assert_no_session_cookie_written

    get settings_account_path
    assert_response :success
    assert_equal "light", @owner.reload.appearance
  end

  test "ceremony issuance requires the Rails CSRF token and is rate limited" do
    ActionController::Base.allow_forgery_protection = true
    post google_identity_ceremony_path, params: { intent: "sign_in" }, as: :json
    assert_response :unprocessable_content
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  test "ceremony floods are refused" do
    Auth::GoogleCeremoniesController::RATE_LIMIT.times do
      post google_identity_ceremony_path, params: { intent: "sign_in" }, as: :json, headers: login_rate_limit_headers
    end
    post google_identity_ceremony_path, params: { intent: "sign_in" }, as: :json, headers: login_rate_limit_headers
    assert_response :too_many_requests
  end

  test "no ceremony is issued when Google sign-in is not configured" do
    original = Rails.configuration.x.google_identity.client_id
    Rails.configuration.x.google_identity.client_id = nil
    post google_identity_ceremony_path, params: { intent: "sign_in" }, as: :json
    assert_response :not_found
  ensure
    Rails.configuration.x.google_identity.client_id = original
  end

  private

  def link_ceremony
    GoogleIdentity::Ceremony.issue(intent: "link", user: @owner, locale: "en", appearance: "system")
  end

  def travel_past_ceremony
    token = link_ceremony
    travel(GoogleIdentity::Ceremony::TTL + 1.second)
    token
  end

  # Google's POST is cross-site: the browser withholds the SameSite=Lax session
  # cookie. The callback must not answer with a session cookie of its own,
  # because the browser would store it in place of the real session.
  def post_cross_site_callback(credential: "header.payload.signature", csrf_cookie: CSRF, csrf_param: CSRF)
    session_cookie = cookies[SESSION_COOKIE]
    cookies.delete(SESSION_COOKIE)
    csrf_cookie ? cookies[:g_csrf_token] = csrf_cookie : cookies.delete(:g_csrf_token)
    post google_identity_callback_path,
         params: { credential: credential, g_csrf_token: csrf_param }.compact,
         headers: login_rate_limit_headers
    assert_not_includes Array(response.headers["set-cookie"]).join("\n"), "#{SESSION_COOKIE}=",
                        "the cross-site callback must not replace the browser's session cookie"
    cookies[SESSION_COOKIE] = session_cookie
  ensure
    travel_back
  end

  def assert_no_session_cookie_written
    assert_not_includes Array(response.headers["set-cookie"]).join("\n"), "#{SESSION_COOKIE}="
  end

  def assert_link_failure_kept_session(label)
    follow_redirect! while response.redirect?
    assert_equal settings_account_path, path, label
    assert_response :success, label
    assert_equal @owner.id, session[:user_id], label
    assert_select "[role='alert']", { text: "Google could not be connected. Please try again." }, label
    assert_no_match(/eyJsecret/, response.body, label)
  end
end
