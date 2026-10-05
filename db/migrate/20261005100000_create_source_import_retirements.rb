class CreateSourceImportRetirements < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    connection.execute "SET lock_timeout = '1s'"
    create_table :source_import_retirements do |t|
      t.references :user, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.string :request_key, limit: 512, null: false
      t.datetime :created_at, null: false
      t.datetime :expires_at, null: false, default: -> { "CURRENT_TIMESTAMP + interval '24 hours'" }
    end
    add_index :source_import_retirements, %i[user_id request_key], unique: true,
      name: "index_source_import_retirements_on_owner_and_key"
    add_index :source_import_retirements, %i[expires_at id], name: "index_source_import_retirements_on_expiry"
    add_check_constraint :source_import_retirements, "request_key ~ '^[0-9a-f]{32}$|^[A-Za-z0-9_-]{16,255}--[0-9a-f]{64}\\.[0-9a-f]{32}$'",
      name: "source_import_retirements_request_key_check"
  ensure
    connection.execute "RESET lock_timeout"
  end
  def down
    connection.execute "SET lock_timeout = '1s'"
    drop_table :source_import_retirements
  ensure
    connection.execute "RESET lock_timeout"
  end
end
