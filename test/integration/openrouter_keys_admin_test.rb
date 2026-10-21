require "test_helper"

class OpenrouterKeysAdminTest < ActionDispatch::IntegrationTest
  KEY = "sk-or-v1-#{"6d" * 32}".freeze
  JSON_HEADERS = { "Accept" => "application/json", "Content-Type" => "application/json" }.freeze

  # Stands in for OpenRouter::KeyStatus: every key gets the same answer.
  class FixedStatus
    def initialize(state) = @state = state
    def call(_api_key) = status
    def cached(api_key) = api_key.present? ? status : nil

    def status
      valid = @state == "valid"
      OpenRouter::KeyStatus::Status.new(
        state: @state, label: valid ? "Three_Heavens" : nil, limit: valid ? BigDecimal("50") : nil,
        limit_remaining: valid ? BigDecimal("49.938") : nil, usage_monthly: valid ? BigDecimal("0.062") : nil,
        free_tier: false, free_requests_remaining: valid ? 997 : nil, free_requests_limit: valid ? 1000 : nil
      )
    end
  end

  setup do
    Rails.cache.clear
    @controllers = [ Settings::ManagedOpenRouterKeysController, Settings::OpenRouterKeysController, Settings::AiSettingsController ]
    @original_status = @controllers.to_h { |controller| [ controller, controller.key_status ] }
    use_status("valid")
  end

  teardown { @original_status.each { |controller, status| controller.key_status = status } }

  test "only admins reach the AI key page and see it in the sidebar" do
    sign_in_as users(:normal)
    get settings_managed_open_router_key_path
    assert_redirected_to root_path
    put settings_managed_open_router_key_path, params: { managed_open_router_key: { api_key: KEY } }
    assert_redirected_to root_path
    assert_equal 0, ManagedOpenRouterKey.count
    get root_path
    assert_select "a[href='#{settings_managed_open_router_key_path}']", count: 0

    sign_out
    sign_in_as users(:admin)
    get settings_managed_open_router_key_path
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "a[href='#{settings_managed_open_router_key_path}'][aria-current='page']"
  end

  test "an admin saves, replaces and removes the app key, which is never shown" do
    sign_in_as users(:admin)

    put settings_managed_open_router_key_path, params: { managed_open_router_key: { api_key: " #{KEY} " } }
    assert_redirected_to settings_managed_open_router_key_path
    follow_redirect!
    assert_includes response.body, I18n.t("managed_key.flash.saved")
    assert_includes response.body, "…#{KEY.last(4)}"
    assert_includes response.body, I18n.t("key_status.valid")
    assert_includes response.body, "Three_Heavens"
    assert_not_includes response.body, KEY
    assert_equal KEY, ManagedOpenRouterKey.effective_api_key
    assert_equal users(:admin), ManagedOpenRouterKey.current.created_by

    delete settings_managed_open_router_key_path
    assert_redirected_to settings_managed_open_router_key_path
    assert_nil ManagedOpenRouterKey.current
  end

  test "a saved key that can no longer be decrypted is reported, not shown as in use" do
    ManagedOpenRouterKey.store!(KEY, by: users(:admin))
    # Raw SQL: as after a secret_key_base rotation without re-encryption.
    ManagedOpenRouterKey.connection.execute(
      "UPDATE managed_open_router_keys SET api_key = '{\"p\":\"bm90LWNpcGhlcnRleHQ=\",\"h\":{}}' WHERE revoked_at IS NULL"
    )
    sign_in_as users(:admin)

    get settings_managed_open_router_key_path

    assert_response :success
    environment_key = ENV["OPENROUTER_API_KEY"].presence
    hint = environment_key ? "…#{environment_key.last(4)}" : I18n.t("managed_key.source.no_hint")
    assert_includes response.body, CGI.escapeHTML(I18n.t("managed_key.source.unreadable", hint: hint))
    assert_not_includes response.body, KEY.last(4)
  end

  test "a key OpenRouter rejects, or a malformed one, is not saved" do
    sign_in_as users(:admin)
    use_status("invalid")
    put settings_managed_open_router_key_path, params: { managed_open_router_key: { api_key: KEY } }
    follow_redirect!
    assert_includes response.body, I18n.t("key_status.rejected")

    use_status("valid")
    put settings_managed_open_router_key_path, params: { managed_open_router_key: { api_key: "sk-not-openrouter" } }
    follow_redirect!
    assert_includes response.body, I18n.t("managed_key.errors.format")
    assert_equal 0, ManagedOpenRouterKey.count
  end

  test "a key saved while OpenRouter is unreachable is kept and reported as unverified" do
    sign_in_as users(:admin)
    use_status("unavailable")

    put settings_managed_open_router_key_path, params: { managed_open_router_key: { api_key: KEY } }
    follow_redirect!

    assert_includes response.body, I18n.t("managed_key.flash.saved_unverified")
    assert_includes response.body, I18n.t("key_status.unavailable")
    assert_equal 1, ManagedOpenRouterKey.active.count
  end

  test "a personal key OpenRouter rejects is not saved, and a saved one shows its status" do
    user = users(:normal)
    sign_in_as user
    use_status("invalid")
    put settings_open_router_key_path, params: { open_router_key: { api_key: KEY, state_token: token(user) } }.to_json,
                                       headers: JSON_HEADERS
    assert_response :unprocessable_content
    assert_equal I18n.t("key_status.rejected"), response.parsed_body.fetch("error")
    assert_equal 0, user.open_router_credentials.count

    use_status("valid")
    put settings_open_router_key_path, params: { open_router_key: { api_key: KEY, state_token: token(user) } }.to_json,
                                       headers: JSON_HEADERS
    assert_response :success
    get settings_ai_settings_path
    assert_includes response.body, I18n.t("ai_settings.key.status_heading")
    assert_includes response.body, I18n.t("key_status.valid")
    assert_not_includes response.body, KEY
  end

  private

  def use_status(state)
    @controllers.each { |controller| controller.key_status = FixedStatus.new(state) }
  end

  def token(user)
    Accounts::AiSettings.state(user.reload).fetch(:state_token)
  end
end
