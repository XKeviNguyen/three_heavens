# V1.0 had no public sign-up: every account was provisioned by an operator and
# could use the server-managed AI provider. 20260924090100 added
# users.managed_ai_access with a false default, which removed that capability
# from every V1.0 account on upgrade.
#
# This restores it for exactly the accounts in the state that migration left
# V1.0 accounts in, a state no V1.1 sign-up produces: a password, marked
# verified by that migration, never sent a confirmation email (self-service
# registration always records one), and no federated identity (Google sign-up
# always creates one). Accounts created later keep the false default, and
# running this again changes nothing.
class PreserveManagedAiAccessForV10Accounts < ActiveRecord::Migration[8.1]
  def up
    restored = update(<<~SQL.squish)
      UPDATE users SET managed_ai_access = true
      WHERE managed_ai_access = false
        AND password_digest IS NOT NULL
        AND email_verified_at IS NOT NULL
        AND confirmation_sent_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM federated_identities WHERE federated_identities.user_id = users.id)
    SQL
    say "Restored managed AI access for #{restored} V1.0 account(s)"
  end

  # Rolling back leaves access as it is: after the upgrade an administrator
  # may have granted or revoked it, and a blanket revocation would repeat the
  # original regression. Revoke individual accounts in Settings > Users.
  def down
  end
end
