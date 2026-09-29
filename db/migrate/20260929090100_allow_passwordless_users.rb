# Accounts created through Sign in with Google have no password. Rolling back
# requires those accounts to set a password first, so down fails loudly if any exist.
class AllowPasswordlessUsers < ActiveRecord::Migration[8.1]
  def change
    change_column_null :users, :password_digest, true
  end
end
