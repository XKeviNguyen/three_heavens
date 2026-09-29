require "test_helper"

class PublicAccountsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "landing and account pages are public in three locales" do
    %w[en vi ja].each do |locale|
      get root_path, headers: { "Accept-Language" => locale }
      assert_response :success
      assert_select "html[lang='#{locale}']"
      assert_select "h1", count: 1
      get new_registration_path, headers: { "Accept-Language" => locale }
      assert_response :success
      assert_select "html[lang='#{locale}']"
    end
  end

  test "registration requires only safe fields and leaves AI access disabled" do
    assert_difference "User.count", 1 do
      assert_enqueued_emails 1 do
        post registration_path, params: {
          user: { email: " NEW@EXAMPLE.TEST ", password: "a long secure password",
                  password_confirmation: "a long secure password" }
        }
      end
    end
    assert_redirected_to new_confirmation_resend_path
    user = User.find_by!(email: "new@example.test")
    assert_equal "user", user.role
    assert_equal "active", user.status
    assert_nil user.email_verified_at
    assert_not user.managed_ai_access?
    assert_equal "en", user.locale
    get new_translation_workspace_path
    assert_redirected_to login_path
  end

  test "registration rejects privilege and locale injection" do
    %w[role status managed_ai_access email_verified_at locale].each_with_index do |attribute, index|
      assert_no_difference "User.count" do
        post registration_path, params: {
          user: { email: "injected@example.test", password: "a long secure password",
                  password_confirmation: "a long secure password", attribute => "admin" }
        }, headers: { "REMOTE_ADDR" => "2001:db8:55::#{index + 1}" }
        assert_response :bad_request
      end
    end
  end

  test "registration rejects invalid addresses and weak or mismatched passwords" do
    cases = [
      [ "not-an-email", "a long secure password", "a long secure password", :unprocessable_content ],
      [ "duplicate@example.test", "a long secure password", "a long secure password", :unprocessable_content ],
      [ "short@example.test", "short", "short", :unprocessable_content ],
      [ "mismatch@example.test", "a long secure password", "a different secure password", :unprocessable_content ],
      [ "long@example.test", "a" * (User::MAXIMUM_PASSWORD_LENGTH + 1), "a" * (User::MAXIMUM_PASSWORD_LENGTH + 1), :bad_request ]
    ]
    cases[1][0] = users(:normal).email

    cases.each_with_index do |(email, password, confirmation, status), index|
      assert_no_difference "User.count" do
        post registration_path, params: {
          user: { email: email, password: password, password_confirmation: confirmation }
        }, headers: { "REMOTE_ADDR" => "192.0.2.#{index + 80}" }
      end
      assert_response status
    end
  end

  test "registration rate limit rejects the sixth request" do
    attributes = { user: { email: "invalid", password: "short", password_confirmation: "short" } }
    5.times do
      post registration_path, params: attributes, headers: { "REMOTE_ADDR" => "192.0.2.199" }
      assert_response :unprocessable_content
    end
    post registration_path, params: attributes, headers: { "REMOTE_ADDR" => "192.0.2.199" }
    assert_response :too_many_requests
    assert_equal "3600", response.headers["Retry-After"]
  end

  test "confirmation token expires and resend invalidates the earlier link" do
    user = User.create!(email: "resend@example.test", password: "a long secure password",
                        confirmation_sent_at: 4.minutes.ago)
    old_token = user.generate_token_for(:email_confirmation)
    assert_enqueued_emails 1 do
      post confirmation_resend_path, params: { email: user.email }
    end
    assert_redirected_to new_confirmation_resend_path
    assert_nil User.find_by_token_for(:email_confirmation, old_token)
    new_token = user.reload.generate_token_for(:email_confirmation)
    travel 25.hours do
      post email_confirmation_path, params: { token: new_token }
      assert_redirected_to new_confirmation_resend_path
      assert_not user.reload.email_verified?
    end
    post confirmation_resend_path, params: { email: "unknown@example.test" }
    assert_redirected_to new_confirmation_resend_path
  end

  test "confirmation and admin access changes reject POST without CSRF when protection is enabled" do
    user = User.create!(email: "csrf@example.test", password: "a long secure password",
                        confirmation_sent_at: Time.current)
    token = user.generate_token_for(:email_confirmation)
    old_value = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post email_confirmation_path, params: { token: token }
    assert_response :unprocessable_content
    assert_not user.reload.email_verified?

    sign_in_as users(:admin)
    target = users(:other)
    target.update!(managed_ai_access: false)
    patch grant_managed_ai_access_settings_user_path(target)
    assert_response :unprocessable_content
    assert_not target.reload.managed_ai_access?
  ensure
    ActionController::Base.allow_forgery_protection = old_value
  end

  test "registration email link uses configured host despite a forged request host" do
    perform_enqueued_jobs do
      post registration_path, params: {
        user: { email: "host-check@example.test", password: "a long secure password",
                password_confirmation: "a long secure password" }
      }, headers: { "Host" => "forged.example" }
    end
    assert_redirected_to new_confirmation_resend_path
    body = ActionMailer::Base.deliveries.last.text_part.body.decoded
    assert_includes body, "example.com"
    assert_not_includes body, "forged.example"
  end

  test "confirmation link GET is read only and POST is single use" do
    user = User.create!(email: "pending@example.test", password: "a long secure password",
                        locale: "ja", confirmation_sent_at: Time.current)
    token = user.generate_token_for(:email_confirmation)
    get email_confirmation_path(token: token)
    assert_response :success
    assert_nil user.reload.email_verified_at
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_equal "no-store", response.headers["Cache-Control"]

    post email_confirmation_path, params: { token: token }
    assert_redirected_to login_path
    assert user.reload.email_verified?
    assert_nil User.find_by_token_for(:email_confirmation, token)

    post email_confirmation_path, params: { token: token }
    assert_redirected_to new_confirmation_resend_path
  end

  test "unverified account cannot start a session" do
    User.create!(email: "pending@example.test", password: "a long secure password",
                 confirmation_sent_at: Time.current)
    post session_path, params: { session: { email: "pending@example.test", password: "a long secure password" } }
    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /Confirm your email/
    get new_translation_workspace_path
    assert_redirected_to login_path
  end

  test "locale cookie and saved account locale follow explicit selection" do
    patch locale_path, params: { locale_code: "vi" }
    assert_redirected_to root_path
    get root_path
    assert_select "html[lang='vi']"

    sign_in_as users(:normal)
    patch locale_path, params: { locale_code: "ja" }
    assert_equal "ja", users(:normal).reload.locale
    get new_translation_workspace_path
    assert_select "html[lang='ja']"
  end

  test "admin controls managed access and normal users cannot grant it" do
    target = users(:other)
    target.update!(managed_ai_access: false)
    sign_in_as users(:normal)
    patch grant_managed_ai_access_settings_user_path(target)
    assert_not target.reload.managed_ai_access?

    sign_out
    sign_in_as users(:admin)
    patch grant_managed_ai_access_settings_user_path(target)
    assert target.reload.managed_ai_access?
    patch revoke_managed_ai_access_settings_user_path(target)
    assert_not target.reload.managed_ai_access?
  end

  test "landing explains the human-guided comparison flow and account-aware action" do
    get root_path, headers: { "Accept-Language" => "en" }
    assert_response :success
    assert_select "meta[name='description']"
    assert_select "h1", text: /Compare AI translations.*Keep the final word/m
    assert_select ".flow-model", count: 3
    assert_select ".flow-winner", text: /Strongest candidate/
    assert_select ".flow-human", text: /You edit and approve/
    assert_select ".flow-final", text: /Final translation/
    assert_select "a[href='#{new_registration_path}']", text: /Start a translation/
    assert_select "a[href='#{benchmarks_path}']", minimum: 1
    assert_select "a[href='#how-it-works']", minimum: 1
    assert_select "#how-it-works", 1
    # CSP style-src 'self' drops inline style attributes, so the page must not rely on them.
    assert_select ".landing-page [style]", count: 0
    assert_select ".landing-locale form[action='#{locale_path}'] button[lang='ja']", text: "日本語"

    patch locale_path, params: { locale_code: "ja" }
    follow_redirect!
    assert_select "h1", text: /AI翻訳を比べる。.*最終判断は、あなたに。/m

    # The language chosen while signed out carries into the account.
    sign_in_as users(:normal)
    assert_equal "ja", users(:normal).reload.locale
    get root_path
    assert_response :success
    assert_select "a[href='#{new_translation_workspace_path}']", text: "ワークスペースを開く"
    assert_select "a[href='#{new_registration_path}']", count: 0
  end
end
