require "application_system_test_case"

class PublicResponsiveLayoutTest < ApplicationSystemTestCase
  VIEWPORTS = [ [ 360, 800 ], [ 375, 812 ] ].freeze

  test "public landing and signup keep usable width in every locale" do
    %w[en vi ja].each do |locale|
      set_public_locale(locale)

      VIEWPORTS.each do |width, height|
        with_browser_viewport(width, height) do
          visit root_path
          assert_public_width("main > section", minimum_gutter: 48)
          assert_equal "horizontal-tb", computed_style("h1", "writingMode")
          assert_locale_controls_inside_viewport

          visit new_registration_path
          assert_public_width("main > section", minimum_gutter: 48)
          assert_equal "horizontal-tb", computed_style("h1", "writingMode")
          assert_locale_controls_inside_viewport
          assert_operator find("main form", match: :first).native.rect.width, :>=, page.evaluate_script("document.documentElement.clientWidth") - 48
        end
      end
    end
  ensure
    clear_browser_viewport
  end

  test "Japanese landing keeps the headline emphasis together" do
    set_public_locale("ja")

    with_browser_viewport(1440, 1000) do
      visit root_path
      assert_text "AI翻訳を比べる。"
      assert_text "最終判断は、あなたに。"
      emphasis = find("h1 span.whitespace-nowrap")
      assert_equal 1, page.evaluate_script("arguments[0].getClientRects().length", emphasis)
    end
  ensure
    clear_browser_viewport
  end

  test "localized workspace sidebar contains long identity and controls" do
    user = users(:normal)
    user.update!(email: "a-very-long-account-identity-for-responsive-testing@example.test", locale: "ja")
    sign_in_in_browser(user, "correct horse battery staple")

    with_browser_viewport(1440, 1000) do
      visit new_translation_workspace_path
      sidebar = find("aside#app-sidebar")
      assert_operator page.evaluate_script("arguments[0].scrollWidth", sidebar), :<=,
                      page.evaluate_script("arguments[0].clientWidth", sidebar)
      within "aside#app-sidebar" do
        assert_field "表示言語"
        assert_button "適用"
      end
      assert_text "1～6件を選択。モデル名、プロバイダー名、識別子で検索できます。"
      assert_no_text "Choose 1–6. Search by model, provider, or identifier."
    end
  ensure
    clear_browser_viewport
  end

  private

  def set_public_locale(locale)
    visit root_path
    within "header" do
      select({ "en" => "English", "vi" => "Tiếng Việt", "ja" => "日本語" }.fetch(locale), from: "locale_code")
      find("form input[type=submit]").click
    end
  end

  def sign_in_in_browser(user, password)
    visit login_path
    fill_in I18n.t("registration.email", locale: I18n.locale), with: user.email
    fill_in I18n.t("registration.password", locale: I18n.locale), with: password
    within "main" do
      find("form input[type=submit]").click
    end
  end

  def with_browser_viewport(width, height)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: width,
      height: height,
      deviceScaleFactor: 1,
      mobile: false
    )
    yield
  ensure
    clear_browser_viewport
  end

  def clear_browser_viewport
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if page&.driver
  rescue StandardError
    nil
  end

  def assert_public_width(selector, minimum_gutter:)
    metrics = page.evaluate_script(<<~JS)
      (() => {
        const element = document.querySelector(#{selector.to_json});
        return {
          clientWidth: document.documentElement.clientWidth,
          scrollWidth: document.documentElement.scrollWidth,
          elementWidth: element.getBoundingClientRect().width
        };
      })()
    JS
    assert_operator metrics.fetch("scrollWidth"), :<=, metrics.fetch("clientWidth")
    assert_operator metrics.fetch("elementWidth"), :>=, metrics.fetch("clientWidth") - minimum_gutter
  end

  def assert_locale_controls_inside_viewport
    metrics = page.evaluate_script(<<~JS)
      (() => {
        const form = document.querySelector("header form");
        const rect = form.getBoundingClientRect();
        return { left: rect.left, right: rect.right, viewport: document.documentElement.clientWidth };
      })()
    JS
    assert_operator metrics.fetch("left"), :>=, 0
    assert_operator metrics.fetch("right"), :<=, metrics.fetch("viewport")
  end

  def computed_style(selector, property)
    page.evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json}))[#{property.to_json}]")
  end
end
