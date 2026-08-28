require "test_helper"

class ActiveStoragePrivacyTest < ActiveSupport::TestCase
  test "does not expose default blob disk representation or direct-upload routes" do
    paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }

    assert_not paths.any? { |path| path.start_with?("/rails/active_storage") }
  end
end
