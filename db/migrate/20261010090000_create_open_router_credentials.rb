# A user's own OpenRouter API key (bring your own key). Each row is one key
# version: adding a key creates a row, and replacing or deleting it revokes
# that row, erasing its ciphertext, while keeping the row so work authorized
# under it keeps a stable credential identity and fails closed. At most one
# unrevoked row exists per user.
class CreateOpenRouterCredentials < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '1s'"
    create_table :open_router_credentials do |t|
      t.references :user, null: false, foreign_key: true, index: true
      # Active Record Encryption ciphertext; NULL once revoked.
      t.text :api_key
      t.string :key_hint
      t.datetime :revoked_at
      t.string :revocation_reason
      t.timestamps
    end

    add_index :open_router_credentials, :user_id, unique: true, where: "revoked_at IS NULL",
      name: "index_open_router_credentials_one_active_per_user"
    add_check_constraint :open_router_credentials,
      "(revoked_at IS NULL AND api_key IS NOT NULL AND revocation_reason IS NULL) OR " \
      "(revoked_at IS NOT NULL AND api_key IS NULL AND revocation_reason IS NOT NULL " \
      "AND (revocation_reason = 'replaced' OR revocation_reason = 'deleted'))",
      name: "open_router_credentials_lifecycle_check"
    add_check_constraint :open_router_credentials,
      "api_key IS NULL OR char_length(api_key) <= 4096",
      name: "open_router_credentials_ciphertext_length_check"
    add_check_constraint :open_router_credentials,
      "key_hint IS NULL OR char_length(key_hint) <= 16",
      name: "open_router_credentials_key_hint_length_check"
  end

  def down
    drop_table :open_router_credentials
  end
end
