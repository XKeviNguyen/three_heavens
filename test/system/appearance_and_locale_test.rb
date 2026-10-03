require "application_system_test_case"

class AppearanceAndLocaleSystemTest < ApplicationSystemTestCase
  CANVAS_DARK = "rgb(13, 13, 15)".freeze

  # Flags visible light surfaces and near-black text: in Dark mode neither
  # should exist outside deliberate solid fills with white text.
  DARK_AUDIT = <<~JS.freeze
    (() => {
      const luminance = (color) => {
        const match = color.match(/rgba?\\(([^)]+)\\)/);
        if (!match) return null;
        const [r, g, b, a = 1] = match[1].split(",").map(Number);
        if (a < 0.5) return null;
        const channel = (value) => { value /= 255; return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4; };
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
      };
      const describe = (element) => element.tagName.toLowerCase() + (element.id ? "#" + element.id : "") +
        "." + [...element.classList].slice(0, 4).join(".") + " «" + (element.textContent || "").trim().slice(0, 30) + "»";
      const offenders = [];
      for (const element of document.querySelectorAll("body, body *")) {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        if (rect.width < 1 || rect.height < 1 || style.visibility === "hidden" || style.display === "none") continue;
        if (element.closest("[data-google-sign-in-target='button']")) continue;
        const background = luminance(style.backgroundColor);
        if (background !== null && background > 0.5 && rect.width * rect.height > 600) offenders.push("light surface " + describe(element));
        const ownText = [...element.childNodes].some((node) => node.nodeType === 3 && node.textContent.trim());
        const text = luminance(style.color);
        if (ownText && text !== null && text < 0.12) offenders.push("dark text " + describe(element));
      }
      return offenders.slice(0, 15);
    })()
  JS

  APPEARANCE_CYCLES = <<~JS.freeze
    const [cycles, done] = [arguments[0], arguments[arguments.length - 1]];
    const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    (async () => {
      for (let cycle = 0; cycle < cycles; cycle++) {
        for (const choice of ["system", "light", "dark", "system"]) {
          document.querySelector(`.appearance-option[data-appearance='${choice}']`).form.requestSubmit();
          while (document.documentElement.dataset.appearance !== choice) await wait(5);
          await wait(20);
        }
      }
      done();
    })();
  JS

  LOCALE_CYCLES = <<~JS.freeze
    const [cycles, done] = [arguments[0], arguments[arguments.length - 1]];
    const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    (async () => {
      for (let cycle = 0; cycle < cycles; cycle++) {
        for (const locale of ["ja", "vi", "en"]) {
          // Each switch is a Turbo visit; wait for it to finish rendering before the next.
          const loaded = new Promise((resolve) => document.addEventListener("turbo:load", resolve, { once: true }));
          const select = document.querySelector("#app-sidebar select[name='locale_code']");
          select.value = locale;
          select.dispatchEvent(new Event("change", { bubbles: true }));
          await loaded;
          if (document.documentElement.lang !== locale) return done(`expected ${locale}, got ${document.documentElement.lang}`);
          await wait(20);
        }
      }
      done();
    })();
  JS

  # WCAG 1.4.3: visible text against its composited background, 4.5:1 or
  # 3:1 for large text. Colours are resolved through a canvas because the
  # light palette is oklch. Returns the offenders.
  CONTRAST_AUDIT = <<~JS.freeze
    (() => {
      const canvas = document.createElement("canvas"); canvas.width = canvas.height = 1; const ctx = canvas.getContext("2d", { willReadFrequently: true });
      const parse = (c) => { if (!c || c === "transparent") return null; ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = "rgba(0,0,0,0)"; ctx.fillStyle = c; ctx.fillRect(0, 0, 1, 1); const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data; return { r, g, b, a: a / 255 }; };
      const lum = ({ r, g, b }) => { const ch = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b); };
      const blend = (top, bottom) => ({ r: top.r * top.a + bottom.r * (1 - top.a), g: top.g * top.a + bottom.g * (1 - top.a), b: top.b * top.a + bottom.b * (1 - top.a), a: 1 });
      const background = (el) => {
        const layers = [];
        for (let e = el; e; e = e.parentElement) { const s = getComputedStyle(e); if (s.backgroundImage !== "none") return null; const c = parse(s.backgroundColor); if (c && c.a > 0) { layers.push(c); if (c.a >= 1) break; } }
        let base = { r: 255, g: 255, b: 255, a: 1 };
        for (const layer of layers.reverse()) base = blend(layer, base);
        return base;
      };
      const out = [];
      for (const el of document.querySelectorAll("body *")) {
        if (!([...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim()))) continue;
        const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
        if (r.width < 1 || r.height < 1 || r.bottom < 0 || s.visibility === "hidden" || s.display === "none" || el.closest("[aria-hidden='true'], .sr-only, svg") || s.opacity === "0") continue;
        if (el.closest("input, select, textarea, [disabled]")) continue;
        const fg = parse(s.color); const bg = background(el); if (!fg || !bg) continue;
        const color = fg.a < 1 ? blend(fg, bg) : fg;
        const [hi, lo] = [lum(color), lum(bg)].sort((a, b) => b - a);
        const ratio = (hi + 0.05) / (lo + 0.05);
        const size = parseFloat(s.fontSize); const bold = Number(s.fontWeight) >= 700;
        const needed = (size >= 24 || (bold && size >= 18.66)) ? 3 : 4.5;
        if (ratio < needed) out.push(`${ratio.toFixed(2)} ${el.tagName.toLowerCase()}.${[...el.classList].slice(0, 5).join(".")} «${el.textContent.trim().slice(0, 40)}»`);
      }
      return [...new Set(out)].slice(0, 25);
    })()
  JS

  teardown do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
  end

  test "appearance menu is keyboard operable, applies immediately, and persists" do
    visit login_path
    summary = find(".appearance-menu summary")
    assert_equal "Appearance: System", summary[:"aria-label"]

    summary.send_keys(:enter)
    assert_selector ".appearance-menu[open] .appearance-option[aria-pressed='true']", text: "System"
    summary.send_keys(:escape)
    assert_no_selector ".appearance-menu[open]"
    assert page.evaluate_script("document.activeElement.matches('.appearance-menu summary')")

    page.execute_script("document.addEventListener('appearance:saved', (event) => { document.documentElement.dataset.testAppearanceSaved = event.detail.appearance })")
    summary.click
    click_button "Dark"
    assert_selector "html[data-appearance='dark']"
    assert_no_selector ".appearance-menu[open]"
    assert page.evaluate_script("document.activeElement.matches('.appearance-menu summary')")
    assert_equal "Appearance: Dark", find(".appearance-menu summary")[:"aria-label"]
    assert_equal CANVAS_DARK, body_background

    # Dark is shown at once but saved in the background; a reload before the
    # save lands renders the previous preference (reproduced with 400 ms of
    # network latency).
    assert_selector "html[data-test-appearance-saved='dark']"
    refresh
    assert_selector "html[data-appearance='dark']"
    assert_selector "meta[name='color-scheme'][content='dark']", visible: :all
    within_window(open_new_window) do
      visit new_registration_path
      assert_selector "html[data-appearance='dark']"
      assert_equal CANVAS_DARK, body_background
    end
  end

  test "rapid appearance choices persist in order and survive an immediate navigation" do
    user = users(:normal)
    sign_in_in_browser(user, "correct horse battery staple")
    visit projects_path
    page.execute_script(%w[dark system dark light].map { |choice| "document.querySelector(`.appearance-option[data-appearance='#{choice}']`).form.requestSubmit();" }.join)
    within("aside#app-sidebar") { click_link "History" }

    assert_current_path history_path
    assert_selector "html[data-appearance='light']"
    Timeout.timeout(5) { sleep 0.05 until user.reload.appearance == "light" }
    refresh
    assert_selector "html[data-appearance='light']"
  end

  test "a failed appearance save shows the saved choice again, and an unanswered one converges on the next page" do
    user = users(:normal)
    sign_in_in_browser(user, "correct horse battery staple")
    visit projects_path
    page.execute_script(<<~JS)
      const original = window.fetch
      window.appearanceFetchMode = "fail"
      window.fetch = async (url, options) => {
        if (!String(url).includes("/appearance")) return original(url, options)
        if (window.appearanceFetchMode === "fail") return new Response("", { status: 500 })
        await original(url, options)
        throw new TypeError("the response was lost")
      }
    JS

    page.execute_script("document.querySelector(`.appearance-option[data-appearance='dark']`).form.requestSubmit()")
    assert_selector "html[data-appearance='system']"
    assert_equal "system", user.reload.appearance

    # The server saves Dark, but the page never learns it and shows its last
    # confirmed choice until the next server-rendered page.
    page.execute_script("window.appearanceFetchMode = 'lose'")
    page.execute_script("document.querySelector(`.appearance-option[data-appearance='dark']`).form.requestSubmit()")
    Timeout.timeout(5) { sleep 0.05 until user.reload.appearance == "dark" }
    assert_selector "html[data-appearance='system']"
    within("aside#app-sidebar") { click_link "History" }
    assert_selector "h1", text: "Experiment history"
    assert_selector "html[data-appearance='dark']"
  end

  test "without Web Locks, rapid appearance choices from one page still persist in order" do
    user = users(:normal)
    sign_in_in_browser(user, "correct horse battery staple")
    visit projects_path
    page.execute_script("Object.defineProperty(navigator, 'locks', { value: undefined, configurable: true })")
    assert_nil page.evaluate_script("navigator.locks")
    page.execute_script(%w[dark system dark light].map { |choice| "document.querySelector(`.appearance-option[data-appearance='#{choice}']`).form.requestSubmit();" }.join)

    assert_selector "html[data-appearance='light']"
    Timeout.timeout(5) { sleep 0.05 until user.reload.appearance == "light" }
    refresh
    assert_selector "html[data-appearance='light']"
  end

  test "System follows the operating system live and explicit choices override it" do
    visit login_path
    emulate_color_scheme("dark")
    assert_equal CANVAS_DARK, body_background
    emulate_color_scheme("light")
    assert_equal "rgb(255, 255, 255)", body_background

    find(".appearance-menu summary").click
    click_button "Light"
    emulate_color_scheme("dark")
    assert_equal "rgb(255, 255, 255)", body_background
  end

  test "a saved Dark preference paints dark with scripts disabled" do
    visit login_path
    # Dark is shown at once but saved in the background; the next page can
    # only render it once that save has set the preference cookie.
    page.execute_script("document.addEventListener('appearance:saved', (event) => { document.documentElement.dataset.testAppearanceSaved = event.detail.appearance })")
    find(".appearance-menu summary").click
    click_button "Dark"
    assert_selector "html[data-appearance='dark'][data-test-appearance-saved='dark']"

    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: true)
    visit new_registration_path
    assert_equal CANVAS_DARK, body_background
    assert_equal "dark", page.evaluate_script("getComputedStyle(document.documentElement).colorScheme")
  ensure
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: false)
  end

  test "without JavaScript, changing appearance keeps the confirmation page and its token" do
    user = users(:normal)
    user.update_columns(email_verified_at: nil, confirmation_sent_at: Time.current)
    token = user.generate_token_for(:email_confirmation)
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: true)

    visit "/email_confirmation?token=#{token}"
    find(".appearance-menu summary").click
    click_button "Dark"
    assert_current_path "/email_confirmation?token=#{token}"
    assert_selector "html[data-appearance='dark']"
    assert_button "Confirm email"

    visit login_path
    find(".appearance-menu summary").click
    click_button "Light"
    assert_current_path login_path
    assert_selector "html[data-appearance='light']"
  ensure
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: false)
  end

  test "dark mode leaves no light-only surfaces or unreadable text across the app" do
    emulate_color_scheme("dark")
    public_pages = [ root_path, login_path, new_registration_path, new_confirmation_resend_path ]
    public_pages.each { |path| assert_dark_readable(path) }

    sign_in_in_browser(users(:admin), "admin secure password value")
    [
      new_translation_workspace_path, projects_path, project_path(projects(:one)), history_path,
      glossaries_path, new_glossary_path, translation_references_path, methodology_profiles_path,
      workflow_profiles_path, benchmarks_path, settings_models_path, settings_users_path, settings_account_path
    ].each { |path| assert_dark_readable(path) }

    visit new_translation_workspace_path
    find_field("Source language").fill_in(with: "Japa")
    assert_selector "[role='option']", text: /Japanese/
    assert_empty page.evaluate_script(DARK_AUDIT), "language popover"
    find_field("Project name").click
    find("#workspace-glossary a[data-turbo-frame='workspace-terminology-editor']", match: :first).click
    assert_selector "dialog[open] form"
    assert_empty page.evaluate_script(DARK_AUDIT), "terminology sheet"

    # Last: its health checks query Solid tables absent from the test database,
    # which aborts the shared test transaction for any later request.
    assert_dark_readable(settings_operations_path)
  end

  test "text meets AA contrast on the main pages in light and dark" do
    user = users(:admin)
    %w[light dark].each do |appearance|
      visit login_path
      page.execute_script("document.addEventListener('appearance:saved', (event) => { document.documentElement.dataset.testAppearanceSaved = event.detail.appearance })")
      page.execute_script("document.querySelector(`.appearance-option[data-appearance='#{appearance}']`).form.requestSubmit()")
      assert_selector "html[data-test-appearance-saved='#{appearance}']"
      [ root_path, login_path ].each do |path|
        visit path
        assert_selector "html[data-appearance='#{appearance}']"
        assert_empty page.evaluate_script(CONTRAST_AUDIT), "#{appearance} #{path}"
      end
      sign_in_in_browser(user, "admin secure password value")
      [ new_translation_workspace_path, projects_path, glossaries_path, settings_models_path ].each do |path|
        visit path
        assert_selector "html[data-appearance='#{appearance}']"
        assert_empty page.evaluate_script(CONTRAST_AUDIT), "#{appearance} #{path}"
      end
      # Clearing cookies instead would race responses still in flight, which
      # can restore the session cookie (seen with injected latency).
      within("aside#app-sidebar") { click_button "Log out" }
      assert_selector "main form input[type=submit]"
    end
  end

  test "the mobile navigation and launch bar are dark on a phone" do
    emulate_color_scheme("dark")
    sign_in_in_browser(users(:normal), "correct horse battery staple")
    with_phone_viewport do
      visit new_translation_workspace_path
      assert_empty page.evaluate_script(DARK_AUDIT)
      find("button[aria-controls='app-sidebar']").click
      assert_empty page.evaluate_script(DARK_AUDIT), "open mobile navigation"
    end
  end

  test "choosing a language switches the landing and signup pages immediately" do
    visit root_path
    within(".landing-header .landing-locale") do
      find("summary").click
      assert_no_button "Apply"
      click_button "日本語"
    end
    assert_selector "html[lang='ja']"
    assert_current_path root_path
    assert_selector ".translation-flow", text: "モデルA"

    visit new_registration_path
    within("header") { select "Tiếng Việt", from: "表示言語" }
    assert_selector "html[lang='vi']"
    assert_current_path new_registration_path
    assert_no_button "Áp dụng"
  end

  test "switching VI to JA keeps the whole workspace draft" do
    sign_in_in_browser(users(:normal), "correct horse battery staple")
    visit new_translation_workspace_path
    within("aside#app-sidebar") { select "Tiếng Việt", from: "Interface language" }
    assert_selector "html[lang='vi']"

    fill_in "Tên dự án", with: "Locale project"
    choose_known_language("Ngôn ngữ nguồn", "Vietnamese")
    choose_known_language("Ngôn ngữ đích", "Japanese")
    fill_in "Tiêu đề tài liệu", with: "Locale title"
    fill_in "Văn bản nguồn", with: "Nội dung nguồn riêng tư"
    within "#workspace-manual-models" do
      find("input[data-model-browser-target='search']").fill_in with: "claude"
      find("[role='option']", text: /Claude/, match: :first).click
    end
    selected_models = model_selection
    assert_not_empty selected_models

    within("aside#app-sidebar") { select "日本語", from: "Ngôn ngữ giao diện" }
    assert_selector "html[lang='ja']"
    assert_field "プロジェクト名", with: "Locale project"
    assert_equal "Vietnamese", committed_value("translation_workspace[source_language]")
    assert_equal "Japanese", committed_value("translation_workspace[target_language]")
    assert_equal "Locale title", committed_value("translation_workspace[document_title]")
    assert_equal "Nội dung nguồn riêng tư", find("textarea[name='translation_workspace[source_text]']", visible: :all).value
    assert_equal selected_models, model_selection
  end

  test "a draft that cannot be saved blocks the language switch and keeps the edits" do
    sign_in_in_browser(users(:normal), "correct horse battery staple")
    visit new_translation_workspace_path
    page.execute_script(<<~JS)
      const realFetch = window.fetch;
      window.fetch = (input, init) => String(input).includes("translation_workspace_draft")
        ? Promise.resolve(new Response("", { status: 500 }))
        : realFetch(input, init);
    JS
    fill_in "Source text", with: "Unsaved private source"

    within("aside#app-sidebar") { select "日本語", from: "Interface language" }
    assert_selector "[data-workspace-guard-target='status']", text: I18n.t("workspace.save_failed", locale: :en), wait: 10
    assert_selector "html[lang='en']"
    assert_equal "en", find("aside#app-sidebar select[name='locale_code']").value
    assert_equal "Unsaved private source", find("textarea[name='translation_workspace[source_text]']", visible: :all).value
    assert_equal "en", users(:normal).reload.locale
  end

  # Cycles run inside the page so Selenium's own per-command retention (element
  # handles, script wrappers) and DevTools network capture do not pollute the
  # heap. After a warm-up batch, thirty more cycles must add nothing lasting.
  test "thirty appearance and language cycles do not accumulate DOM, listeners, stylesheets, or heap" do
    sign_in_in_browser(users(:normal), "correct horse battery staple")
    visit projects_path
    browser = page.driver.browser
    browser.manage.timeouts.script = 180
    browser.execute_cdp("Performance.enable")
    browser.execute_cdp("Network.disable")

    # Appearance changes stay in the page (120 per batch). Each locale change is
    # an ordinary Turbo navigation (90 per batch); plain Turbo navigation keeps a
    # few KB of history bookkeeping per visit, so the bound there only catches
    # document-sized retention.
    { "appearance" => [ APPEARANCE_CYCLES, 64.kilobytes ], "locale" => [ LOCALE_CYCLES, 1.megabyte ] }.each do |name, (cycles, heap_bound)|
      assert_nil browser.execute_async_script(cycles, 30), "#{name} warm-up cycles"
      warmed = client_footprint(browser)
      assert_nil browser.execute_async_script(cycles, 30), "#{name} measured cycles"
      settled = client_footprint(browser)

      %i[nodes stylesheets listeners menus].each do |metric|
        assert_equal warmed[metric], settled[metric], "#{name} cycles changed #{metric}: #{warmed} -> #{settled}"
      end
      assert_equal 1, settled[:menus]
      assert_operator settled[:heap] - warmed[:heap], :<, heap_bound, "#{name} cycles grew the heap: #{warmed} -> #{settled}"
    end
    assert_selector "html[lang='en'][data-appearance='system']"
  end

  test "thirty appearance cycles on the landing stay bounded" do
    visit root_path
    browser = page.driver.browser
    browser.manage.timeouts.script = 180
    browser.execute_cdp("Performance.enable")
    browser.execute_cdp("Network.disable")

    browser.execute_async_script(APPEARANCE_CYCLES, 30)
    warmed = client_footprint(browser)
    browser.execute_async_script(APPEARANCE_CYCLES, 30)
    settled = client_footprint(browser)

    %i[nodes stylesheets listeners].each do |metric|
      assert_equal warmed[metric], settled[metric], "landing cycles changed #{metric}: #{warmed} -> #{settled}"
    end
    assert_operator settled[:heap] - warmed[:heap], :<, 64.kilobytes, "landing cycles grew the heap: #{warmed} -> #{settled}"
    assert_equal 6, page.evaluate_script("document.querySelectorAll('.appearance-option').length")
    assert_equal [ "true" ], page.evaluate_script("[...document.querySelectorAll('.appearance-option[data-appearance=system]')].map((option) => option.getAttribute('aria-pressed'))").uniq
  end

  private

  def emulate_color_scheme(scheme)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: scheme } ])
  end

  def body_background
    page.evaluate_script("getComputedStyle(document.body).backgroundColor")
  end

  def assert_dark_readable(path)
    visit path
    assert_empty page.evaluate_script(DARK_AUDIT), "dark mode audit for #{path}"
  end

  def with_phone_viewport
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: true)
    yield
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  def committed_value(name)
    find("input[name='#{name}']", visible: :all).value
  end

  def model_selection
    all("input[name='translation_workspace[model_identifiers][]'], input[name='translation_workspace[model_ids][]']", visible: :all).map(&:value).sort
  end

  def sign_in_in_browser(user, password)
    visit login_path
    fill_in "Email", with: user.email
    fill_in "Password", with: password
    within("main") { click_button "Sign in" }
    assert_current_path new_translation_workspace_path
  end

  def client_footprint(browser)
    browser.execute_cdp("HeapProfiler.collectGarbage")
    # Inspector handles must be released, or the measurement itself retains heap.
    listeners = %w[document window].sum do |target|
      object = browser.execute_cdp("Runtime.evaluate", expression: target, objectGroup: "footprint").dig("result", "objectId")
      browser.execute_cdp("DOMDebugger.getEventListeners", objectId: object).fetch("listeners").size
    end
    browser.execute_cdp("Runtime.releaseObjectGroup", objectGroup: "footprint")
    browser.execute_cdp("HeapProfiler.collectGarbage")
    {
      nodes: page.evaluate_script("document.getElementsByTagName('*').length"),
      stylesheets: page.evaluate_script("document.styleSheets.length"),
      menus: page.evaluate_script("document.querySelectorAll('.appearance-menu').length"),
      listeners: listeners,
      heap: browser.execute_cdp("Performance.getMetrics").fetch("metrics").find { |metric| metric["name"] == "JSHeapUsedSize" }.fetch("value").to_i
    }
  end
end
