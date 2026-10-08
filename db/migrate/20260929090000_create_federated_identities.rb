class CreateFederatedIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :federated_identities do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :provider, null: false
      t.string :provider_uid, null: false
      t.timestamps
    end

    add_index :federated_identities, %i[provider provider_uid], unique: true
    add_index :federated_identities, %i[user_id provider], unique: true
    add_check_constraint :federated_identities, "provider IN ('google')", name: "federated_identities_provider_check"
    add_check_constraint :federated_identities,
                         "char_length(provider_uid) BETWEEN 1 AND 255",
                         name: "federated_identities_provider_uid_length_check"
  end
end
