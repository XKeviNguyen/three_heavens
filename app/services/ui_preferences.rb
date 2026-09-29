# Interface language and appearance for one browser, across signing in and out.
#
# - ui_locale / ui_appearance cookies are what a signed-out visitor sees.
# - A change made while signed out is also recorded, signed, as a pending
#   override. At the next sign-in it becomes the account's preference;
#   without one, the account's stored preferences win (defaults such as
#   Accept-Language or the OS theme never overwrite an account).
# - Signed-in changes are saved to the account. The account's values are
#   mirrored to the cookies at sign-in, on every change and at sign-out, so
#   signing out keeps the same look without creating an override.
#
# Only these two allowlisted values are handled; nothing here can affect
# identity, authorization, or any other account attribute.
class UiPreferences
  LOCALE_COOKIE = :ui_locale
  APPEARANCE_COOKIE = :ui_appearance
  OVERRIDE_COOKIE = :ui_preference_override
  ALLOWED = { "locale" => User::SUPPORTED_LOCALES, "appearance" => User::APPEARANCES }.freeze

  def self.sanitize(values)
    return {} unless values.respond_to?(:to_h)

    values.to_h.to_h { |key, value| [ key.to_s, value.to_s ] }
      .select { |key, value| ALLOWED.fetch(key, []).include?(value) }
  end

  def initialize(cookies)
    @cookies = cookies
  end

  def locale
    @cookies[LOCALE_COOKIE].presence_in(User::SUPPORTED_LOCALES)
  end

  def appearance
    @cookies[APPEARANCE_COOKIE].presence_in(User::APPEARANCES)
  end

  def pending_overrides
    self.class.sanitize(JSON.parse(@cookies.signed[OVERRIDE_COOKIE].to_s))
  rescue JSON::ParserError
    {}
  end

  # A signed-out visitor's explicit choice: shown now, applied at next sign-in.
  def choose_as_guest(**choices)
    choices = self.class.sanitize(choices)
    write_display(choices)
    write(OVERRIDE_COOKIE, pending_overrides.merge(choices).to_json, signed: true, expires: 30.days.from_now)
  end

  # A signed-in user's choice: saved to the account and kept for after sign-out.
  def choose_as_user(user, **choices)
    user.update!(self.class.sanitize(choices))
    mirror(user)
    clear_overrides
  end

  # At sign-in, explicit signed-out choices become the account's preferences.
  def apply_at_sign_in(user, overrides = pending_overrides)
    overrides = self.class.sanitize(overrides)
    user.update!(overrides) if overrides.any?
    mirror(user)
    clear_overrides
  end

  def mirror(user)
    write_display("locale" => user.locale, "appearance" => user.appearance)
  end

  # Written unconditionally: cookies.delete is a no-op when the request did not
  # carry the cookie, as with Google's cross-site sign-in callback.
  def clear_overrides
    write(OVERRIDE_COOKIE, "", expires: Time.at(0))
  end

  private

  def write_display(values)
    write(LOCALE_COOKIE, values["locale"], expires: 1.year.from_now) if values["locale"]
    write(APPEARANCE_COOKIE, values["appearance"], expires: 1.year.from_now) if values["appearance"]
  end

  def write(name, value, expires:, signed: false)
    options = { value: value, expires: expires, httponly: true, same_site: :lax, secure: Rails.env.production? }
    signed ? @cookies.signed[name] = options : @cookies[name] = options
  end
end
