require "test_helper"
require_relative "../../support/google_identity_test_helper"

class GoogleIdentity::CeremonyTest < ActiveSupport::TestCase
  include GoogleIdentityTestHelper

  test "round-trips server context and rejects tampering and expiry" do
    token = GoogleIdentity::Ceremony.issue(intent: "sign_in", locale: "ja", appearance: "dark", return_path: "/projects/1")
    ceremony = GoogleIdentity::Ceremony.resolve(token)

    assert_equal [ "sign_in", "ja", "dark", "/projects/1" ], [ ceremony.intent, ceremony.locale, ceremony.appearance, ceremony.return_path ]
    assert_nil GoogleIdentity::Ceremony.resolve(token.sub(/.\z/) { |char| char == "a" ? "b" : "a" })
    assert_nil GoogleIdentity::Ceremony.resolve("forged")
    assert_nil GoogleIdentity::Ceremony.resolve(nil)
    travel(GoogleIdentity::Ceremony::TTL + 1.second) { assert_nil GoogleIdentity::Ceremony.resolve(token) }
  end

  test "linking ceremonies must name their user" do
    user = users(:normal)
    assert_raises(ArgumentError) { GoogleIdentity::Ceremony.issue(intent: "link", locale: "en", appearance: "system") }
    assert_raises(ArgumentError) { GoogleIdentity::Ceremony.issue(intent: "admin", locale: "en", appearance: "system") }

    ceremony = GoogleIdentity::Ceremony.resolve(GoogleIdentity::Ceremony.issue(intent: "link", user: user, locale: "en", appearance: "system"))
    assert ceremony.link?
    assert_equal user.id, ceremony.user_id
  end

  test "keeps only same-origin return paths" do
    %w[
      http://evil.example/ https://evil.example //evil.example ///evil.example /\\evil.example
      javascript:alert(1) relative/path
    ].each { |path| assert_nil GoogleIdentity::Ceremony.safe_return_path(path), path }
    assert_nil GoogleIdentity::Ceremony.safe_return_path("/path with space")
    assert_nil GoogleIdentity::Ceremony.safe_return_path("/#{"a" * 250}")
    assert_nil GoogleIdentity::Ceremony.safe_return_path("/%2F%2Fevil.example")
    assert_nil GoogleIdentity::Ceremony.safe_return_path("/no-such-page")
    assert_equal "/projects/1?tab=history", GoogleIdentity::Ceremony.safe_return_path("/projects/1?tab=history")
  end

  test "drops unsupported interface preferences" do
    ceremony = GoogleIdentity::Ceremony.resolve(GoogleIdentity::Ceremony.issue(intent: "sign_in", locale: "xx", appearance: "neon"))
    assert_nil ceremony.locale
    assert_nil ceremony.appearance
  end

  test "each ceremony can be consumed once" do
    ceremony = GoogleIdentity::Ceremony.resolve(GoogleIdentity::Ceremony.issue(intent: "sign_in", locale: "en", appearance: "system"))
    assert ceremony.consume!
    assert_not GoogleIdentity::Ceremony.resolve(GoogleIdentity::Ceremony.issue(intent: "sign_in", locale: "en", appearance: "system")).nil?
    assert_not ceremony.consume!
  end
end
