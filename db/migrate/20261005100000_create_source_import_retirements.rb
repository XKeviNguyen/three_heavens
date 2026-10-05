class CreateSourceImportRetirements < ActiveRecord::Migration[8.1]
  def change
    create_table :source_import_retirements do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.string :request_key, limit: 32, null: false
      t.datetime :created_at, null: false
    end
    add_index :source_import_retirements, %i[user_id request_key], unique: true,
      name: "index_source_import_retirements_on_owner_and_key"
    add_check_constraint :source_import_retirements, "request_key ~ '^[0-9a-f]{32}$'",
      name: "source_import_retirements_request_key_check"
  end
end
