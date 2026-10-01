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

  # A language change is a Turbo visit to a page the server renders with the
  # appearance it holds at that moment. Holding that page in the browser
  # while a newer appearance is chosen and saved makes the visit render an
  # older appearance than the latest saved choice, deterministically.
  test "a language page rendered before a newer appearance was saved does not revert it" do
    user = users(:normal)
    user.update!(locale: "en", appearance: "light")
    visit root_path
    hold_fetch("/locale", until_released: :response)

    choose_landing_locale("日本語")
    assert_until { held_fetch_state("/locale") == "served" }
    choose_appearance("dark")
    release_fetch("/locale")

    assert_selector "html[lang='ja']"
    assert_appearance_stays("dark")
    sign_in_with_password(user, heading: "ログイン")
    assert_selector "html[lang='ja'][data-appearance='dark']"
    assert_equal [ "ja", "dark" ], user.reload.values_at(:locale, :appearance)
  end

  test "an appearance chosen before a language change but saved after its page was rendered is kept" do
    user = users(:normal)
    user.update!(locale: "en", appearance: "light")
    visit root_path
    hold_fetch("/appearance", until_released: :request)
    hold_fetch("/locale", until_released: :response)

    request_appearance("dark")
    choose_landing_locale("日本語")
    assert_until { held_fetch_state("/locale") == "served" }
    release_fetch("/appearance")
    assert_until { page.evaluate_script("window.__appearanceSaved") == "dark" }
    release_fetch("/locale")

    assert_selector "html[lang='ja']"
    assert_appearance_stays("dark")
    sign_in_with_password(user, heading: "ログイン")
    assert_equal [ "ja", "dark" ], user.reload.values_at(:locale, :appearance)
  end

  test "signed in, rapid appearance changes during a language change end on the last choice through sign-out and sign-in" do
    user = users(:normal)
    user.update!(locale: "en", appearance: "light")
    emulate_color_scheme("dark")
    sign_in_with_password(user)
    hold_fetch("/locale", until_released: :response)

    within("aside#app-sidebar") { select "日本語", from: "Interface language" }
    assert_until { held_fetch_state("/locale") == "served" }
    %w[dark light].each { |appearance| request_appearance(appearance) }
    choose_appearance("system")
    release_fetch("/locale")

    assert_selector "html[lang='ja']"
    assert_appearance_stays("system")
    assert_equal DARK_CANVAS, body_background
    assert_equal [ "ja", "system" ], user.reload.values_at(:locale, :appearance)

    within("aside#app-sidebar") { click_button "ログアウト" }
    assert_current_path login_path
    assert_selector "html[lang='ja'][data-appearance='system']"
    sign_in_with_password(user, heading: "ログイン")
    assert_selector "html[lang='ja'][data-appearance='system']"
    assert_equal [ "ja", "system" ], user.reload.values_at(:locale, :appearance)
  end

  # Tabs share the account and cookies, so a choice saved from one tab must
  # never be overwritten by an earlier choice from another that reached the
  # server later. Tab A's save is held before it is sent while tab B makes a
  # later choice.
  test "an earlier choice from another tab never overwrites a later one" do
    user = users(:normal)
    user.update!(appearance: "light")
    sign_in_with_password(user)
    tab_a = current_window
    tab_b = open_new_window
    within_window(tab_b) { visit new_translation_workspace_path }

    hold_fetch("/appearance", until_released: :request)
    request_appearance("dark")
    within_window(tab_b) { request_appearance("system") }
    release_fetch("/appearance")
    assert_until { page.evaluate_script("window.__appearanceSaved") == "dark" }
    within_window(tab_b) { assert_until { page.evaluate_script("window.__appearanceSaved") == "system" } }

    assert_equal "system", user.reload.appearance
    [ tab_a, tab_b ].each do |tab|
      within_window(tab) do
        visit new_translation_workspace_path
        assert_selector "html[data-appearance='system']"
      end
    end
  ensure
    tab_b&.close
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
    request_appearance(value)
    assert_until { page.evaluate_script("window.__appearanceSaved") == value }
  end

  def request_appearance(value)
    page.execute_script(<<~JS)
      window.__appearanceSaved = null;
      document.addEventListener("appearance:saved", (event) => { window.__appearanceSaved = event.detail.appearance });
      document.querySelector(`.appearance-option[data-appearance='#{value}']`).form.requestSubmit();
    JS
    assert_selector "html[data-appearance='#{value}']"
  end

  # The appearance shown, and the control's state, after every pending
  # response has had the chance to render.
  def assert_appearance_stays(value)
    page.evaluate_async_script("requestAnimationFrame(() => setTimeout(arguments[0], 200))")
    assert_selector "html[data-appearance='#{value}']"
    assert_selector ".appearance-option[data-appearance='#{value}'][aria-pressed='true']", visible: :all
  end

  # Holds the next fetch whose URL contains the fragment until release_fetch:
  # before it is sent (:request), or after the server has answered it and
  # before the page sees the answer (:response). Turbo visits and form
  # submissions, and the appearance saves, all go through window.fetch.
  def hold_fetch(fragment, until_released:)
    page.execute_script(<<~JS, fragment, until_released.to_s)
      const [fragment, stage] = arguments
      if (!window.__heldFetches) {
        window.__heldFetches = {}
        const realFetch = window.fetch
        window.fetch = function (input, init) {
          const url = String(input instanceof Request ? input.url : input)
          const hold = Object.entries(window.__heldFetches).find(([part, held]) => held.state === "armed" && url.includes(part))?.[1]
          if (!hold) return realFetch.call(this, input, init)

          if (hold.stage === "request") {
            hold.state = "held"
            return new Promise((resolve) => { hold.release = () => resolve(realFetch.call(window, input, init)) })
          }
          hold.state = "sent"
          return realFetch.call(this, input, init).then((response) => {
            hold.state = "served"
            return new Promise((resolve) => { hold.release = () => resolve(response) })
          })
        }
      }
      window.__heldFetches[fragment] = { stage, state: "armed" }
    JS
  end

  def held_fetch_state(fragment)
    page.evaluate_script("window.__heldFetches[#{fragment.to_json}].state")
  end

  def release_fetch(fragment)
    assert_until { page.evaluate_script("typeof window.__heldFetches[#{fragment.to_json}].release") == "function" }
    page.execute_script("window.__heldFetches[#{fragment.to_json}].state = 'released'; window.__heldFetches[#{fragment.to_json}].release()")
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
