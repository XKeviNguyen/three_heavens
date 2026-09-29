# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

require "securerandom"

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    # Only the Google Identity Services endpoints needed by the Sign in with
    # Google button, and only when it is configured.
    google = Rails.configuration.x.google_identity.client_id.present?
    policy.script_src :self, *("https://accounts.google.com/gsi/client" if google)
    policy.style_src :self, *("https://accounts.google.com/gsi/style" if google)
    policy.img_src :self, :data
    policy.font_src :self, :data
    policy.connect_src :self, *("https://accounts.google.com/gsi/" if google)
    policy.frame_src :self, "https://accounts.google.com/gsi/" if google
    policy.object_src :none
    policy.base_uri :self
    policy.form_action :self
    policy.frame_ancestors :none
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  # style-src nonces let Google Identity Services and Turbo's progress bar inject
  # their <style> elements (both copy the page nonce) without 'unsafe-inline'.
  config.content_security_policy_nonce_directives = %w[script-src style-src]
  config.content_security_policy_nonce_auto = true
  config.content_security_policy_report_only = false
end
