require "test_helper"
require_relative "support/open_router_catalog_fixture"

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
