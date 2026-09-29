class AddAppearanceToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :appearance, :string, null: false, default: "system"
    add_check_constraint :users, "appearance IN ('system', 'light', 'dark')", name: "users_appearance_check"
  end
end
