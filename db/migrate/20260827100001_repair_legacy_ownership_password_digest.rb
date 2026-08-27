require "bcrypt"
require "securerandom"

class RepairLegacyOwnershipPasswordDigest < ActiveRecord::Migration[8.1]
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  def up
    MigrationUser.where(status: "disabled")
      .where.not("password_digest LIKE ?", "$2%")
      .find_each do |user|
        user.update_columns(
          password_digest: BCrypt::Password.create(SecureRandom.hex(64)),
          updated_at: Time.current
        )
      end
  end

  def down
    # Random legacy credentials cannot and should not be restored.
  end
end
