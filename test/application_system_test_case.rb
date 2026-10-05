require "test_helper"

# Selenium Manager otherwise reports usage statistics to an external service
# whenever it resolves the browser and driver.
ENV["SE_AVOID_STATS"] = "true"
require_relative "support/open_router_catalog_fixture"

# Assert observable browser state instead of treating Capybara's two-second
# default as an application deadline. Concurrent Chrome processes can take
# longer to finish a request or replace the document even after Rails responds.
Capybara.default_max_wait_time = 10

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium,
            using: :headless_chrome,
            screen_size: [ 1400, 1000 ] do |options|
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.binary = ENV["CHROME_BIN"] if ENV["CHROME_BIN"].present?

    next if options.binary

    paths = Selenium::WebDriver::SeleniumManager.binary_paths(
      "--browser",
      options.browser_name
    )
    options.binary = paths.fetch("browser_path")
  end

  setup do
    # Start from a clean browser: a late response from the previous example can
    # land after Capybara's reset and restore its session cookie.
    page.driver.browser.execute_cdp("Network.clearBrowserCookies")
    # Browser tests never load Google Identity Services; tests that exercise the
    # button install a local stand-in (see GoogleIdentitySystemHelper).
    page.driver.browser.execute_cdp("Network.enable")
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [ "*accounts.google.com*" ])
    # Each browser example starts with an independent login throttle window.
    ActionController::Base.cache_store.clear
    @original_catalog_transport = OpenRouter::Catalog.transport
    OpenRouter::Catalog.transport = -> { OpenRouterCatalogFixture.to_json }
  end

  teardown do
    OpenRouter::Catalog.transport = @original_catalog_transport
  end

  def choose_known_language(label, value)
    field = find_field(label)
    field.fill_in with: value
    field.send_keys(:arrow_down, :enter)
  end

  Selenium::WebDriver.logger.level = :warn
end
