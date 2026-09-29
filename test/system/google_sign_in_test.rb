require "application_system_test_case"
require_relative "../support/google_identity_system_helper"

class GoogleSignInSystemTest < ApplicationSystemTestCase
  include GoogleIdentitySystemHelper

  test "Continue with Google signs a new person into the workspace through the redirect callback" do
    install_google_identity_stand_in
    with_google_verifier(NonceEchoVerifier.new) do
      visit login_path
      config = page.evaluate_script("window.__gis.config")
      assert_equal "redirect", config["ux_mode"]
      assert_equal false, config["auto_select"]
      assert_equal "#{page.server_url}/auth/google/callback", config["login_uri"]
      assert_equal GoogleIdentity.client_id, config["client_id"]
      assert GoogleIdentity::Ceremony.resolve(config["nonce"]), "the nonce is a server-issued ceremony"

      click_button "Google stand-in (outline)"
      assert_current_path new_translation_workspace_path
      assert_text "Signed in successfully."
      assert_equal 0, page.evaluate_script("window.__gis.prompted"), "One Tap must never be prompted"
    end

    user = User.find_by!(email: "google.person@gmail.com")
    assert_not user.managed_ai_access?
    assert_equal [ "google" ], user.federated_identities.pluck(:provider)
  end

  test "the button uses a ceremony fetched when shown and is renewed before that ceremony expires" do
    install_google_identity_stand_in
    install_long_timer_capture
    with_google_verifier(NonceEchoVerifier.new) do
      visit login_path
      assert_selector "button[data-theme='outline']"
      first = gis_nonces.last
      assert_equal "sign_in", GoogleIdentity::Ceremony.resolve(first).intent
      assert_equal [ (GoogleIdentity::Ceremony::TTL.to_i - 60) * 1000 ], page.evaluate_script("window.__longTimers.map((timer) => timer.delay)")

      fire_long_timers
      assert_until { gis_nonces.size == 2 }
      renewed = gis_nonces.last
      assert_not_equal first, renewed
      assert GoogleIdentity::Ceremony.resolve(renewed)

      click_button "Google stand-in (outline)"
      assert_current_path new_translation_workspace_path
    end
  end

  test "a ceremony that lapses while the page is hidden is renewed only once the page is visible" do
    install_google_identity_stand_in
    install_long_timer_capture
    visit login_path
    assert_selector "button[data-theme='outline']"

    page.execute_script("Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true })")
    fire_long_timers
    assert_no_selector "[data-google-sign-in-target='button'] button"
    sleep 0.3
    assert_equal 1, gis_nonces.size, "no ceremony is minted for a hidden page"

    page.execute_script("Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true }); document.dispatchEvent(new Event('visibilitychange'))")
    assert_selector "button[data-theme='outline']"
    assert_equal 2, gis_nonces.size
  end

  test "renewal is bounded for a page left open for hours" do
    install_google_identity_stand_in
    install_long_timer_capture
    visit login_path
    assert_selector "button[data-theme='outline']"

    11.times do |renewal|
      fire_long_timers
      assert_until { gis_nonces.size == renewal + 2 }
    end
    fire_long_timers
    assert_text "This page has been open for a long time. Reload it to continue with Google."
    assert_no_selector "[data-google-sign-in-target='button'] button"
    assert_equal 12, gis_nonces.size
  end

  test "Turbo snapshots never keep a live button and a restored page gets a fresh ceremony" do
    install_google_identity_stand_in
    visit login_path
    assert_selector "button[data-theme='outline']"
    first = gis_nonces.last

    click_link "Create account"
    assert_current_path new_registration_path
    assert_selector "button[data-theme='outline']"
    cached_button = page.evaluate_script(<<~JS)
      (() => {
        const snapshot = window.Turbo.session.view.snapshotCache.snapshots["#{page.server_url}/login"];
        return snapshot ? snapshot.element.querySelectorAll("[data-google-sign-in-target='button'] *").length : null;
      })()
    JS
    assert_equal 0, cached_button, "the cached login snapshot holds no Google button"

    go_back
    assert_current_path login_path
    assert_selector "button[data-theme='outline']"
    restored = gis_nonces.last
    assert_not_equal first, restored
    assert_equal "sign_in", GoogleIdentity::Ceremony.resolve(restored).intent
  end

  test "a saved signed-out theme choice re-mints a ceremony carrying it, and a language switch mints one too" do
    install_google_identity_stand_in
    visit login_path
    assert_selector "button[data-theme='outline']"
    ceremony = gis_nonces.last

    find(".appearance-menu summary").click
    click_button "Dark"
    assert_selector "button[data-theme='filled_black']"
    assert_until { gis_nonces.size == 2 }
    renewed = GoogleIdentity::Ceremony.resolve(gis_nonces.last)
    assert_equal({ "appearance" => "dark" }, renewed.preference_overrides, "the explicit choice travels with Google sign-in")
    assert_empty GoogleIdentity::Ceremony.resolve(ceremony).preference_overrides

    within("header") { select "日本語", from: "Interface language" }
    assert_selector "html[lang='ja']"
    assert_selector "button[data-theme='filled_black']"
    assert_equal "ja", GoogleIdentity::Ceremony.resolve(gis_nonces.last).locale
  end

  test "the official button follows the resolved appearance" do
    install_google_identity_stand_in
    visit login_path
    assert_selector "button[data-theme='outline']"

    find(".appearance-menu summary").click
    click_button "Dark"
    assert_selector "button[data-theme='filled_black']"

    find(".appearance-menu summary").click
    click_button "System"
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "dark" } ])
    assert_selector "button[data-theme='filled_black']"
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ])
    assert_selector "button[data-theme='outline']"
  ensure
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
  end

  test "email sign-in still works when Google Identity Services cannot load" do
    # Record the GIS script element: it must carry this document's CSP nonce,
    # because GIS copies it onto the <style> it injects.
    recorder = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: <<~JS).fetch("identifier")
      const append = HTMLHeadElement.prototype.append;
      HTMLHeadElement.prototype.append = function (...nodes) {
        for (const node of nodes) if (node.src?.includes("accounts.google.com/gsi/client")) window.__gisScriptNonce = node.nonce;
        return append.apply(this, nodes);
      };
    JS
    visit login_path
    assert_text "Google sign-in is unavailable right now. You can still use your email and password.", wait: 12
    assert_equal page.evaluate_script("document.querySelector('meta[name=csp-nonce]').content"),
                 page.evaluate_script("window.__gisScriptNonce")

    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    within("main") { click_button "Sign in" }
    assert_current_path new_translation_workspace_path
  ensure
    page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: recorder) if recorder
  end

  private

  def assert_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end
end
