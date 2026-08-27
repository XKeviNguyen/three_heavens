require "securerandom"
require "bcrypt"

class CreateUsersAndAddProjectOwnership < ActiveRecord::Migration[8.1]
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  def up
    create_table :users do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.string :role, null: false, default: "user"
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    add_index :users, "LOWER(email)", unique: true, name: "index_users_on_lower_email"
    add_check_constraint :users,
                         "email = LOWER(BTRIM(email)) AND char_length(email) BETWEEN 3 AND 254",
                         name: "users_normalized_email_check"
    add_check_constraint :users,
                         "role IN ('user', 'admin')",
                         name: "users_role_check"
    add_check_constraint :users,
                         "status IN ('active', 'disabled')",
                         name: "users_status_check"

    add_reference :projects, :user, index: true

    if project_model.exists?
      legacy_owner = MigrationUser.create!(
        email: "legacy-ownership-#{SecureRandom.uuid}@invalid.local",
        password_digest: BCrypt::Password.create(SecureRandom.hex(64)),
        role: "user",
        status: "disabled",
        created_at: Time.current,
        updated_at: Time.current
      )
      project_model.where(user_id: nil).update_all(user_id: legacy_owner.id)
    end

    change_column_null :projects, :user_id, false
    add_foreign_key :projects, :users, on_delete: :restrict
  end

  def down
    remove_foreign_key :projects, :users
    remove_reference :projects, :user, index: true
    drop_table :users
  end

  private

  def project_model
    @project_model ||= Class.new(ActiveRecord::Base) do
      self.table_name = "projects"
    end
  end
end
