# The app-wide (managed) OpenRouter API key, set by an admin in the app. Each
# row is one key version: saving a key creates a row, and replacing or
# deleting it revokes that row and erases its ciphertext. At most one
# unrevoked row exists. Without one, managed AI work uses OPENROUTER_API_KEY.
class CreateManagedOpenRouterKeys < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '1s'"
    create_table :managed_open_router_keys do |t|
      # Active Record Encryption ciphertext; NULL once revoked.
      t.text :api_key
      t.string :key_hint
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
      t.datetime :revoked_at
      t.string :revocation_reason
      t.timestamps
    end

    execute <<~SQL
      CREATE UNIQUE INDEX index_managed_open_router_keys_one_active
      ON managed_open_router_keys ((true)) WHERE revoked_at IS NULL
    SQL
    add_check_constraint :managed_open_router_keys,
      "(revoked_at IS NULL AND api_key IS NOT NULL AND revocation_reason IS NULL) OR " \
      "(revoked_at IS NOT NULL AND api_key IS NULL AND revocation_reason IS NOT NULL " \
      "AND (revocation_reason = 'replaced' OR revocation_reason = 'deleted'))",
      name: "managed_open_router_keys_lifecycle_check"
    add_check_constraint :managed_open_router_keys,
      "api_key IS NULL OR char_length(api_key) <= 4096",
      name: "managed_open_router_keys_ciphertext_length_check"
    add_check_constraint :managed_open_router_keys,
      "key_hint IS NULL OR char_length(key_hint) <= 16",
      name: "managed_open_router_keys_key_hint_length_check"
  end

  def down
    drop_table :managed_open_router_keys
  end
end
