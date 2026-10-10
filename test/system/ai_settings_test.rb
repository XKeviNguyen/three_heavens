require "application_system_test_case"

class AiSettingsSystemTest < ApplicationSystemTestCase
  PASSWORD = "correct horse battery staple".freeze
  KEY = "sk-or-v1-#{"8c" * 32}".freeze

  setup do
    @user = users(:normal)
  end

  test "a user without managed access adds, selects, and deletes their own key in the React island" do
    @user.update!(managed_ai_access: false)
    sign_in_in_browser
    visit settings_ai_settings_path
    assert_island_mounted

    assert_selector "[data-testid='ai-settings-status']", text: "New AI work can't start yet."
    assert find_field("My OpenRouter API key", disabled: true).disabled?

    fill_in "OpenRouter API key", with: KEY
    click_button "Save key"
    assert_text "OpenRouter key saved."
    assert_selector "[data-testid='ai-settings-key-status']", text: "Saved key ending …#{KEY.last(4)}"
    assert_equal "Replace key", active_element_text, "focus stays on the submit button"
    assert_equal "", find_field("OpenRouter API key").value
    assert_equal "managed", @user.reload.ai_payment_source, "saving a key does not switch the payer"

    choose "My OpenRouter API key"
    click_button "Use this payment source"
    assert_selector "[data-testid='ai-settings-status']", text: "New AI work is paid with your OpenRouter key."
    assert_equal "personal", @user.reload.ai_payment_source

    assert_not_includes page.html, KEY
    stored = page.evaluate_script("JSON.stringify([Object.entries(localStorage), Object.entries(sessionStorage)])")
    assert_not_includes stored, KEY.last(16)

    click_button "Delete key"
    assert_equal "Cancel", active_element_text
    click_button "Cancel"
    assert_equal "Delete key", active_element_text
    click_button "Delete key"
    within("[role='group']") { click_button "Delete key" }
    assert_text "OpenRouter key deleted."
    assert_equal "Your OpenRouter key", active_element_text
    assert_selector "[data-testid='ai-settings-key-status']", text: "No key saved."
    assert_selector "[data-testid='ai-settings-status']", text: "Your selected OpenRouter key is missing."
    assert_equal "personal", @user.reload.ai_payment_source
  end

  test "Turbo visits, Back and Forward mount exactly one island and unmount it on other pages" do
    sign_in_in_browser
    visit projects_path
    assert_equal false, page.evaluate_script("Boolean(window.ThreeHeavensIslands)")

    # The bundle is first inserted by a Turbo visit, after turbo:load fired.
    within("#app-sidebar") { click_link "AI settings" }
    assert_island_mounted

    3.times do
      within("#app-sidebar") { click_link "Projects" }
      assert_selector "h1", text: "Projects"
      assert_equal 0, mounted_count
      page.go_back
      assert_island_mounted
      page.go_forward
      assert_selector "h1", text: "Projects"
      assert_equal 0, mounted_count
      within("#app-sidebar") { click_link "AI settings" }
      assert_island_mounted
    end

    # One root and one set of listeners: a single submit sends one request.
    fill_in "OpenRouter API key", with: KEY
    click_button "Save key"
    assert_text "OpenRouter key saved."
    assert_equal 1, @user.open_router_credentials.count
  end

  test "keyboard use on a small screen in Japanese" do
    @user.update!(locale: "ja")
    page.current_window.resize_to(375, 812)
    sign_in_in_browser
    visit settings_ai_settings_path
    assert_island_mounted
    assert_selector "h1", text: "AI設定"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "no horizontal scrolling"

    find_field("OpenRouter APIキー").send_keys(KEY, :enter)
    assert_text "OpenRouterキーを保存しました。"

    radio = find_field("自分のOpenRouter APIキー")
    radio.send_keys(:space)
    assert radio.checked?
    find_button("この支払い元を使う").send_keys(:enter)
    assert_selector "[data-testid='ai-settings-status']", text: "新しいAI処理はあなたのOpenRouterキーで支払われます。"
  ensure
    page.current_window.resize_to(1400, 1000)
  end

  test "an unavailable button looks unavailable in dark mode" do
    @user.update!(appearance: "dark")
    sign_in_in_browser
    visit settings_ai_settings_path
    assert_island_mounted

    button = find_button("Use this payment source")
    assert_equal "true", button["aria-disabled"]
    disabled = page.evaluate_script("getComputedStyle(arguments[0]).backgroundColor", button)
    enabled = page.evaluate_script("getComputedStyle(arguments[0]).backgroundColor", find_button("Save key"))
    assert_not_equal enabled, disabled
  end

  test "a stale page and a lost connection never apply a change silently" do
    sign_in_in_browser
    visit settings_ai_settings_path
    assert_island_mounted

    token = Accounts::AiSettings.state(@user.reload).fetch(:state_token)
    Accounts::AiSettings.store_key!(@user, api_key: KEY, state_token: token)
    fill_in "OpenRouter API key", with: "sk-or-v1-#{"0d" * 32}"
    click_button "Save key"
    assert_selector "[role='alert']", text: "These settings changed in another window."
    assert_selector "[data-testid='ai-settings-key-status']", text: "Saved key ending …#{KEY.last(4)}"
    assert_equal 1, @user.open_router_credentials.count

    page.driver.browser.execute_cdp("Network.emulateNetworkConditions", offline: true, latency: 0,
                                                                         downloadThroughput: -1, uploadThroughput: -1)
    click_button "Replace key"
    assert_selector "[role='alert']", text: "Three Heavens couldn't be reached"
  ensure
    page.driver.browser.execute_cdp("Network.emulateNetworkConditions", offline: false, latency: 0,
                                                                         downloadThroughput: -1, uploadThroughput: -1)
  end

  private

  def sign_in_in_browser
    visit login_path
    find("input[type=email]").fill_in with: @user.email
    find("input[type=password]").fill_in with: PASSWORD
    find("input[type=email]").ancestor("form").find("[type=submit]").click
    assert_selector "#app-sidebar", visible: :all
  end

  def active_element_text
    page.evaluate_script("document.activeElement.textContent.trim()")
  end

  def assert_island_mounted
    assert_selector "[data-react-island='ai-settings'][data-react-mounted='true']", count: 1
    assert_equal 1, mounted_count
  end

  def mounted_count
    page.evaluate_script("window.ThreeHeavensIslands ? window.ThreeHeavensIslands.mountedCount() : 0")
  end
end
