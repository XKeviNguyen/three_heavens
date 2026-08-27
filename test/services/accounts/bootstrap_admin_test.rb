require "test_helper"

class Accounts::BootstrapAdminTest < ActiveSupport::TestCase
  test "creates an active admin from supplied operator values" do
    admin = nil

    assert_difference -> { User.count }, 1 do
      admin = Accounts::BootstrapAdmin.call(
        email: "  Operator@Example.TEST ",
        password: "operator supplied secure password"
      )
    end

    assert_equal "operator@example.test", admin.email
    assert admin.admin?
    assert admin.active?
    assert admin.authenticate("operator supplied secure password")
  end

  test "requires both environment-supplied values and creates nothing when absent" do
    assert_no_difference -> { User.count } do
      assert_raises Accounts::BootstrapAdmin::ConfigurationError do
        Accounts::BootstrapAdmin.call(email: nil, password: nil)
      end
    end
  end

  test "initial admin safely claims projects held by the disabled migration owner" do
    legacy_owner = User.create!(
      email: "legacy-ownership-#{SecureRandom.uuid}@invalid.local",
      password: SecureRandom.hex(32),
      status: :disabled
    )
    project = Project.create!(
      user: legacy_owner,
      name: "Preserved historical project",
      source_language: "Vietnamese",
      target_language: "English"
    )

    admin = Accounts::BootstrapAdmin.call(
      email: "history-operator@example.test",
      password: "operator supplied secure password"
    )

    assert_equal admin, project.reload.user
    assert legacy_owner.reload.disabled?
  end
end
