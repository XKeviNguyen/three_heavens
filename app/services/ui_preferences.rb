# Interface language and appearance for one browser, across signing in and out.
#
# - ui_locale / ui_appearance cookies are what a signed-out visitor sees.
# - A change made while signed out is also recorded, signed, as a pending
#   override. At the next sign-in it becomes the account's preference;
#   without one, the account's stored preferences win (defaults such as
#   Accept-Language or the OS theme never overwrite an account).
# - Signed-in changes are saved to the account. The account's values are
#   mirrored to the cookies at sign-in and each change is written to its
#   cookie, so signing out keeps the same look without creating an override.
#
# Language and appearance changes are separate requests that can overlap, and
# each response's cookies replace the browser's. Every cookie therefore holds
# one preference and is written only by a change to that preference, so a
# response can never carry an older value of the other one.
#
# Only these two allowlisted values are handled; nothing here can affect
# identity, authorization, or any other account attribute.
class UiPreferences
  LOCALE_COOKIE = :ui_locale
  APPEARANCE_COOKIE = :ui_appearance
  OVERRIDE_COOKIES = { "locale" => :ui_locale_override, "appearance" => :ui_appearance_override }.freeze
  # The browser numbers its appearance choices in the order made. The latest
  # saved number is rendered with every page, so a page rendered before a
  # newer choice was saved (a slow or prefetched visit) is recognized as older
  # instead of switching the appearance back.
  APPEARANCE_REVISION_COOKIE = :ui_appearance_revision
  # At most 15 digits, so every revision is an exact JavaScript number.
  APPEARANCE_REVISION_FORMAT = /\A[1-9][0-9]{0,14}\z/
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

  def appearance_revision
    value = @cookies[APPEARANCE_REVISION_COOKIE].to_s
    value.match?(APPEARANCE_REVISION_FORMAT) ? Integer(value, 10) : 0
  end

  def record_appearance_revision(revision)
    revision = revision.to_s
    raise ArgumentError, "invalid appearance revision" unless revision.match?(APPEARANCE_REVISION_FORMAT)

    write(APPEARANCE_REVISION_COOKIE, revision, expires: 1.year.from_now)
  end

  def pending_overrides
    self.class.sanitize(OVERRIDE_COOKIES.transform_values { |name| @cookies.signed[name] })
  end

  # A signed-out visitor's explicit choice: shown now, applied at next sign-in.
  def choose_as_guest(**choices)
    choices = self.class.sanitize(choices)
    write_display(choices)
    choices.each { |key, value| write(OVERRIDE_COOKIES.fetch(key), value, signed: true, expires: 30.days.from_now) }
  end

  # A signed-in user's choice: saved to the account and kept for after sign-out.
  def choose_as_user(user, **choices)
    choices = self.class.sanitize(choices)
    user.update!(choices)
    write_display(choices)
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
    OVERRIDE_COOKIES.each_value { |name| write(name, "", expires: Time.at(0)) }
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
