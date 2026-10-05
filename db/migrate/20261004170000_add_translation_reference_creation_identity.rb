class AddTranslationReferenceCreationIdentity < ActiveRecord::Migration[8.1]
  def change
    create_table :translation_reference_creations do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :translation_reference, index: { unique: true }
      t.string :creation_key, limit: 32, null: false
      t.string :payload_digest, limit: 64, null: false
      t.string :status, null: false, default: "pending"
      t.text :failure
      t.timestamps
    end
    add_index :translation_reference_creations, [ :user_id, :creation_key ], unique: true,
      name: "index_reference_creations_on_owner_and_key"
    add_check_constraint :translation_reference_creations,
      "creation_key ~ '^[0-9a-f]{32}$' AND payload_digest ~ '^[0-9a-f]{64}$'",
      name: "reference_creations_identity_check"
    add_check_constraint :translation_reference_creations, <<~SQL.squish, name: "reference_creations_outcome_check"
      (status IN ('pending', 'expired') AND translation_reference_id IS NULL AND failure IS NULL) OR
      (status = 'completed' AND translation_reference_id IS NOT NULL AND failure IS NULL) OR
      (status = 'failed' AND translation_reference_id IS NULL AND failure IS NOT NULL)
    SQL
    add_check_constraint :translation_reference_creations,
      "failure IS NULL OR octet_length(failure) <= 2097152", name: "reference_creations_failure_size_check"
    add_index :translation_reference_creations, :created_at, where: "status = 'failed'",
      name: "index_reference_creations_on_expiring_failure"
    # Ownership of the replayed reference is authoritative in PostgreSQL too.
    add_index :translation_references, [ :user_id, :id ], unique: true, name: "index_translation_references_on_owner_and_id"
    add_foreign_key :translation_reference_creations, :translation_references,
      column: [ :user_id, :translation_reference_id ], primary_key: [ :user_id, :id ],
      name: "reference_creations_owner_fk"
  end
end
