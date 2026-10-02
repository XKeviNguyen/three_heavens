require "test_helper"
require_relative "../support/google_identity_test_helper"

class GoogleSignInTest < ActionDispatch::IntegrationTest
  include GoogleIdentityTestHelper
  include ActiveJob::TestHelper

  CSRF = "csrf-token-from-google".freeze

  test "the callback accepts only POST" do
    get "/auth/google/callback"
    assert_response :not_found
  end

  test "Google's double-submit CSRF token must be present in cookie and body and match" do
    with_google_verifier(FakeVerifier.new(claims: claims_for(sign_in_ceremony))) do |verifier|
      post_callback(csrf_cookie: nil)
      assert_rejected
      post_callback(csrf_param: nil)
      assert_rejected
      post_callback(csrf_param: "different")
      assert_rejected
      post_callback(csrf_param: [ CSRF ])
      assert_rejected
      post_callback(csrf_cookie: "x" * 300, csrf_param: "x" * 300)
      assert_rejected
      assert_empty verifier.credentials, "credentials must not be verified before the CSRF check"
    end
  end

  test "only small form posts reach verification" do
    with_google_verifier(FakeVerifier.new(claims: claims_for(sign_in_ceremony))) do |verifier|
      cookies[:g_csrf_token] = CSRF
      post google_identity_callback_path, params: { credential: "a.b.c", g_csrf_token: CSRF }.to_json,
                                          headers: login_rate_limit_headers.merge("CONTENT_TYPE" => "application/json")
      assert_rejected
      post_callback(credential: "a" * 20.kilobytes)
      assert_equal 413, response.status, "oversized bodies are refused before Rails parses or logs them"
      assert_empty verifier.credentials
    end
  end

  test "a new Google user is created with safe defaults, signed in on a fresh session, and cannot reach paid AI" do
    get new_translation_workspace_path, headers: login_rate_limit_headers
    assert_redirected_to login_path
    assert session[:return_to_after_authenticating].present?
    session_before = cookies["_three_heavens_session"]

    verifier = FakeVerifier.new(claims: claims_for(sign_in_ceremony(locale: "vi")))
    with_google_verifier(verifier) do
      assert_difference [ "User.count", "FederatedIdentity.count" ], 1 do
        post_callback(extra: { role: "admin", status: "disabled", managed_ai_access: "1", user: { role: "admin" } })
      end
    end

    assert_equal [ "header.payload.signature" ], verifier.credentials
    assert_redirected_to new_translation_workspace_path
    assert_response :see_other
    assert_equal "Đăng nhập thành công.", flash[:notice]
    user = User.find_by!(email: "google.person@gmail.com")
    assert_equal [ "user", "active", false, "vi" ], [ user.role, user.status, user.managed_ai_access, user.locale ]
    assert_equal user.id, signed_in_user_id
    assert_nil session[:return_to_after_authenticating]
    assert_not_equal session_before, cookies["_three_heavens_session"]

    follow_redirect!
    assert_response :success
    assert_no_difference "AiProviderAttempt.count" do
      assert_no_enqueued_jobs do
        post translation_workspace_path, params: {
          translation_workspace: {
            project_name: "Forged", source_language: "Vietnamese", target_language: "Japanese",
            document_title: "Forged", source_text: "Source", workflow_mode: "manual",
            model_ids: [ llm_models(:openrouter_claude).id ], submission_token: issue_translation_workspace_token(user: user)
          }
        }
      end
    end
    assert_redirected_to new_translation_workspace_path
  end

  test "repeat sign-in with the same Google subject reuses the account" do
    with_google_verifier(FakeVerifier.new(claims: claims_for(sign_in_ceremony))) { post_callback }
    delete session_path

    with_google_verifier(FakeVerifier.new(claims: claims_for(sign_in_ceremony))) do
      assert_no_difference([ "User.count", "FederatedIdentity.count" ]) { post_callback }
    end
    assert_equal User.find_by!(email: "google.person@gmail.com").id, signed_in_user_id
  end

  test "a Google session cookie copied before sign-out stops authenticating after sign-out" do
    with_google_verifier(FakeVerifier.new(claims: claims_for(sign_in_ceremony))) { post_callback }
    copied_cookie = cookies["_three_heavens_session"]
    delete session_path

    replay = open_session
    replay.cookies["_three_heavens_session"] = copied_cookie
    replay.get history_path
    replay.assert_redirected_to login_path
    assert_not User.find_by!(email: "google.person@gmail.com").sessions.exists?
  end

  test "the ceremony return path is honoured and scoped to this site" do
    with_google_verifier(FakeVerifier.new(claims: claims_for(sign_in_ceremony(return_path: "/projects")))) { post_callback }
    assert_redirected_to "/projects"

    delete session_path
    with_google_verifier(FakeVerifier.new(claims: claims_for(sign_in_ceremony(return_path: "//evil.example/x")))) { post_callback }
    assert_redirected_to new_translation_workspace_path
  end

  test "disabled accounts, email collisions, and non-authoritative emails do not sign in" do
    disabled = users(:other)
    disabled.federated_identities.create!(provider: "google", provider_uid: "disabled-sub")
    disabled.update!(status: :disabled)
    with_google_verifier(FakeVerifier.new(claims: claims_for(sign_in_ceremony, subject: "disabled-sub"))) { post_callback }
    assert_rejected("Google sign-in could not be completed. Please try again.")

    with_google_verifier(FakeVerifier.new(claims: claims_for(sign_in_ceremony, subject: "collision", email: users(:normal).email))) do
      assert_no_difference([ "User.count", "FederatedIdentity.count" ]) { post_callback }
    end
    assert_rejected("An account already exists for this email. Sign in first, then connect Google.")

    with_google_verifier(FakeVerifier.new(claims: claims_for(sign_in_ceremony, subject: "third", email: "person@elsewhere.example"))) do
      assert_no_difference("User.count") { assert_no_enqueued_emails { post_callback } }
    end
    assert_rejected("Google can't confirm this email address for a new account. Create an account with your email and password, then connect Google from Account.")
  end

  test "rejected credentials show a generic message and log only a category" do
    log = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)

    %i[expired audience issuer signature malformed claims].each do |category|
      with_google_verifier(FakeVerifier.new(error: category)) { post_callback(credential: "eyJsecret.eyJpayload.sig") }
      assert_rejected("Google sign-in could not be completed. Please try again.")
    end
    with_google_verifier(FakeVerifier.new(error: :keys_unavailable)) { post_callback }
    assert_rejected("Google sign-in is temporarily unavailable. Try again later or use your email and password.")

    assert_includes log.string, "category=audience"
    assert_not_includes log.string, "eyJsecret"
    assert_not_includes log.string, CSRF
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
                 .filter("credential" => "eyJ", "g_csrf_token" => CSRF)
    assert_equal({ "credential" => "[FILTERED]", "g_csrf_token" => "[FILTERED]" }, filtered)
  ensure
    Rails.logger = original_logger
  end

  test "forged, expired, and replayed ceremonies are refused" do
    with_google_verifier(FakeVerifier.new(claims: google_claims(nonce: "not-issued-by-us"))) { post_callback }
    assert_rejected

    expired = sign_in_ceremony
    travel(GoogleIdentity::Ceremony::TTL + 1.second) do
      with_google_verifier(FakeVerifier.new(claims: claims_for(expired))) { post_callback }
      assert_rejected
    end

    with_memory_cache do
      ceremony = sign_in_ceremony
      with_google_verifier(FakeVerifier.new(claims: claims_for(ceremony))) do
        post_callback
        assert_redirected_to new_translation_workspace_path
        delete session_path
        post_callback
        assert_rejected
      end
    end
  end

  test "callback floods are rate limited" do
    with_google_verifier(FakeVerifier.new(error: :signature)) do
      Auth::GoogleCallbacksController::RATE_LIMIT.times { post_callback }
      post_callback
    end
    assert_rejected("Too many sign-in attempts. Wait three minutes, then try again.")
  end

  test "linking finishes only for the signed-in user who started it" do
    owner = users(:normal)
    sign_in_as owner
    get settings_account_path
    assert_select "[data-controller='google-sign-in'][data-google-sign-in-login-uri-value='http://www.example.com/auth/google/callback']"

    link = link_ceremony(owner)
    with_google_verifier(FakeVerifier.new(claims: claims_for(link, subject: "owner-sub", email: "owner.google@gmail.com"))) { post_callback }
    assert_redirected_to settings_account_path
    assert_not owner.federated_identities.exists?, "the cross-site callback must not link on its own"

    follow_redirect!
    assert_select "[role='status']", text: /owner\.google@gmail\.com/
    post settings_account_google_identity_path
    assert_redirected_to settings_account_path
    assert_equal [ "owner-sub" ], owner.federated_identities.pluck(:provider_uid)
  end

  test "signing out discards a pending link" do
    owner = users(:normal)
    sign_in_as owner
    with_google_verifier(FakeVerifier.new(claims: claims_for(link_ceremony(owner), subject: "stale-sub"))) { post_callback }
    delete session_path
    assert_redirected_to login_path
    sign_in_as owner

    get settings_account_path
    assert_select "[role='status']", count: 0
    post settings_account_google_identity_path
    assert_not FederatedIdentity.exists?(provider_uid: "stale-sub")
  end

  test "a pending link cannot be completed by a different signed-in user" do
    with_google_verifier(FakeVerifier.new(claims: claims_for(link_ceremony(users(:normal)), subject: "victim-sub"))) { post_callback }
    sign_in_as users(:other)

    get settings_account_path
    assert_select "[role='status']", count: 0
    post settings_account_google_identity_path
    assert_equal "The Google confirmation expired. Connect Google again.", flash[:alert]
    assert_not FederatedIdentity.exists?(provider_uid: "victim-sub")
  end

  test "a Google identity owned by someone else is not linked or disclosed" do
    users(:other).federated_identities.create!(provider: "google", provider_uid: "owned-sub")
    sign_in_as users(:normal)
    with_google_verifier(FakeVerifier.new(claims: claims_for(link_ceremony(users(:normal)), subject: "owned-sub"))) { post_callback }
    follow_redirect!
    post settings_account_google_identity_path

    assert_equal "This Google account is already connected to another account.", flash[:alert]
    assert_not_includes flash[:alert], users(:other).email
    assert_equal users(:other), FederatedIdentity.find_by!(provider_uid: "owned-sub").user
  end

  test "a Google-only account cannot disconnect its only sign-in method" do
    with_google_verifier(FakeVerifier.new(claims: claims_for(sign_in_ceremony))) { post_callback }
    delete settings_account_google_identity_path

    assert_equal "Google is the only way to sign in to this account, so it can't be disconnected.", flash[:alert]
    assert User.find_by!(email: "google.person@gmail.com").federated_identities.exists?
  end

  test "sign-in pages offer Google only when configured and keep email sign-in" do
    get login_path
    assert_select "[data-controller='google-sign-in'][data-google-sign-in-text-value='continue_with'][data-google-sign-in-ceremony-url-value='#{google_identity_ceremony_path}'][data-google-sign-in-intent-value='sign_in']"
    assert_select "[data-google-sign-in-nonce-value]", { count: 0 }, "no ceremony is baked into the page"
    assert_select "form[action='#{session_path}'] input[type='password']"
    get new_registration_path
    assert_select "[data-google-sign-in-text-value='signup_with']"

    original = Rails.configuration.x.google_identity.client_id
    Rails.configuration.x.google_identity.client_id = nil
    get login_path
    assert_select "[data-controller='google-sign-in']", count: 0
    assert_select "form[action='#{session_path}'] input[type='password']"
    get new_registration_path
    assert_select "[data-controller='google-sign-in']", count: 0
    assert_select "form[action='#{registration_path}'] input[type='password']", 2
    sign_in_as users(:normal)
    assert_equal users(:normal).id, signed_in_user_id
  ensure
    Rails.configuration.x.google_identity.client_id = original
  end

  private

  def sign_in_ceremony(locale: "en", return_path: nil)
    GoogleIdentity::Ceremony.issue(intent: "sign_in", locale: locale, appearance: "system", return_path: return_path)
  end

  def link_ceremony(user)
    GoogleIdentity::Ceremony.issue(intent: "link", user: user, locale: "en", appearance: "system")
  end

  def claims_for(ceremony, subject: "109876543210987654321", email: "google.person@gmail.com")
    google_claims(subject: subject, email: email, nonce: ceremony)
  end

  def post_callback(credential: "header.payload.signature", csrf_cookie: CSRF, csrf_param: CSRF, extra: {})
    if csrf_cookie
      cookies[:g_csrf_token] = csrf_cookie
    else
      cookies.delete(:g_csrf_token)
    end
    post google_identity_callback_path,
         params: { credential: credential, g_csrf_token: csrf_param, select_by: "btn" }.compact.merge(extra),
         headers: login_rate_limit_headers
  end

  def assert_rejected(message = "Google sign-in could not be completed. Please try again.")
    assert_redirected_to login_path
    assert_response :see_other
    assert_nil signed_in_user_id
    follow_redirect!
    assert_select "[role='alert']", text: message
  end
end
