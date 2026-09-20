require "test_helper"

class Operations::ReleaseIdentityTest < ActiveSupport::TestCase
  test "returns only a safe release SHA" do
    assert_equal "abcdef1234567", Operations::ReleaseIdentity.call(environment: { "RELEASE_SHA" => "abcdef1234567" })
    assert_equal "unknown", Operations::ReleaseIdentity.call(environment: { "KAMAL_VERSION" => "private release value" })
    assert_equal "0123456789abcdef", Operations::ReleaseIdentity.call(
      environment: { "KAMAL_VERSION" => "release-label", "RELEASE_SHA" => "0123456789abcdef" }
    )
  end
end
