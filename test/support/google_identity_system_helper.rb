require_relative "google_identity_test_helper"

# Browser-side stand-in for Google Identity Services. It records how the page
# configures GIS and, when its button is pressed, posts to login_uri the way
# GIS redirect mode does: a g_csrf_token cookie plus matching form fields. The
# credential carries the page's nonce so NonceEchoVerifier can return claims
# bound to the real server-issued ceremony.
module GoogleIdentitySystemHelper
  include GoogleIdentityTestHelper

  STAND_IN = <<~JS.freeze
    window.__gis = { initialized: [], rendered: [], prompted: 0 };
    window.google = { accounts: { id: {
      initialize(config) { window.__gis.initialized.push(config); window.__gis.config = config; },
      prompt() { window.__gis.prompted += 1; },
      renderButton(element, options) {
        window.__gis.rendered.push(options);
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = "Google stand-in (" + options.theme + ")";
        button.dataset.theme = options.theme;
        button.addEventListener("click", () => {
          const config = window.__gis.config;
          document.cookie = "g_csrf_token=stand-in-csrf; path=/";
          const form = document.createElement("form");
          form.method = "post";
          form.action = config.login_uri;
          const fields = { credential: "stand-in." + btoa(config.nonce) + ".sig", g_csrf_token: "stand-in-csrf", select_by: "btn" };
          for (const [name, value] of Object.entries(fields)) {
            const input = document.createElement("input");
            input.type = "hidden"; input.name = name; input.value = value;
            form.append(input);
          }
          document.body.append(form);
          form.submit();
        });
        element.replaceChildren(button);
      }
    } } };
  JS

  # Returns claims for a fixed Google person, bound to the nonce the page sent.
  class NonceEchoVerifier
    def initialize(subject: "109876543210987654321", email: "google.person@gmail.com")
      @subject = subject
      @email = email
    end

    def verify(credential)
      nonce = Base64.decode64(credential.to_s.split(".")[1].to_s)
      GoogleIdentity::TokenVerifier::Claims.new(subject: @subject, email: @email, email_verified: true, hosted_domain: nil, nonce: nonce)
    end
  end

  # Lets a test fire the ceremony-expiry timer instead of waiting minutes.
  LONG_TIMER_CAPTURE = <<~JS.freeze
    window.__longTimers = [];
    const realSetTimeout = window.setTimeout;
    window.setTimeout = function (callback, delay, ...rest) {
      if (delay >= 60000) { window.__longTimers.push({ callback, delay }); return -1; }
      return realSetTimeout(callback, delay, ...rest);
    };
  JS

  # CDP keeps injected scripts for the whole browser session, so remove them.
  def self.included(base)
    base.teardown do
      remove_google_identity_stand_in
      @injected_scripts&.each { |identifier| page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: identifier) }
    end
  end

  def install_long_timer_capture
    (@injected_scripts ||= []) << page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: LONG_TIMER_CAPTURE).fetch("identifier")
  end

  def fire_long_timers
    page.execute_script("window.__longTimers.splice(0).forEach((timer) => timer.callback())")
  end

  def gis_nonces
    page.evaluate_script("window.__gis.initialized.map((config) => config.nonce)")
  end

  def install_google_identity_stand_in
    @google_stand_in = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: STAND_IN).fetch("identifier")
  end

  def remove_google_identity_stand_in
    return unless @google_stand_in

    page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: @google_stand_in)
    @google_stand_in = nil
  end
end
