class AddTranslationReferenceCreationIdentity < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    previous = select_value("SHOW lock_timeout")
    connection.execute "SET lock_timeout = '1s'"
    # A timed-out concurrent build may leave an invalid index. Complete this
    # canonical-table step before creating the replay ledger atomically.
    index_name = "index_translation_references_on_owner_and_id"
    valid = select_value("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass(#{connection.quote(index_name)})")
    unless valid == true
      remove_index :translation_references, name: index_name, algorithm: :concurrently if valid == false
      add_index :translation_references, %i[user_id id], unique: true, name: index_name, algorithm: :concurrently
    end
    unless table_exists?(:translation_reference_creations)
      transaction do
        create_table :translation_reference_creations do |t|
          t.references :user, null: false, foreign_key: true, index: false
          t.references :translation_reference, index: { unique: true }
          t.string :creation_key, limit: 512, null: false
          t.string :payload_digest, limit: 64, null: false
          t.string :status, null: false, default: "pending"
          t.text :failure
          t.timestamps
          t.datetime :expires_at, null: false, default: -> { "CURRENT_TIMESTAMP + interval '24 hours'" }
        end
        add_index :translation_reference_creations, [ :user_id, :creation_key ], unique: true,
          name: "index_reference_creations_on_owner_and_key"
        add_index :translation_reference_creations, %i[expires_at id], name: "index_translation_reference_creations_on_expiry"
        add_check_constraint :translation_reference_creations,
          "creation_key ~ '^[0-9a-f]{32}$|^[A-Za-z0-9_-]{16,255}--[0-9a-f]{64}\\.[0-9a-f]{32}$' AND payload_digest ~ '^[0-9a-f]{64}$'",
          name: "reference_creations_identity_check"
        add_check_constraint :translation_reference_creations, <<~SQL.squish, name: "reference_creations_outcome_check"
          (status::text = ANY (ARRAY['pending'::text, 'expired'::text]) AND translation_reference_id IS NULL AND failure IS NULL) OR
          (status = 'completed' AND translation_reference_id IS NOT NULL AND failure IS NULL) OR
          (status = 'failed' AND translation_reference_id IS NULL AND failure IS NOT NULL)
        SQL
        add_check_constraint :translation_reference_creations,
          "failure IS NULL OR octet_length(failure) <= 2097152", name: "reference_creations_failure_size_check"
        add_index :translation_reference_creations, %i[created_at id], where: "status = 'failed'",
          name: "index_reference_creations_on_expiring_failure"
        add_foreign_key :translation_reference_creations, :translation_references,
          column: [ :user_id, :translation_reference_id ], primary_key: [ :user_id, :id ],
          name: "reference_creations_owner_fk", validate: false
        validate_foreign_key :translation_reference_creations, name: "reference_creations_owner_fk"
      end
    end
  ensure
    connection.execute "SET lock_timeout = #{connection.quote(previous)}" if previous
  end
  def down
    previous = select_value("SHOW lock_timeout")
    connection.execute "SET lock_timeout = '1s'"
    drop_table :translation_reference_creations, if_exists: true
    remove_index :translation_references, name: "index_translation_references_on_owner_and_id", algorithm: :concurrently, if_exists: true
  ensure
    connection.execute "SET lock_timeout = #{connection.quote(previous)}" if previous
  end
end
