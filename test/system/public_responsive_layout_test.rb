require "application_system_test_case"
require "base64"

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
          assert_selector ".landing-mobile-menu", visible: true

          visit new_registration_path
          assert_public_width("main > section", minimum_gutter: 48)
          assert_equal "horizontal-tb", computed_style("h1", "writingMode")
          assert_locale_controls_inside_viewport
          assert_operator find("main form", match: :first).native.rect.width, :>=,
                          page.evaluate_script("document.documentElement.clientWidth") - 48
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
      emphasis = find("h1 .landing-heading-nowrap")
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
        assert_no_button "適用"
      end
      assert_text "1～6件を選択。モデル名、プロバイダー名、識別子で検索できます。"
      assert_no_text "Choose 1–6. Search by model, provider, or identifier."
    end
  ensure
    clear_browser_viewport
  end

  # 320 CSS px is the reflow width (1280 px at 400% zoom). The Benchmarks sort
  # form used to push a whole-page scroll there, worst in Vietnamese/Japanese;
  # the admin users table must keep its own contained scroll.
  test "benchmarks and admin tables reflow at narrow widths in every locale" do
    user = users(:admin)
    sign_in_in_browser(user, "admin secure password value")
    %w[en vi ja].each do |locale|
      user.update!(locale:)
      [ 320, 360 ].each do |width|
        with_browser_viewport(width, 900, mobile: true) do
          visit benchmarks_path
          assert_selector "select#sort"
          assert_no_horizontal_overflow("benchmarks #{locale} #{width}px")
          visit settings_users_path
          assert_no_horizontal_overflow("admin users #{locale} #{width}px")
          table_region = find("table").ancestor("div.overflow-x-auto")
          assert_operator page.evaluate_script("arguments[0].clientWidth", table_region), :<=, width
        end
      end
    end
  ensure
    clear_browser_viewport
  end

  # Document titles are auto-filled from uploaded file names, so long unbroken
  # names are normal data and must wrap instead of widening the page.
  test "long unbroken project and document names reflow at phone widths" do
    user = users(:normal)
    name = "Kinh_Thanh_ban_dich_2024_final_v3_reviewed"
    project = user.projects.create!(name: name, source_language: "Vietnamese", target_language: "Japanese")
    project.documents.create!(title: name, source_text: "Source").experiments.create!(instruction_prompt: "Translate.", name: name)
    sign_in_in_browser(user, "correct horse battery staple")
    [ 320, 375, 430 ].each do |width|
      with_browser_viewport(width, 900, mobile: true) do
        [ projects_path, project_path(project), history_path ].each do |path|
          visit path
          assert_text name.first(12)
          assert_no_horizontal_overflow("#{path} #{width}px")
        end
      end
    end
  ensure
    clear_browser_viewport
  end

  # The saved-glossary menu used to hang from its button, which wraps to the
  # middle of the row on phones, so it ran off the right edge and widened
  # the whole page (and the launch bar) by up to 80 px.
  test "the saved glossary menu stays on screen at phone widths" do
    user = users(:normal)
    Glossaries::Create.call(user:, attributes: {
      name: "Glossary_" * 16, description: "", source_language: "Vietnamese", target_language: "Japanese",
      entries: [ { source_term: "Sabbath", preferred_target_term: "安息日", note: "" } ]
    })
    sign_in_in_browser(user, "correct horse battery staple")
    [ 320, 390, 430, 640 ].each do |width|
      with_browser_viewport(width, 900, mobile: width < 640) do
        visit new_translation_workspace_path
        within("#workspace-terminology") { find("summary", text: "Choose saved glossary").click }
        menu = find("#workspace-terminology details[open] > div")
        assert_text "Glossary_Glossary_"
        bounds = page.evaluate_script("(() => { const r = arguments[0].getBoundingClientRect(); return [r.left, r.right] })()", menu)
        assert_operator bounds.first, :>=, 0, "menu starts on screen at #{width}px"
        assert_operator bounds.last, :<=, width, "menu ends on screen at #{width}px"
        assert_no_horizontal_overflow("saved glossary menu #{width}px")
      end
    end
  ensure
    clear_browser_viewport
  end

  # WCAG 2.4.11: keyboard focus must not end up entirely under the sticky
  # header or the workspace launch bar, including at high zoom equivalents.
  test "tabbing through the workspace never hides focus behind the sticky bars" do
    sign_in_in_browser(users(:normal), "correct horse battery staple")
    [ [ 853, 683 ], [ 320, 256 ] ].each do |width, height|
      with_browser_viewport(width, height, mobile: width < 768) do
        visit new_translation_workspace_path
        find_field("Project name").click
        hidden = 0
        30.times do
          page.driver.browser.action.send_keys(:tab).perform
          hidden += 1 if page.evaluate_script(<<~JS)
            (() => {
              const focused = document.activeElement.getBoundingClientRect()
              if (focused.width === 0 && focused.height === 0) return false
              const header = document.getElementById("app-header")
              const launch = document.getElementById("workspace-launch")
              // The bars' own controls and fixed overlays such as the skip link
              // are drawn above the bars, so they are never hidden by them.
              const element = document.activeElement
              if (launch.contains(element) || header?.contains(element) || getComputedStyle(element).position === "fixed") return false
              const top = header && getComputedStyle(header).position === "sticky" && header.offsetParent ? header.getBoundingClientRect().bottom : 0
              const bottom = getComputedStyle(launch).position === "fixed" ? launch.getBoundingClientRect().top : window.innerHeight
              return focused.bottom <= top || focused.top >= bottom
            })()
          JS
        end
        assert_equal 0, hidden, "fully hidden tab stops at #{width}x#{height}"
      end
    end
  ensure
    clear_browser_viewport
  end

  test "the mobile navigation drawer is closed after navigating back" do
    sign_in_in_browser(users(:normal), "correct horse battery staple")
    with_browser_viewport(375, 812, mobile: true) do
      visit projects_path
      find("button[data-action='sidebar#open']").click
      assert_selector "aside#app-sidebar", visible: true
      within("aside#app-sidebar") { click_link "History" }
      assert_current_path history_path
      page.go_back
      assert_current_path projects_path
      # The URL changes before Turbo renders the restored page, so wait for
      # the Projects page itself rather than reading the History page's DOM.
      assert_selector "main h1", text: I18n.t("projects_ui.heading")
      assert_selector "aside#app-sidebar", visible: :hidden
      assert_selector "button[data-action='sidebar#open'][aria-expanded='false']"
    end
  ensure
    clear_browser_viewport
  end

  test "landing redesign stays composed across viewports locales and zoom" do
    review_dir = Rails.root.join("tmp/landing_review")
    FileUtils.mkdir_p(review_dir) if ENV["LANDING_REVIEW"] == "1"

    set_public_locale("en")
    [ [ 360, 800 ], [ 375, 812 ], [ 390, 844 ], [ 430, 900 ], [ 768, 1024 ],
      [ 1024, 900 ], [ 1280, 900 ], [ 1440, 1000 ], [ 1920, 1080 ] ].each do |width, height|
      with_browser_viewport(width, height, mobile: width < 768) do
        visit root_path
        assert_selector "h1", text: "Compare AI translations."
        assert_selector ".translation-flow"
        assert_equal "grid", computed_style(".landing-hero-grid", "display")
        assert_selector ".flow-model", count: 3
        assert_selector ".landing-value-card", count: 4
        assert_no_horizontal_overflow("#{width}px")
      end
    end

    %w[en vi ja].each do |locale|
      clear_browser_viewport
      set_public_locale(locale)

      with_browser_viewport(1440, 1000) do
        visit root_path
        assert_no_horizontal_overflow("#{locale} desktop")
        capture_landing_review(review_dir.join("landing-#{locale}-1440.png"))
      end

      with_browser_viewport(375, 812, mobile: true) do
        visit root_path
        assert_no_horizontal_overflow("#{locale} mobile")
        assert_selector ".landing-mobile-menu", visible: true
        capture_landing_review(review_dir.join("landing-#{locale}-375.png"))
      end
    end

    clear_browser_viewport
    set_public_locale("en")
    [ [ 1.25, "125" ], [ 1.5, "150" ], [ 2.0, "200" ] ].each do |scale, label|
      page.driver.browser.execute_cdp(
        "Emulation.setDeviceMetricsOverride",
        width: (1440 / scale).floor,
        height: (1000 / scale).floor,
        deviceScaleFactor: scale,
        mobile: false
      )
      visit root_path
      assert_no_horizontal_overflow("#{label}% zoom")
      capture_landing_review(review_dir.join("landing-200-percent.png")) if label == "200"
    end
  ensure
    clear_browser_viewport
  end

  test "landing motion settles and repeated visits keep bounded client state" do
    with_browser_viewport(1440, 1000) do
      visit root_path
      wait_for_landing_motion
      assert_operator page.evaluate_script("document.querySelectorAll('.landing-page *').length"), :<, 450
      assert_operator page.evaluate_script("document.querySelectorAll('.translation-flow *').length"), :<, 150
      assert_equal 0, page.evaluate_script("document.getAnimations().filter((animation) => animation.playState === 'running').length")

      browser = page.driver.browser
      browser.execute_cdp("Performance.enable")
      samples = 6.times.map do
        visit login_path
        visit root_path
        wait_for_landing_motion
        browser.execute_cdp("HeapProfiler.collectGarbage")
        javascript_heap_size(browser)
      end

      assert samples.each_cons(2).any? { |previous, current| current <= previous },
             "Expected repeated landing visits not to grow monotonically: #{samples.inspect}"
      stabilized = samples.last(4)
      assert_operator stabilized.max - stabilized.min, :<=, 1.megabyte,
                      "Expected landing heap to stabilize: #{samples.inspect}"
    end
  ensure
    clear_browser_viewport
  end

  test "landing diagram is complete without motion" do
    with_browser_viewport(1440, 1000) do
      with_reduced_motion do
        visit root_path
        assert_equal 0, page.evaluate_script("document.getAnimations().length")
        assert_equal "1", computed_style(".flow-final", "opacity")
        widths = page.evaluate_script(<<~JS)
          [...document.querySelectorAll(".flow-score-fill")].map((bar) =>
            Math.round(bar.getBoundingClientRect().width / bar.ownerSVGElement.getBoundingClientRect().width * 100))
        JS
        assert_equal [ 92, 88, 85, 85, 91, 82, 78, 84, 90 ], widths
      end
    end
  ensure
    clear_browser_viewport
  end

  test "landing menus close after navigation, outside clicks, and escape" do
    with_browser_viewport(375, 812, mobile: true) do
      visit root_path
      find(".landing-mobile-menu summary").click
      within(".landing-mobile-menu") { click_link "How it works" }
      assert_no_selector ".landing-mobile-menu[open]"

      find(".landing-mobile-menu summary").click
      assert_selector ".landing-mobile-menu[open]"
      find(".landing-hero-principles").click
      assert_no_selector ".landing-mobile-menu[open]"
    end

    with_browser_viewport(1440, 1000) do
      visit root_path
      find(".landing-locale summary").click
      assert_button "日本語"
      find(".landing-locale summary").send_keys(:escape)
      assert_no_selector ".landing-locale[open]"
      assert page.evaluate_script("document.activeElement.matches('.landing-locale summary')")
    end
  ensure
    clear_browser_viewport
  end

  private

  def set_public_locale(locale)
    visit root_path
    within ".landing-header .landing-locale" do
      find("summary").click
      click_button ApplicationHelper::INTERFACE_LOCALE_NAMES.fetch(locale)
    end
    assert_selector "html[lang='#{locale}']"
  end

  def sign_in_in_browser(user, password)
    visit login_path
    fill_in I18n.t("registration.email", locale: I18n.locale), with: user.email
    fill_in I18n.t("registration.password", locale: I18n.locale), with: password
    page.execute_script("document.querySelector('main form').setAttribute('data-turbo', 'false')")
    within "main" do
      find("form input[type=submit]").click
    end
    assert_current_path new_translation_workspace_path
  end

  def with_browser_viewport(width, height, mobile: false)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: width,
      height: height,
      deviceScaleFactor: 1,
      mobile: mobile
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

  # Full-page captures can race compositor animations, so review screenshots
  # use reduced motion, which renders the same finished state immediately.
  def capture_landing_review(path)
    return unless ENV["LANDING_REVIEW"] == "1"

    with_reduced_motion do
      result = page.driver.browser.execute_cdp(
        "Page.captureScreenshot",
        format: "png",
        fromSurface: true,
        captureBeyondViewport: true
      )
      File.binwrite(path, Base64.strict_decode64(result.fetch("data")))
    end
  end

  def with_reduced_motion
    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia",
      features: [ { name: "prefers-reduced-motion", value: "reduce" } ]
    )
    yield
  ensure
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
  end

  def wait_for_landing_motion
    page.driver.browser.execute_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const animations = document.querySelector(".landing-page").getAnimations({ subtree: true });
      Promise.all(animations.map((animation) => animation.finished.catch(() => null)))
        .then(() => requestAnimationFrame(() => requestAnimationFrame(done)));
    JS
  end

  def javascript_heap_size(browser)
    browser.execute_cdp("Performance.getMetrics").fetch("metrics").
      find { |metric| metric.fetch("name") == "JSHeapUsedSize" }.fetch("value").to_i
  end

  def computed_style(selector, property)
    page.evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json}))[#{property.to_json}]")
  end

  def assert_no_horizontal_overflow(label)
    metrics = page.evaluate_script("({ client: document.documentElement.clientWidth, scroll: document.documentElement.scrollWidth })")
    assert_operator metrics.fetch("scroll"), :<=, metrics.fetch("client"),
                    "Expected no horizontal overflow at #{label}, got #{metrics.inspect}"
  end
end
