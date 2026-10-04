class CreateUploadBudgets < ActiveRecord::Migration[8.1]
  def change
    create_table :upload_budgets do |t|
      t.references :user, null: false, index: { unique: true }, foreign_key: true
      t.bigint :window_id, null: false
      t.integer :count, null: false
      t.uuid :receipts, array: true, null: false
    end
    add_check_constraint :upload_budgets, "count >= 0 AND count <= 10", name: "upload_budgets_count_bounds"
    add_check_constraint :upload_budgets, "count = cardinality(receipts)", name: "upload_budgets_receipt_count"
  end
end
