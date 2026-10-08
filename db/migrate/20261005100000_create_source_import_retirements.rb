class CreateSourceImportRetirements < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    previous = select_value("SHOW lock_timeout")
    connection.execute "SET lock_timeout = '1s'"
    unless table_exists?(:source_import_retirements)
      transaction do
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
      end
    end
  ensure
    connection.execute "SET lock_timeout = #{connection.quote(previous)}" if previous
  end
  def down
    previous = select_value("SHOW lock_timeout")
    connection.execute "SET lock_timeout = '1s'"
    drop_table :source_import_retirements, if_exists: true
  ensure
    connection.execute "SET lock_timeout = #{connection.quote(previous)}" if previous
  end
end
