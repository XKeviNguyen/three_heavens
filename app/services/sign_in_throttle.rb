# Per-account budget keys for password sign-in rate limits; the per-network
# budget is ApplicationController#client_network.
#
# Rotating forwarding headers or addresses cannot buy more guesses against one
# account. A browser that has signed in to the account before holds a device
# cookie and gets its own budget instead, so failed attempts from elsewhere
# cannot lock the owner out of a browser they already use (OWASP device
# cookies); only browsers new to the account share the account budget.
module SignInThrottle
  DEVICE_COOKIE = :sign_in_device
  DEVICE_COOKIE_LIFETIME = 1.year

  module_function

  def account_key(cookies, submitted_email)
    account = account_digest(submitted_email)
    device = known_device(cookies)
    device && ActiveSupport::SecurityUtils.secure_compare(device["a"], account) ? "device:#{device["d"]}" : account
  end

  def remember_device(cookies, user)
    cookies.encrypted[DEVICE_COOKIE] = {
      value: { "a" => account_digest(user.email), "d" => SecureRandom.hex(16) }.to_json,
      expires: DEVICE_COOKIE_LIFETIME.from_now, httponly: true, same_site: :lax, secure: Rails.env.production?
    }
  end

  # Keyed so the shared cache never holds an email address or a digest that a
  # list of candidate addresses could reverse. Non-string and over-long
  # submissions, which never authenticate, share the blank-email budget.
  def account_digest(email)
    email = "" unless email.is_a?(String) && email.length <= User::MAXIMUM_EMAIL_LENGTH
    OpenSSL::HMAC.hexdigest("SHA256", digest_key, User.normalize_value_for(:email, email).to_s)
  end

  def known_device(cookies)
    device = JSON.parse(cookies.encrypted[DEVICE_COOKIE].to_s)
    device if device.is_a?(Hash) && device["a"].is_a?(String) && device["d"].is_a?(String)
  rescue JSON::ParserError
    nil
  end

  def digest_key
    Rails.application.key_generator.generate_key("sign_in_throttle/account", 32)
  end
end
