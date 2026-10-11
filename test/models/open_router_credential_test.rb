require "test_helper"

class OpenRouterCredentialTest < ActiveSupport::TestCase
  KEY = "sk-or-v1-#{"4d" * 32}".freeze

  test "the key is stored only as ciphertext and redacted from inspect" do
    credential = users(:normal).open_router_credentials.create!(api_key: KEY)
    stored = OpenRouterCredential.connection.select_value(
      "SELECT api_key FROM open_router_credentials WHERE id = #{Integer(credential.id)}"
    )

    assert_not_includes stored, KEY
    assert_not_includes stored, KEY.last(16)
    assert_equal KEY, credential.reload.api_key
    assert_equal "…#{KEY.last(4)}", credential.key_hint
    assert_not_includes credential.inspect, KEY
    assert_includes Rails.application.config.filter_parameters.map(&:to_s).join, "_key"
  end

  test "revoking erases the ciphertext and keeps the row for authorized work's identity" do
    credential = users(:normal).open_router_credentials.create!(api_key: KEY)
    credential.revoke!(reason: "deleted")

    assert_nil credential.reload.read_attribute_before_type_cast(:api_key)
    assert_not credential.active?
    assert_raises(ArgumentError) { users(:normal).open_router_credentials.create!(api_key: KEY).revoke!(reason: "bogus") }
  end

  test "an undecryptable key can still be replaced or deleted" do
    user = users(:normal)
    %w[replace delete].each do |change|
      credential = user.open_router_credentials.create!(api_key: KEY)
      # Raw SQL: as after a secret_key_base rotation without re-encryption.
      OpenRouterCredential.connection.execute(
        "UPDATE open_router_credentials SET api_key = '{\"p\":\"bm90LWNpcGhlcnRleHQ=\",\"h\":{}}' WHERE id = #{Integer(credential.id)}"
      )
      token = Accounts::AiSettings.state(user.reload).fetch(:state_token)
      if change == "replace"
        Accounts::AiSettings.store_key!(user, api_key: KEY, state_token: token)
        assert_equal KEY, user.reload.active_open_router_credential.api_key
        user.active_open_router_credential.revoke!(reason: "deleted")
      else
        Accounts::AiSettings.delete_key!(user, state_token: token)
      end
      assert_nil credential.reload.read_attribute_before_type_cast(:api_key)
      assert_equal 0, user.open_router_credentials.active.count
    end
  end

  test "keys are validated and the database allows one active key per user" do
    user = users(:normal)
    [ "", "sk-or-short", "pk-or-#{"a" * 40}", "sk-or-#{"a" * 30} space" ].each do |value|
      assert_not user.open_router_credentials.build(api_key: value).valid?, value.inspect
    end

    user.open_router_credentials.create!(api_key: KEY)
    assert_violates(ActiveRecord::RecordNotUnique) do
      OpenRouterCredential.new(user: user, api_key: KEY).save!(validate: false)
    end
  end

  test "the database refuses an active row without ciphertext or a revoked row without a reason" do
    user = users(:normal)
    assert_violates(ActiveRecord::CheckViolation) do
      OpenRouterCredential.connection.execute(
        "INSERT INTO open_router_credentials (user_id, created_at, updated_at) VALUES (#{Integer(user.id)}, now(), now())"
      )
    end
    assert_violates(ActiveRecord::CheckViolation) do
      OpenRouterCredential.connection.execute(
        "INSERT INTO open_router_credentials (user_id, revoked_at, created_at, updated_at) VALUES (#{Integer(user.id)}, now(), now(), now())"
      )
    end
  end

  test "billing identity must name a key exactly when personal" do
    run = translation_runs(:one)
    assert_violates(ActiveRecord::CheckViolation) { run.update_columns(billing_source: "personal") }
    credential = users(:normal).open_router_credentials.create!(api_key: KEY)
    assert_violates(ActiveRecord::CheckViolation) { run.update_columns(open_router_credential_id: credential.id) }
    assert_violates(ActiveRecord::CheckViolation) { run.update_columns(billing_source: "platform") }
    assert_not TranslationRun.find(run.id).tap { |record| record.billing_source = "personal" }.valid?
    assert_not TranslationRun.find(run.id).tap { |record| record.open_router_credential_id = credential.id }.valid?
  end

  private

  # Each expected violation runs in a savepoint so the test transaction stays usable.
  def assert_violates(error_class, &block)
    assert_raises(error_class) { ActiveRecord::Base.transaction(requires_new: true, &block) }
  end
end
