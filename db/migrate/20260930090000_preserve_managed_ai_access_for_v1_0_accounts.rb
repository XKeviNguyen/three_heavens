# V1.0 had no public sign-up: every account was provisioned by an operator and
# could use the server-managed AI provider. 20260924090100 added
# users.managed_ai_access with a false default, which removed that capability
# from every V1.0 account on upgrade.
#
# This restores it for exactly the accounts still in the state that migration
# left V1.0 accounts in, a state no V1.1 sign-up produces: a password, marked
# verified by that migration, never sent a confirmation email (self-service
# registration always records one), no federated identity (Google sign-up
# always creates one), and not updated since that migration marked it
# verified. That migration set email_verified_at without touching
# updated_at, while every later change through the application, including an
# administrator granting or revoking managed access, moves updated_at past
# it, so an explicit access decision is never overridden. Accounts created
# later keep the false default, and running this again changes nothing.
#
# A V1.0 database upgraded directly runs both migrations in one db:prepare
# before any request, so every V1.0 account qualifies. On a database that
# already ran earlier V1.1 code, accounts changed in between (for example a
# new locale or a linked Google identity) keep their current access and can
# be granted in Settings > Users.
class PreserveManagedAiAccessForV10Accounts < ActiveRecord::Migration[8.1]
  def up
    restored = update(<<~SQL.squish)
      UPDATE users SET managed_ai_access = true
      WHERE managed_ai_access = false
        AND password_digest IS NOT NULL
        AND email_verified_at IS NOT NULL
        AND confirmation_sent_at IS NULL
        AND updated_at <= email_verified_at
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
