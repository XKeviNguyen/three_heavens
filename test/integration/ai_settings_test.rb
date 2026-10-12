require "test_helper"

class AiSettingsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  KEY = "sk-or-v1-#{"7e" * 32}".freeze
  OTHER_KEY = "sk-or-v1-#{"9f" * 32}".freeze
  JSON_HEADERS = { "Accept" => "application/json", "Content-Type" => "application/json" }.freeze

  setup do
    @user = users(:normal)
    Rails.cache.clear
    ActionController::Base.cache_store.clear
  end

  test "signed-out visitors cannot read or change AI settings" do
    get settings_ai_settings_path
    assert_redirected_to login_path

    put settings_open_router_key_path, params: { open_router_key: { api_key: KEY, state_token: "managed.0" } }
    assert_redirected_to login_path
    assert_equal 0, OpenRouterCredential.count
  end

  test "the page shows status, never the key, and is not cacheable" do
    sign_in_as @user
    store_key(KEY)

    get settings_ai_settings_path

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "[data-react-island='ai-settings'][data-react-props]"
    assert_select "meta[name='turbo-cache-control'][content='no-cache']"
    assert_select "script[type='module'][src*='islands']"
    assert_includes response.body, "…#{KEY.last(4)}"
    assert_not_includes response.body, KEY
    assert_not_includes response.body, KEY.first(20)
  end

  test "the server-rendered fallback confirms replacing and deleting a saved key, naming it" do
    sign_in_as @user
    get settings_ai_settings_path
    assert_select "input[type=submit][value='Save key']:not([data-turbo-confirm])"

    Accounts::AiSettings.store_key!(@user, api_key: KEY, state_token: Accounts::AiSettings.state(@user.reload).fetch(:state_token))
    get settings_ai_settings_path
    hint = "…#{KEY.last(4)}"
    assert_select "input[type=submit][value='Replace key'][data-turbo-confirm=?]", I18n.t("ai_settings.key.replace_confirm", hint: hint)
    assert_select "input[type=submit][value='Delete key'][data-turbo-confirm=?]", I18n.t("ai_settings.key.delete_confirm", hint: hint)
  end

  test "BYOK works with managed access disabled; managed selection is refused" do
    @user.update!(managed_ai_access: false)
    sign_in_as @user

    put settings_open_router_key_path, params: { open_router_key: { api_key: KEY, state_token: token } }.to_json, headers: JSON_HEADERS
    assert_response :success
    assert_not_includes response.body, KEY
    assert_equal true, response.parsed_body.dig("state", "personal_key", "configured")
    assert_equal "managed", @user.reload.ai_payment_source, "saving a key never switches the payer"

    patch settings_ai_settings_path, params: { ai_settings: { payment_source: "personal", state_token: token } }.to_json, headers: JSON_HEADERS
    assert_response :success
    assert_equal "personal", @user.reload.ai_payment_source
    assert_nil response.parsed_body.dig("state", "denial_code")

    patch settings_ai_settings_path, params: { ai_settings: { payment_source: "managed", state_token: token } }.to_json, headers: JSON_HEADERS
    assert_response :unprocessable_content
    assert_equal "payment_source", response.parsed_body["field"]
    assert_equal "personal", @user.reload.ai_payment_source
  end

  test "a managed user is offered both sources and the explicit selection governs new work" do
    sign_in_as @user
    store_key(KEY)
    assert Ai::BillingPolicy.authorize!(@user.reload).attributes == { billing_source: "managed", open_router_credential_id: nil }

    patch settings_ai_settings_path, params: { ai_settings: { payment_source: "personal", state_token: token } }
    assert_redirected_to settings_ai_settings_path
    assert_equal "personal", Ai::BillingPolicy.authorize!(@user.reload).billing_source

    patch settings_ai_settings_path, params: { ai_settings: { payment_source: "managed", state_token: token } }
    assert_equal "managed", Ai::BillingPolicy.authorize!(@user.reload).billing_source
  end

  test "deleting or replacing the key never switches the selected source" do
    sign_in_as @user
    store_key(KEY)
    patch settings_ai_settings_path, params: { ai_settings: { payment_source: "personal", state_token: token } }

    store_key(OTHER_KEY)
    assert_equal 1, @user.open_router_credentials.active.count
    assert_equal "replaced", @user.open_router_credentials.where.not(revoked_at: nil).sole.revocation_reason
    assert_nil @user.open_router_credentials.where.not(revoked_at: nil).sole.read_attribute_before_type_cast(:api_key)

    delete settings_open_router_key_path, params: { open_router_key: { state_token: token } }.to_json, headers: JSON_HEADERS
    assert_response :success
    assert_equal "personal", @user.reload.ai_payment_source
    assert_equal "personal_key_unavailable", response.parsed_body.dig("state", "denial_code")
    assert_equal 0, @user.open_router_credentials.active.count
    assert_equal [ nil ], @user.open_router_credentials.pluck(:api_key).uniq, "every revoked key's ciphertext is erased"
  end

  test "stale or replayed forms are rejected without changing anything" do
    sign_in_as @user
    stale = token
    store_key(KEY)

    put settings_open_router_key_path, params: { open_router_key: { api_key: OTHER_KEY, state_token: stale } }.to_json, headers: JSON_HEADERS
    assert_response :conflict
    assert_equal token, response.parsed_body.dig("state", "state_token")
    assert_equal 1, OpenRouterCredential.count

    delete settings_open_router_key_path, params: { open_router_key: { state_token: stale } }
    assert_redirected_to settings_ai_settings_path
    assert_equal 1, @user.open_router_credentials.active.count
  end

  # Without JavaScript the forms have no in-flight guard: a double click, or
  # Back and submitting the same choice again, sends a second request with the
  # token the first one already used. When the user's change is in place, that
  # request must not report that the settings changed in another window.
  test "repeating an already applied form submission reports success, not a conflict" do
    sign_in_as @user
    store_key(KEY)

    rendered = token
    2.times { patch settings_ai_settings_path, params: { ai_settings: { payment_source: "personal", state_token: rendered } } }
    assert_lands_on_notice I18n.t("ai_settings.flash.source_saved")
    assert_equal "personal", @user.reload.ai_payment_source

    rendered = token
    2.times { delete settings_open_router_key_path, params: { open_router_key: { state_token: rendered } } }
    assert_lands_on_notice I18n.t("ai_settings.flash.key_deleted")
    assert_equal 0, @user.open_router_credentials.active.count

    # The same choice is no longer usable (the key is gone), and a different
    # choice is a real conflict: both are still refused.
    [ "personal", "managed" ].each do |source|
      patch settings_ai_settings_path, params: { ai_settings: { payment_source: source, state_token: rendered } }
      follow_redirect!
      assert_select "[role='alert']", text: I18n.t("ai_settings.errors.stale")
    end
    assert_equal "personal", @user.reload.ai_payment_source
  end

  # Recognizing a repeated key save would need the stored key decrypted in a
  # web request, which only a claimed provider run may do; the repeat stays a
  # conflict, and the first save is kept exactly once.
  test "a repeated key save keeps one key and is reported as a conflict" do
    sign_in_as @user
    rendered = token

    2.times { put settings_open_router_key_path, params: { open_router_key: { api_key: KEY, state_token: rendered } } }

    assert_equal 1, @user.open_router_credentials.count
    follow_redirect!
    assert_select "[role='alert']", text: I18n.t("ai_settings.errors.stale")
    assert_includes response.body, "…#{KEY.last(4)}"
  end

  test "tampered, oversized, or malformed parameters are rejected" do
    sign_in_as @user
    [
      [ :put, settings_open_router_key_path, { open_router_key: { api_key: "not a key", state_token: token } }, :unprocessable_content ],
      [ :put, settings_open_router_key_path, { open_router_key: { api_key: "sk-or-#{"a" * 300}", state_token: token } }, :unprocessable_content ],
      [ :put, settings_open_router_key_path, { open_router_key: { api_key: "", state_token: token } }, :unprocessable_content ],
      [ :put, settings_open_router_key_path, { open_router_key: "flat" }, :bad_request ],
      [ :patch, settings_ai_settings_path, { ai_settings: { payment_source: "admin", state_token: token } }, :unprocessable_content ],
      [ :patch, settings_ai_settings_path, { ai_settings: { payment_source: "personal", state_token: token } }, :unprocessable_content ]
    ].each do |method, path, body, status|
      public_send(method, path, params: body.to_json, headers: JSON_HEADERS)
      assert_response status, "#{method} #{body.inspect}"
    end
    assert_equal 0, OpenRouterCredential.count
    assert_equal "managed", @user.reload.ai_payment_source
  end

  test "forged ownership parameters cannot write another user's key" do
    other = users(:other)
    sign_in_as @user

    put settings_open_router_key_path,
        params: { user_id: other.id, open_router_key: { api_key: KEY, state_token: token, user_id: other.id } }.to_json,
        headers: JSON_HEADERS

    assert_response :success
    assert_equal 0, other.open_router_credentials.count
    assert_equal 1, @user.open_router_credentials.count
  end

  test "mutations require a CSRF token when protection is enabled" do
    sign_in_as @user
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    put settings_open_router_key_path, params: { open_router_key: { api_key: KEY, state_token: token } }
    assert_response :unprocessable_content
    patch settings_ai_settings_path, params: { ai_settings: { payment_source: "personal", state_token: token } }
    assert_response :unprocessable_content
    assert_equal 0, OpenRouterCredential.count
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "key mutations are throttled per user" do
    sign_in_as @user
    AiSettingsResponses::MUTATION_LIMIT.times do
      delete settings_open_router_key_path, params: { open_router_key: { state_token: token } }.to_json, headers: JSON_HEADERS
      assert_response :success
    end
    delete settings_open_router_key_path, params: { open_router_key: { state_token: token } }.to_json, headers: JSON_HEADERS
    assert_response :too_many_requests
  end

  test "the key never reaches logs, events, or another user's or an administrator's pages" do
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)
    originals = [ Rails.logger, ActionController::Base.logger ]
    Rails.logger = ActionController::Base.logger = logger
    begin
      sign_in_as @user
      put settings_open_router_key_path, params: { open_router_key: { api_key: KEY, state_token: token } }.to_json, headers: JSON_HEADERS
      assert_response :success
      get settings_ai_settings_path
      sign_out
      sign_in_as users(:admin)
      get settings_users_path
      assert_not_includes response.body, KEY
      assert_not_includes response.body, KEY.last(4)
    ensure
      Rails.logger, ActionController::Base.logger = originals
    end

    assert_includes log.string, "open_router_key_changed"
    assert_not_includes log.string, KEY
    assert_includes log.string, "[FILTERED]"
  end

  test "denied users are sent to AI settings from paid work and see why" do
    @user.update!(managed_ai_access: false)
    sign_in_as @user

    post retry_failed_experiment_path(experiments(:one))
    assert_redirected_to settings_ai_settings_path
    follow_redirect!
    assert_select "[role='status']", text: /Platform-managed AI isn't enabled/
  end

  test "a personal-key user with managed access disabled launches a manual workspace billed to the key" do
    @user.update!(managed_ai_access: false)
    sign_in_as @user
    store_key(KEY)
    patch settings_ai_settings_path, params: { ai_settings: { payment_source: "personal", state_token: token } }

    get new_translation_workspace_path
    assert_select "input[type=submit][disabled]", 0
    assert_select "[data-testid='ai-payer']", text: /paid with your OpenRouter key/

    assert_enqueued_jobs 1, only: TranslationRunJob do
      post translation_workspace_path, params: {
        translation_workspace: {
          project_name: "BYOK project", source_language: "Vietnamese", target_language: "Japanese",
          document_title: "BYOK document", source_text: "Source text", instruction_prompt: "Translate faithfully.",
          workflow_mode: "manual", model_ids: [ llm_models(:openrouter_claude).id ],
          submission_token: issue_translation_workspace_token(user: @user)
        }
      }
    end
    run = TranslationRun.order(:id).last
    assert_equal [ "personal", @user.active_open_router_credential.id ], [ run.billing_source, run.open_router_credential_id ]
  end

  private

  def token
    Accounts::AiSettings.state(@user.reload).fetch(:state_token)
  end

  # The page the browser shows after the last of the repeated submissions.
  def assert_lands_on_notice(notice)
    assert_redirected_to settings_ai_settings_path
    follow_redirect!
    assert_select "[role='alert']", { text: I18n.t("ai_settings.errors.stale"), count: 0 }, "no false conflict"
    assert_includes response.body, notice
  end

  def store_key(key)
    put settings_open_router_key_path, params: { open_router_key: { api_key: key, state_token: token } }.to_json, headers: JSON_HEADERS
    assert_response :success
  end
end
