class AddUploadAttemptAdmission < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '1s'"
    add_column :upload_budgets, :attempt_window_id, :bigint, null: false, default: 0
    add_column :upload_budgets, :attempt_count, :integer, null: false, default: 0
    add_check_constraint :upload_budgets, "attempt_count >= 0 AND attempt_count <= 30",
      name: "upload_budgets_attempt_count_bounds"
  end

  def down
    execute "SET LOCAL lock_timeout = '1s'"
    remove_check_constraint :upload_budgets, name: "upload_budgets_attempt_count_bounds"
    remove_column :upload_budgets, :attempt_count
    remove_column :upload_budgets, :attempt_window_id
  end
end
