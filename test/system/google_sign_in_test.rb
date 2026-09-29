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
end
