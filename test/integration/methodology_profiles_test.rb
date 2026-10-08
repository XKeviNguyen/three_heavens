require "test_helper"
require_relative "../support/methodology_profile_test_helper"

class MethodologyProfilesTest < ActionDispatch::IntegrationTest
  include MethodologyProfileTestHelper

  setup { sign_in_as users(:normal) }

  test "owner creates revises archives and reactivates a private methodology" do
    assert_difference -> { MethodologyProfile.count }, 1 do
      post methodology_profiles_path, params: { methodology_profile: methodology_profile_attributes }
    end
    profile = MethodologyProfile.order(:id).last
    assert_redirected_to methodology_profile_path(profile)
    follow_redirect!
    assert_response :success
    assert_select "h1", text: "Faithful literary methodology"
    assert_select "h2", text: /Version 1 · Current/
    assert_includes response.body, profile.current_revision.configuration_digest

    get methodology_profiles_path
    assert_response :success
    assert_select "h2", text: "Faithful literary methodology"

    assert_difference -> { MethodologyProfileRevision.count }, 1 do
      patch methodology_profile_path(profile), params: {
        methodology_profile: methodology_profile_attributes(
          name: "Revision two",
          guidance: "Revised guidance"
        ).merge(expected_version: "1")
      }
    end
    assert_equal 2, profile.reload.current_revision.version

    patch deactivate_methodology_profile_path(profile)
    assert_not profile.reload.active?
    patch activate_methodology_profile_path(profile)
    assert profile.reload.active?

    other = create_methodology_profile(user: users(:other))
    get methodology_profile_path(other)
    assert_response :not_found
    get edit_methodology_profile_path(other)
    assert_response :not_found
  end

  test "strict parameters and stale edits fail closed" do
    profile = create_methodology_profile

    patch methodology_profile_path(profile), params: {
      methodology_profile: methodology_profile_attributes.merge(expected_version: "0")
    }
    assert_response :conflict
    assert_equal 1, profile.revisions.count

    [
      { methodology_profile: "bad" },
      { methodology_profile: methodology_profile_attributes.merge(user_id: users(:other).id) },
      { methodology_profile: methodology_profile_attributes.merge(guidance: [ "bad" ]) }
    ].each do |payload|
      assert_no_difference -> { MethodologyProfile.count } do
        post methodology_profiles_path, params: payload
      end
      assert_response :bad_request
    end
  end
end
