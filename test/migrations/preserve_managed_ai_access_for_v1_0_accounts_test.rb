require "test_helper"
require Rails.root.join("db/migrate/20260930090000_preserve_managed_ai_access_for_v1_0_accounts")

class PreserveManagedAiAccessForV10AccountsTest < ActiveSupport::TestCase
  PASSWORD = "migration test password"

  setup do
    User.update_all(managed_ai_access: false)
    upgraded_at = Time.zone.parse("2026-09-24 09:01:00")
    # The state 20260924090100 leaves every V1.0 account in.
    @v1_account = create_v1_account("v1@example.test", upgraded_at)
    @v1_disabled = create_v1_account("v1-disabled@example.test", upgraded_at, status: :disabled)
    @v1_admin = create_v1_account("v1-admin@example.test", upgraded_at, role: :admin)
    # V1.1 self-service sign-ups, confirmed and not yet confirmed.
    @registered = create_user("registered@example.test", email_verified_at: Time.current, confirmation_sent_at: 1.hour.ago)
    @unconfirmed = create_user("unconfirmed@example.test", confirmation_sent_at: 1.hour.ago)
    @google = User.new(email: "google@example.test", role: :user, status: :active, email_verified_at: Time.current)
    @google.federated_identities.build(provider: "google", provider_uid: "google-subject-1")
    @google.save!
    # An operator-created account that never received verification.
    @unverified_operator = create_user("unverified-admin@example.test", role: :admin)
  end

  test "restores managed access for V1.0 accounts only and is idempotent" do
    run_migration

    assert_equal [ true, true, true ], [ @v1_account, @v1_disabled, @v1_admin ].map { |user| user.reload.managed_ai_access }
    assert_equal [ false, false, false, false ],
                 [ @registered, @unconfirmed, @google, @unverified_operator ].map { |user| user.reload.managed_ai_access }
    assert Ai::ManagedAccess.allowed?(@v1_account)
    assert_not Ai::ManagedAccess.allowed?(@v1_disabled), "a disabled account stays blocked by its status"

    assert_no_changes -> { User.order(:id).pluck(:id, :managed_ai_access, :updated_at) } do
      run_migration
    end
  end

  # Codex review of the first version: an administrator's decision made after
  # the earlier migration ran must never be overridden.
  test "an explicit access decision after the upgrade is never overridden" do
    @v1_admin.update!(managed_ai_access: true)
    @v1_admin.update!(managed_ai_access: false) # granted, then revoked
    changed = create_v1_account("v1-changed@example.test", @v1_account.email_verified_at)
    changed.update!(locale: "ja")

    run_migration

    assert_equal [ false, false ], [ @v1_admin, changed ].map { |user| user.reload.managed_ai_access }
    assert @v1_account.reload.managed_ai_access, "an untouched V1.0 account is still restored"
  end

  test "rolling back and migrating again does not re-grant a revocation" do
    run_migration
    @v1_account.reload.update!(managed_ai_access: false)

    run_migration(:down)
    run_migration

    assert_not @v1_account.reload.managed_ai_access
  end

  test "accounts that sign up after the upgrade keep the restricted default" do
    run_migration
    later = create_user("later@example.test", email_verified_at: Time.current, confirmation_sent_at: 1.minute.ago)

    assert_not later.reload.managed_ai_access
    assert_not Ai::ManagedAccess.allowed?(later)
  end

  test "rolling back leaves access decisions unchanged" do
    run_migration

    assert_no_changes -> { User.order(:id).pluck(:id, :managed_ai_access) } do
      run_migration(:down)
    end
  end

  private

  # As 20260924090100 leaves a V1.0 account: verified at the upgrade, last
  # updated before it.
  def create_v1_account(email, upgraded_at, **attributes)
    user = create_user(email, email_verified_at: upgraded_at, **attributes)
    user.update_columns(created_at: upgraded_at - 30.days, updated_at: upgraded_at - 1.day)
    user
  end

  def create_user(email, role: :user, status: :active, **attributes)
    User.create!(email:, password: PASSWORD, role:, status:, **attributes)
  end

  def run_migration(direction = :up)
    migration = PreserveManagedAiAccessForV10Accounts.new
    migration.define_singleton_method(:connection) { ActiveRecord::Base.connection }
    migration.suppress_messages { migration.migrate(direction) }
  end
end
