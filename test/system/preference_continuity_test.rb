require "application_system_test_case"
require_relative "../support/google_identity_system_helper"

class PreferenceContinuitySystemTest < ApplicationSystemTestCase
  include GoogleIdentitySystemHelper

  DARK_CANVAS = "rgb(13, 13, 15)".freeze

  teardown do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: false)
  end

  test "landing JA + Dark carry into the dashboard and back out after sign-out" do
    user = users(:normal)
    user.update!(locale: "en", appearance: "light")
    visit root_path
    choose_landing_locale("日本語")
    choose_appearance("dark")

    sign_in_with_password(user, heading: "ログイン")
    assert_selector "html[lang='ja'][data-appearance='dark']"
    assert_text "ログインしました。"
    assert_equal DARK_CANVAS, body_background
    assert_equal [ "ja", "dark" ], user.reload.values_at(:locale, :appearance)

    within("aside#app-sidebar") { click_button "ログアウト" }
    visit root_path
    assert_selector "html[lang='ja'][data-appearance='dark']"
    assert_equal DARK_CANVAS, page.evaluate_script("getComputedStyle(document.querySelector('.landing-page')).backgroundColor")
  end

  test "Light chosen on the login page travels with Google sign-in without a reload" do
    user = users(:normal)
    user.update!(locale: "vi", appearance: "dark")
    user.federated_identities.create!(provider: "google", provider_uid: "system-google")
    install_google_identity_stand_in

    with_google_verifier(NonceEchoVerifier.new(subject: "system-google", email: user.email)) do
      visit login_path
      assert_selector "button[data-theme='outline']"
      within("header") { select "Tiếng Việt", from: "Interface language" }
      assert_selector "html[lang='vi']"
      choose_appearance("light")
      assert_until { GoogleIdentity::Ceremony.resolve(gis_nonces.last)&.preference_overrides == { "locale" => "vi", "appearance" => "light" } }

      click_button "Google stand-in (outline)"
      assert_current_path new_translation_workspace_path
    end
    assert_selector "html[lang='vi'][data-appearance='light']"
    assert_text "Đăng nhập thành công."
    assert_equal [ "vi", "light" ], user.reload.values_at(:locale, :appearance)
  end

  test "System follows the OS on both sides of sign-in and stays stored as System" do
    user = users(:normal)
    user.update!(locale: "vi", appearance: "system")
    emulate_color_scheme("dark")

    sign_in_with_password(user)
    assert_selector "html[lang='vi'][data-appearance='system']"
    assert_equal DARK_CANVAS, body_background
    emulate_color_scheme("light")
    assert_until { body_background != DARK_CANVAS }

    within("aside#app-sidebar") { click_button "Đăng xuất" }
    assert_current_path login_path
    assert_selector "html[data-appearance='system']"
    assert_equal "rgb(255, 255, 255)", body_background
    emulate_color_scheme("dark")
    assert_until { body_background == DARK_CANVAS }
    assert_equal "system", user.reload.appearance
  end

  test "without JavaScript the first signed-in paint already uses the chosen appearance" do
    user = users(:normal)
    user.update!(appearance: "light")
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: true)

    visit login_path
    find(".appearance-menu summary").click
    click_button "Dark"
    assert_selector "html[data-appearance='dark']"
    fill_in "Email", with: user.email
    fill_in "Password", with: "correct horse battery staple"
    within("main") { click_button "Sign in" }

    assert_current_path new_translation_workspace_path
    assert_selector "html[data-appearance='dark']"
    assert_equal DARK_CANVAS, body_background
    assert_equal "dark", user.reload.appearance
  end

  test "repeated sign-in and sign-out cycles leave the page structure unchanged" do
    user = users(:normal)
    cycle = lambda do |appearance|
      sign_in_with_password(user)
      choose_appearance(appearance)
      within("aside#app-sidebar") { find("button[type='submit']", match: :first).click }
      assert_current_path login_path
    end
    # The first cycle attaches Turbo's lazy listeners and the sign-out notice.
    cycle.call("dark")
    baseline = page_footprint

    6.times { |index| cycle.call(index.even? ? "light" : "dark") }
    assert_equal baseline, page_footprint
  end

  private

  def choose_landing_locale(name)
    within(".landing-header .landing-locale") do
      find("summary").click
      click_button name
    end
  end

  # Waits for the save itself, since sign-in must see the stored choice.
  def choose_appearance(value)
    page.execute_script(<<~JS)
      window.__appearanceSaved = null;
      document.addEventListener("appearance:saved", (event) => { window.__appearanceSaved = event.detail.appearance }, { once: true });
      document.querySelector(`.appearance-option[data-appearance='#{value}']`).form.requestSubmit();
    JS
    assert_selector "html[data-appearance='#{value}']"
    assert_until { page.evaluate_script("window.__appearanceSaved") == value }
  end

  def sign_in_with_password(user, heading: nil)
    visit login_path
    assert_selector "h1", text: heading if heading
    find("input[type='email']").fill_in(with: user.email)
    find("input[type='password']").fill_in(with: "correct horse battery staple")
    within("main") { find("input[type='submit']").click }
    assert_current_path new_translation_workspace_path
  end

  def emulate_color_scheme(scheme)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: scheme } ])
  end

  def body_background
    page.evaluate_script("getComputedStyle(document.body).backgroundColor")
  end

  def page_footprint
    browser = page.driver.browser
    listeners = %w[document window].sum do |target|
      object = browser.execute_cdp("Runtime.evaluate", expression: target, objectGroup: "footprint").dig("result", "objectId")
      browser.execute_cdp("DOMDebugger.getEventListeners", objectId: object).fetch("listeners").size
    end
    browser.execute_cdp("Runtime.releaseObjectGroup", objectGroup: "footprint")
    {
      nodes: page.evaluate_script("document.getElementsByTagName('*').length"),
      stylesheets: page.evaluate_script("document.styleSheets.length"),
      listeners: listeners
    }
  end

  def assert_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end
end
