require "test_helper"

class ManagedOpenRouterKeyTest < ActiveSupport::TestCase
  KEY = "sk-or-v1-#{"3a" * 32}".freeze
  OTHER_KEY = "sk-or-v1-#{"4b" * 32}".freeze

  setup do
    @admin = users(:admin)
    @original_env_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = "sk-or-v1-server-environment-key"
  end

  teardown { ENV["OPENROUTER_API_KEY"] = @original_env_key }

  test "a saved key replaces the environment key until it is deleted" do
    assert_equal "added", ManagedOpenRouterKey.store!(KEY, by: @admin)
    assert_equal KEY, ManagedOpenRouterKey.effective_api_key

    assert_equal "replaced", ManagedOpenRouterKey.store!(OTHER_KEY, by: @admin)
    assert_equal OTHER_KEY, ManagedOpenRouterKey.effective_api_key
    assert_equal 1, ManagedOpenRouterKey.active.count

    assert_equal "deleted", ManagedOpenRouterKey.delete!
    assert_nil ManagedOpenRouterKey.delete!
    assert_equal "sk-or-v1-server-environment-key", ManagedOpenRouterKey.effective_api_key
  end

  test "revoked versions keep no ciphertext and the stored key is encrypted" do
    ManagedOpenRouterKey.store!(KEY, by: @admin)
    ManagedOpenRouterKey.store!(OTHER_KEY, by: @admin)

    revoked = ManagedOpenRouterKey.where.not(revoked_at: nil).sole
    assert_equal "replaced", revoked.revocation_reason
    assert_nil revoked.read_attribute_before_type_cast(:api_key)
    raw = ManagedOpenRouterKey.connection.select_value("SELECT api_key FROM managed_open_router_keys WHERE revoked_at IS NULL")
    assert_not_includes raw, OTHER_KEY
    assert_equal "…#{OTHER_KEY.last(4)}", ManagedOpenRouterKey.current.key_hint
    assert_not_includes ManagedOpenRouterKey.current.inspect, OTHER_KEY.last(8)
  end

  test "the database allows one active key" do
    ManagedOpenRouterKey.store!(KEY, by: @admin)

    assert_raises(ActiveRecord::RecordNotUnique) { ManagedOpenRouterKey.create!(api_key: OTHER_KEY) }
  end

  test "an undecryptable saved key falls back to the environment key" do
    ManagedOpenRouterKey.store!(KEY, by: @admin)
    # Raw SQL: as after a secret_key_base rotation without re-encryption.
    ManagedOpenRouterKey.connection.execute(
      "UPDATE managed_open_router_keys SET api_key = '{\"p\":\"bm90LWNpcGhlcnRleHQ=\",\"h\":{}}' WHERE revoked_at IS NULL"
    )

    assert_equal "sk-or-v1-server-environment-key", ManagedOpenRouterKey.effective_api_key
  end

  test "rejects a malformed key" do
    assert_raises(ActiveRecord::RecordInvalid) { ManagedOpenRouterKey.store!("not-an-openrouter-key", by: @admin) }
    assert_equal 0, ManagedOpenRouterKey.count
  end
end
