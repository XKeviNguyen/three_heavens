class AddPublicAccountAccessFields < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :email_verified_at, :datetime
    add_column :users, :confirmation_sent_at, :datetime
    add_column :users, :locale, :string, null: false, default: "en"
    add_column :users, :managed_ai_access, :boolean, null: false, default: false

    execute "UPDATE users SET email_verified_at = CURRENT_TIMESTAMP"
    add_check_constraint :users, "locale IN ('en', 'vi', 'ja')", name: "users_locale_check"
  end

  def down
    remove_check_constraint :users, name: "users_locale_check"
    remove_column :users, :managed_ai_access
    remove_column :users, :locale
    remove_column :users, :confirmation_sent_at
    remove_column :users, :email_verified_at
  end
end
