require "test_helper"

class Accounts::BootstrapAdminTest < ActiveSupport::TestCase
  class FakePrompt
    attr_reader :asked_labels, :secret_labels

    def initialize(interactive:, email: nil, password: nil, confirmation: nil)
      @interactive = interactive
      @email = email
      @password = password
      @confirmation = confirmation
      @asked_labels = []
      @secret_labels = []
    end

    def interactive?
      @interactive
    end

    def ask(label)
      asked_labels << label
      @email
    end

    def ask_secret(label)
      secret_labels << label
      label.include?("Confirm") ? @confirmation : @password
    end
  end

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

  test "creates an admin from environment variables without prompting" do
    prompt = FakePrompt.new(interactive: false)
    environment = {
      "THREE_HEAVENS_ADMIN_EMAIL" => "environment@example.test",
      "THREE_HEAVENS_ADMIN_PASSWORD" => "environment supplied secure password"
    }

    admin = Accounts::BootstrapAdmin.call(
      email: nil,
      password: nil,
      environment: environment,
      prompt: prompt
    )

    assert_equal "environment@example.test", admin.email
    assert admin.admin?
    assert_empty prompt.asked_labels
    assert_empty prompt.secret_labels
  end

  test "prompts interactively without echoing the password" do
    prompt = FakePrompt.new(
      interactive: true,
      email: "prompted@example.test",
      password: "prompted secure password",
      confirmation: "prompted secure password"
    )

    admin = Accounts::BootstrapAdmin.call(email: nil, password: nil, environment: {}, prompt: prompt)

    assert_equal "prompted@example.test", admin.email
    assert admin.authenticate("prompted secure password")
    assert_equal [ "Admin email: " ], prompt.asked_labels
    assert_equal [ "Admin password: ", "Confirm admin password: " ], prompt.secret_labels
  end

  test "rejects a mismatched interactive password confirmation without creating an account" do
    prompt = FakePrompt.new(
      interactive: true,
      email: "mismatch@example.test",
      password: "first secure password",
      confirmation: "different secure password"
    )

    assert_no_difference -> { User.count } do
      error = assert_raises Accounts::BootstrapAdmin::ConfigurationError do
        Accounts::BootstrapAdmin.call(email: nil, password: nil, environment: {}, prompt: prompt)
      end
      assert_equal "Admin password confirmation does not match", error.message
    end
  end

  test "fails clearly without prompting when required values are absent and input is not interactive" do
    prompt = FakePrompt.new(interactive: false)

    assert_no_difference -> { User.count } do
      error = assert_raises Accounts::BootstrapAdmin::ConfigurationError do
        Accounts::BootstrapAdmin.call(email: nil, password: nil, environment: {}, prompt: prompt)
      end
      assert_includes error.message, "THREE_HEAVENS_ADMIN_EMAIL"
      assert_includes error.message, "THREE_HEAVENS_ADMIN_PASSWORD"
      assert_includes error.message, "interactive terminal"
    end
    assert_empty prompt.asked_labels
    assert_empty prompt.secret_labels
  end

  test "promotes an existing user to an active administrator with the new password" do
    existing = users(:normal)

    admin = Accounts::BootstrapAdmin.call(
      email: existing.email.upcase,
      password: "replacement secure password"
    )

    assert_equal existing.id, admin.id
    assert admin.reload.admin?
    assert admin.active?
    assert admin.authenticate("replacement secure password")
    assert_not admin.authenticate("correct horse battery staple")
  end

  test "never includes the password in validation errors" do
    password = "Zq7!marker"

    error = assert_raises ActiveRecord::RecordInvalid do
      Accounts::BootstrapAdmin.call(email: "invalid-password@example.test", password: password)
    end

    assert_not_includes error.message, password
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
