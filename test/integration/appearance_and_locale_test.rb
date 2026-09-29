require "test_helper"

class AppearanceAndLocaleTest < ActionDispatch::IntegrationTest
  test "appearance defaults to System and is rendered before any script runs" do
    get login_path

    assert_select "html[data-appearance='system']"
    assert_select "meta[name='color-scheme'][content='light dark']"
    assert_select ".appearance-menu summary[aria-label='Appearance: System']"
    assert_select ".appearance-option[aria-pressed='true']", text: "System"
    assert_equal "system", User.new.appearance
  end

  test "the redesigned landing renders in dark with appearance and one-step language controls" do
    cookies[:ui_appearance] = "dark"
    get root_path

    assert_select "html[data-appearance='dark']"
    assert_select "meta[name='color-scheme'][content='dark']"
    assert_select ".landing-hero h1", text: /Compare AI translations/
    assert_select ".translation-flow .flow-model", 3
    assert_select ".translation-flow .flow-winner"
    assert_select ".landing-value-card", 4
    assert_select ".decision-diagram"
    assert_select ".landing-trust-grid article", 3
    assert_select ".landing-final-cta"
    assert_select ".landing-header .appearance-menu summary[aria-label='Appearance: Dark']"
    assert_select ".landing-mobile-panel .landing-appearance-options .appearance-option", 3
    assert_select ".landing-locale form[action='#{locale_path}'] button[lang='ja']", text: "日本語"
    assert_select ".landing-page input[type='submit']", count: 0
    assert_no_match(/>(Apply|適用|Áp dụng)</, response.body)
    assert_select ".landing-page [style]", count: 0
  end

  test "visitors keep their appearance in a cookie and invalid values are refused" do
    patch appearance_path, params: { appearance: "dark" }, headers: { "Referer" => "http://www.example.com/login" }
    assert_redirected_to "/login"
    assert_equal "dark", cookies[:ui_appearance]

    get login_path
    assert_select "html[data-appearance='dark']"
    assert_select "meta[name='color-scheme'][content='dark']"

    patch appearance_path, params: { appearance: "neon" }
    assert_response :bad_request
    cookies[:ui_appearance] = "neon"
    get login_path
    assert_select "html[data-appearance='system']"
  end

  test "signed-in users keep their appearance on their account" do
    user = users(:normal)
    sign_in_as user

    patch appearance_path, params: { appearance: "light" }, as: :json
    assert_response :no_content
    assert_equal "light", user.reload.appearance

    get new_translation_workspace_path
    assert_select "html[data-appearance='light']"
    assert_raises(ActiveRecord::StatementInvalid) { user.update_column(:appearance, "neon") }
  end

  test "appearance labels are localized" do
    { "vi" => "Giao diện: Theo hệ thống", "ja" => "外観: システム設定" }.each do |locale, label|
      patch locale_path, params: { locale_code: locale }
      get login_path
      assert_select ".appearance-menu summary[aria-label=?]", label
    end
  end

  test "the interface language is chosen without a separate Apply button" do
    get login_path
    assert_select "form.locale-selector select[data-action='change->locale-select#switch']"
    assert_select "form.locale-selector input[type='submit'], form.locale-selector button", count: 0

    sign_in_as users(:normal)
    get new_translation_workspace_path
    assert_select "#app-sidebar form.locale-selector select"
    assert_select "#app-sidebar form.locale-selector input[type='submit']", count: 0
    assert_no_match(/>(Apply|適用|Áp dụng)</, response.body)
  end

  test "locale persists in a cookie for visitors and on the account when signed in, with an allowlist" do
    patch locale_path, params: { locale_code: "ja" }, headers: { "Referer" => "http://www.example.com/registration/new" }
    assert_redirected_to "/registration/new"
    assert_equal "ja", cookies[:ui_locale]
    patch locale_path, params: { locale_code: "fr" }
    assert_response :bad_request

    user = users(:normal)
    sign_in_as user
    patch locale_path, params: { locale_code: "vi" }, headers: { "Referer" => "http://evil.example/steal" }
    assert_redirected_to root_path
    [ "http://www.example.com//evil.example/x", "http://www.example.com/\\evil.example" ].each do |referer|
      patch appearance_path, params: { appearance: "dark" }, headers: { "Referer" => referer }
      assert_redirected_to root_path
    end
    assert_equal "vi", user.reload.locale
  end
end
