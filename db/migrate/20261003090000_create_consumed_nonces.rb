class CreateConsumedNonces < ActiveRecord::Migration[8.1]
  def change
    create_table :consumed_nonces do |t|
      t.string :digest, null: false, limit: 64
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
    end

    add_index :consumed_nonces, :digest, unique: true
    add_index :consumed_nonces, :expires_at
    add_check_constraint :consumed_nonces, "digest ~ '^[0-9a-f]{64}$'", name: "consumed_nonces_digest_format"
  end
end
