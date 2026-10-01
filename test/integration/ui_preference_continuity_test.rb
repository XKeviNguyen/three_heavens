require "test_helper"
require_relative "../support/google_identity_test_helper"

class UiPreferenceContinuityTest < ActionDispatch::IntegrationTest
  include GoogleIdentityTestHelper
  include ActiveJob::TestHelper

  SIGNED_IN = { "en" => "Signed in successfully.", "vi" => "Đăng nhập thành công.", "ja" => "ログインしました。" }.freeze
  CROSS_SITE_WITHHELD = %w[_three_heavens_session ui_locale ui_appearance ui_locale_override ui_appearance_override].freeze

  setup do
    @account = users(:normal)
    @other = users(:other)
  end

  test "case 1: explicit signed-out JA + Dark survive a Google sign-in and a sign-out" do
    @account.update!(locale: "en", appearance: "light")
    @account.federated_identities.create!(provider: "google", provider_uid: "case-1")
    choose_as_guest(locale: "ja", appearance: "dark")
    assert_rendered("ja", "dark", login_path)

    google_sign_in(subject: "case-1")
    assert_signed_in_render("ja", "dark")
    assert_account(@account, "ja", "dark")

    sign_out
    assert_rendered("ja", "dark", root_path)
  end

  test "case 2: explicit VI + Light after a JA + Dark sign-out win at password sign-in" do
    @account.update!(locale: "ja", appearance: "dark")
    sign_in_as @account
    sign_out
    assert_rendered("ja", "dark", login_path)

    choose_as_guest(locale: "vi", appearance: "light")
    password_sign_in(@account)
    assert_signed_in_render("vi", "light")
    assert_account(@account, "vi", "light")

    sign_out
    assert_rendered("vi", "light", login_path)
  end

  test "case 3: browser defaults never overwrite a stored account preference" do
    @account.update!(locale: "ja", appearance: "dark")
    get login_path, headers: { "Accept-Language" => "en-US,en;q=0.9" }
    assert_rendered("en", "system")

    password_sign_in(@account, headers: { "Accept-Language" => "en-US,en;q=0.9" })
    assert_signed_in_render("ja", "dark")
    assert_account(@account, "ja", "dark")
  end

  test "case 4: System is stored as System on both sides of the sign-in boundary" do
    @account.update!(locale: "vi", appearance: "system")
    password_sign_in(@account)
    assert_signed_in_render("vi", "system")
    assert_select "meta[name='color-scheme'][content='light dark']"

    sign_out
    assert_equal "system", cookies[:ui_appearance]
    assert_rendered("vi", "system", login_path)
    assert_account(@account, "vi", "system")
  end

  test "case 5: signed-in changes are kept through sign-out and the next sign-in" do
    @account.update!(locale: "ja", appearance: "dark")
    password_sign_in(@account)
    patch locale_path, params: { locale_code: "vi" }
    patch appearance_path, params: { appearance: "system" }, as: :json
    assert_account(@account, "vi", "system")
    assert_no_pending_override

    sign_out
    assert_rendered("vi", "system", root_path)
    password_sign_in(@account)
    assert_signed_in_render("vi", "system")
    assert_account(@account, "vi", "system")
  end

  test "case 6: a change on the login page between sessions is adopted" do
    @account.update!(locale: "vi", appearance: "dark")
    password_sign_in(@account)
    sign_out
    choose_as_guest(locale: "ja", appearance: "light")

    password_sign_in(@account)
    assert_signed_in_render("ja", "light")
    assert_account(@account, "ja", "light")
  end

  test "case 7: a shared browser does not hand one account's preferences to the next" do
    @account.update!(locale: "ja", appearance: "dark")
    @other.update!(locale: "vi", appearance: "light")
    password_sign_in(@account)
    sign_out
    assert_rendered("ja", "dark", login_path)
    assert_no_pending_override

    password_sign_in(@other)
    assert_signed_in_render("vi", "light")
    assert_account(@other, "vi", "light")
    sign_out
    assert_rendered("vi", "light", login_path)
    assert_account(@account, "ja", "dark")
  end

  test "case 8: an explicit change on a shared browser applies to whoever signs in next" do
    @account.update!(locale: "ja", appearance: "dark")
    @other.update!(locale: "vi", appearance: "light")
    password_sign_in(@account)
    sign_out
    choose_as_guest(locale: "en", appearance: "system")

    password_sign_in(@other)
    assert_signed_in_render("en", "system")
    assert_account(@other, "en", "system")
    assert_account(@account, "ja", "dark")
  end

  test "only explicitly changed preferences are adopted" do
    @account.update!(locale: "ja", appearance: "dark")
    choose_as_guest(appearance: "light")
    password_sign_in(@account, headers: { "Accept-Language" => "vi" })
    assert_signed_in_render("ja", "light")
    assert_account(@account, "ja", "light")
  end

  test "Google keeps a stored preference without an override and adopts one with it" do
    @account.update!(locale: "ja", appearance: "dark")
    @account.federated_identities.create!(provider: "google", provider_uid: "keeps")
    get login_path, headers: { "Accept-Language" => "en" }
    google_sign_in(subject: "keeps")
    assert_signed_in_render("ja", "dark")
    assert_account(@account, "ja", "dark")

    sign_out
    choose_as_guest(locale: "vi", appearance: "system")
    google_sign_in(subject: "keeps")
    assert_signed_in_render("vi", "system")
    assert_account(@account, "vi", "system")

    patch locale_path, params: { locale_code: "ja" }
    sign_out
    assert_no_difference("User.count") { google_sign_in(subject: "keeps") }
    assert_signed_in_render("ja", "system")
  end

  test "a new Google account starts from the current page and gets no paid AI access" do
    choose_as_guest(locale: "ja")
    assert_difference("User.count", 1) { google_sign_in(subject: "brand-new", email: "brand.new@gmail.com") }
    user = User.find_by!(email: "brand.new@gmail.com")
    assert_signed_in_render("ja", "system")
    assert_equal [ "ja", "system", false, "user", "active" ], [ user.locale, user.appearance, user.managed_ai_access, user.role, user.status ]

    assert_no_difference("AiProviderAttempt.count") do
      assert_no_enqueued_jobs do
        post translation_workspace_path, params: { translation_workspace: {
          project_name: "Forged", source_language: "Vietnamese", target_language: "Japanese", document_title: "Forged",
          source_text: "Source", workflow_mode: "manual", model_ids: [ llm_models(:openrouter_claude).id ],
          submission_token: issue_translation_workspace_token(user: user)
        } }
      end
    end
  end

  test "linking Google never changes the signed-in user's preferences" do
    @account.update!(locale: "vi", appearance: "dark")
    password_sign_in(@account)
    ceremony = mint_ceremony("link")
    with_google_verifier(FakeVerifier.new(claims: google_claims(subject: "linked", nonce: ceremony))) do
      post_cross_site_callback(keep_browser_cookies: true)
    end
    follow_redirect!
    post settings_account_google_identity_path
    assert_equal [ "linked" ], @account.federated_identities.pluck(:provider_uid)
    assert_account(@account, "vi", "dark")
  end

  test "tampered or invalid preference cookies are ignored and never touch other attributes" do
    @account.update!(locale: "ja", appearance: "dark")
    cookies[:ui_locale_override] = "vi"
    cookies[:ui_appearance_override] = { appearance: "light", role: "admin" }.to_json
    cookies[:ui_locale] = "xx"
    cookies[:ui_appearance] = "neon"
    get login_path
    assert_rendered("en", "system")

    password_sign_in(@account)
    assert_signed_in_render("ja", "dark")
    assert_equal [ "user", true ], [ @account.reload.role, @account.managed_ai_access ]
  end

  test "display cookies and the pending override are separate" do
    choose_as_guest(locale: "vi")
    assert_equal "vi", cookies[:ui_locale]
    assert cookies[:ui_locale_override].present?, "an explicit signed-out change is recorded as pending"
    assert_not_includes cookies[:ui_locale_override], "vi", "the pending override is signed, not plain"
    assert_nil cookies[:ui_appearance_override], "only the changed preference is recorded"

    password_sign_in(@account)
    assert_no_pending_override
    sign_out
    assert_equal "vi", cookies[:ui_locale]
    assert_no_pending_override
  end

  test "overlapping signed-out locale and appearance changes are both adopted at sign-in, in any order" do
    each_overlap do |order, arrival|
      reset!
      @account.update!(locale: "en", appearance: "light")
      get root_path
      changes = { locale: -> { choose_as_guest(locale: "ja") }, appearance: -> { choose_as_guest(appearance: "dark") } }
      deliver_overlapping(*changes.values_at(*order), arrival:)

      assert_rendered("ja", "dark", root_path)
      password_sign_in(@account)
      assert_signed_in_render("ja", "dark")
      assert_account(@account, "ja", "dark")
    end
  end

  test "overlapping signed-in changes never leave an older value for after sign-out, in any order" do
    each_overlap do |order, arrival|
      reset!
      @account.update!(locale: "en", appearance: "light")
      password_sign_in(@account)
      changes = {
        locale: -> { patch locale_path, params: { locale_code: "ja" } },
        appearance: -> { patch appearance_path, params: { appearance: "dark" }, as: :json }
      }
      deliver_overlapping(*changes.values_at(*order), arrival:)

      assert_account(@account, "ja", "dark")
      assert_equal [ "ja", "dark" ], [ cookies[:ui_locale], cookies[:ui_appearance] ]
    end
  end

  test "signing out while an appearance change is still being saved keeps that change, in any order" do
    each_overlap(:appearance, :sign_out) do |order, arrival|
      reset!
      @account.update!(locale: "ja", appearance: "light")
      password_sign_in(@account)
      changes = {
        appearance: -> { patch appearance_path, params: { appearance: "dark" }, as: :json },
        sign_out: -> { delete session_path }
      }
      deliver_overlapping(*changes.values_at(*order), arrival:)

      assert_account(@account, "ja", "dark")
      assert_rendered("ja", "dark", login_path)
      assert_select ".appearance-menu[data-appearance-revision-value='1']"
    end
  end

  private

  # Every order in which the server can run two overlapping requests, each
  # with both orders in which their responses can reach the browser.
  def each_overlap(first = :locale, second = :appearance)
    [ [ first, second ], [ second, first ] ].product([ :as_run, :reversed ]).each do |order, arrival|
      yield order, arrival
    end
  end

  # Runs the requests in order, each sent with the cookies the browser holds
  # now (as when one is sent before another's response has arrived), then
  # lets the browser store their responses' cookies in order of arrival.
  def deliver_overlapping(*requests, arrival:)
    sent_with = cookies.to_hash
    responses = requests.map do |request|
      restore_cookies(sent_with)
      request.call
      Array(response.headers["Set-Cookie"]).join("\n")
    end
    restore_cookies(sent_with)
    responses.reverse! if arrival == :reversed
    responses.each { |set_cookie| cookies.merge(set_cookie, URI("http://www.example.com/")) }
  end

  def restore_cookies(values)
    cookies.to_hash.each_key { |name| cookies.delete(name) }
    values.each { |name, value| cookies[name] = value }
  end

  def choose_as_guest(locale: nil, appearance: nil)
    patch locale_path, params: { locale_code: locale } if locale
    patch appearance_path, params: { appearance: appearance }, as: :json if appearance
  end

  def password_sign_in(user, headers: {})
    post session_path, params: { session: { email: user.email, password: password_for(user) } },
                       headers: login_rate_limit_headers.merge(headers)
    follow_redirect!
  end

  def mint_ceremony(intent)
    post google_identity_ceremony_path, params: { intent: intent }, as: :json
    response.parsed_body.fetch("nonce")
  end

  def google_sign_in(subject:, email: @account.email)
    ceremony = mint_ceremony("sign_in")
    with_google_verifier(FakeVerifier.new(claims: google_claims(subject: subject, email: email, nonce: ceremony))) do
      post_cross_site_callback
    end
    follow_redirect!
  end

  # Google's POST is cross-site: SameSite=Lax cookies, including the session
  # and every preference cookie, are withheld by the browser.
  # keep_browser_cookies: the browser still holds them afterwards (a link
  # attempt returns to the existing session), they are only not sent.
  def post_cross_site_callback(keep_browser_cookies: false)
    held = CROSS_SITE_WITHHELD.to_h { |name| [ name, cookies[name] ] }
    CROSS_SITE_WITHHELD.each { |name| cookies.delete(name) }
    cookies[:g_csrf_token] = "csrf"
    post google_identity_callback_path, params: { credential: "a.b.c", g_csrf_token: "csrf" }, headers: login_rate_limit_headers
    held.each { |name, value| cookies[name] = value if value && keep_browser_cookies }
  end

  def sign_out
    delete session_path
    follow_redirect!
  end

  def assert_rendered(locale, appearance, path = nil)
    get path if path
    assert_response :success
    assert_select "html[lang='#{locale}'][data-appearance='#{appearance}']"
  end

  def assert_signed_in_render(locale, appearance)
    assert_equal new_translation_workspace_path, path
    assert_rendered(locale, appearance)
    assert_select "[role='status']", text: SIGNED_IN.fetch(locale)
  end

  def assert_account(user, locale, appearance)
    assert_equal [ locale, appearance ], user.reload.values_at(:locale, :appearance)
  end

  def assert_no_pending_override
    assert cookies[:ui_locale_override].blank? && cookies[:ui_appearance_override].blank?, "no pending signed-out override remains"
  end
end
