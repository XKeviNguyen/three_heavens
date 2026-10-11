require "application_system_test_case"

class ProductTourSystemTest < ApplicationSystemTestCase
  PASSWORD = "correct horse battery staple".freeze

  setup do
    @user = users(:normal)
  end

  test "a new account is invited, steps through all seven steps, and finishing is remembered" do
    @user.update_columns(product_tour_version: nil, product_tour_outcome: nil)
    sign_in_in_browser
    visit projects_path

    within("[data-testid='product-tour-invite']") { click_button "Take the tour" }
    assert_tour_step "1 of 7", "Welcome to Three Heavens"
    assert_no_selector "[data-testid='product-tour-invite']"
    assert_equal "Next", active_element_text, "focus moves into the tour"

    click_tour_button "Next"
    assert_tour_step "2 of 7", "Your workspace"
    assert_spotlight_on "[data-tour-target='nav-work']"

    click_tour_button "Back"
    assert_tour_step "1 of 7", "Welcome to Three Heavens"
    assert_no_selector "[data-testid='product-tour-spotlight']", visible: :all

    titles = [ "Your workspace", "Translation knowledge", "Workflow setups", "AI access and who pays", "Start a translation", "From candidates to a final translation" ]
    titles.each.with_index(2) do |title, number|
      click_tour_button "Next"
      assert_tour_step "#{number} of 7", title
    end
    assert_spotlight_on "#app-sidebar a[href='#{settings_ai_settings_path}']", step: "AI access and who pays", back: 2

    click_tour_button "Finish"
    assert_no_selector "[data-testid='product-tour']", visible: :all
    assert_equal "Help", active_element_text, "focus returns to Help"
    # The outcome is written by an asynchronous request.
    assert_until { [ @user.reload.product_tour_version, @user.product_tour_outcome ] == [ ProductTour::VERSION, "completed" ] }

    visit history_path
    assert_selector "h1", text: "Translation history"
    assert_no_selector "[data-testid='product-tour-invite']"
  end

  test "Escape dismisses the offered tour, records it once, and leaves the page usable" do
    @user.update_columns(product_tour_version: nil, product_tour_outcome: nil)
    sign_in_in_browser
    visit projects_path
    within("[data-testid='product-tour-invite']") { click_button "Take the tour" }
    assert_tour_step "1 of 7", "Welcome to Three Heavens"

    find("[data-testid='product-tour']").send_keys(:escape)

    assert_no_selector "[data-testid='product-tour']", visible: :all
    assert_until { @user.reload.product_tour_outcome == "dismissed" }
    within("#app-sidebar") { click_link "History" }
    assert_selector "h1", text: "Translation history"
    assert_no_selector "[data-testid='product-tour-invite']"
  end

  test "Not now dismisses the invitation without starting the tour" do
    @user.update_columns(product_tour_version: nil, product_tour_outcome: nil)
    sign_in_in_browser
    visit projects_path

    within("[data-testid='product-tour-invite']") { click_button "Not now" }

    assert_no_selector "[data-testid='product-tour-invite']"
    assert_no_selector "[data-testid='product-tour']", visible: :all
    assert_until { @user.reload.product_tour_outcome == "dismissed" }
    # A Turbo restoration of the earlier page must not invite again.
    within("#app-sidebar") { click_link "History" }
    assert_selector "h1", text: "Translation history"
    page.go_back
    assert_selector "h1", text: "Projects"
    assert_no_selector "[data-testid='product-tour-invite']"
  end

  # The invitation hides at once, but the next page offers it again until the
  # server has actually recorded the answer.
  test "a dismissal the server never received is offered again on the next page" do
    @user.update_columns(product_tour_version: nil, product_tour_outcome: nil)
    sign_in_in_browser
    visit projects_path
    assert_selector "[data-testid='product-tour-invite']"
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [ "*accounts.google.com*", "*/product_tour" ])

    within("[data-testid='product-tour-invite']") { click_button "Not now" }
    assert_no_selector "[data-testid='product-tour-invite']"
    within("#app-sidebar") { click_link "History" }
    assert_selector "h1", text: "Translation history"
    assert_selector "[data-testid='product-tour-invite']"
    assert_nil @user.reload.product_tour_outcome

    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [ "*accounts.google.com*" ])
    within("[data-testid='product-tour-invite']") { click_button "Not now" }
    assert_until { @user.reload.product_tour_outcome == "dismissed" }
    within("#app-sidebar") { click_link "Projects" }
    assert_selector "h1", text: "Projects"
    assert_no_selector "[data-testid='product-tour-invite']"
  end

  test "double clicking Not now dismisses without clicking the page behind it" do
    @user.update_columns(product_tour_version: nil, product_tour_outcome: nil)
    sign_in_in_browser
    visit projects_path
    page.execute_script(<<~JS)
      window.clicksBehindInvite = 0
      document.addEventListener("click", (event) => { if (!event.target.closest("[data-testid='product-tour-invite']")) window.clicksBehindInvite++ })
    JS

    find("[data-testid='product-tour-invite'] button", text: "Not now").double_click

    assert_no_selector "[data-testid='product-tour-invite']"
    assert_equal 0, page.evaluate_script("window.clicksBehindInvite")
    assert_until { @user.reload.product_tour_outcome == "dismissed" }
  end

  test "an established account is never interrupted and can replay the tour from Help" do
    sign_in_in_browser
    visit projects_path
    assert_selector "[data-react-island='product-tour'][data-react-mounted='true']"
    assert_no_selector "[data-testid='product-tour-invite']"

    open_help_and_click "Full product tour"
    assert_tour_step "1 of 7", "Welcome to Three Heavens"
    click_tour_button "Skip tour"

    assert_no_selector "[data-testid='product-tour']", visible: :all
    assert_equal "preexisting", @user.reload.product_tour_outcome, "a replay writes nothing"
  end

  test "a page tour points at the page's own elements and skips what the page does not show" do
    sign_in_in_browser
    visit translation_references_path
    assert_selector "h1", text: "References"
    assert_no_selector "[data-tour-target='record-list']", visible: :all

    open_help_and_click "Tour this page"
    # Intro and Add a reference; the list, form and history steps are absent here.
    assert_tour_step "1 of 2", "Translation references"
    click_tour_button "Next"
    assert_tour_step "2 of 2", "Add a reference"
    assert_spotlight_on "[data-tour-target='library-new']"
    click_tour_button "Finish"
    assert_no_selector "[data-testid='product-tour']", visible: :all

    click_link "New reference"
    assert_selector "[data-react-island='file-field'][data-react-mounted='true']", count: 2
    open_help_and_click "Tour this page"
    assert_tour_step "1 of 3", "Translation references"
    click_tour_button "Next"
    assert_tour_step "2 of 3", "Source example"
    assert_spotlight_on "[data-tour-target='reference-source']"
  end

  # A running experiment reloads itself every 5 seconds, which would cut any
  # tour short and bring the invitation back.
  test "on a page that refreshes while AI work runs, tours wait and nothing is offered" do
    @user.update_columns(product_tour_version: nil, product_tour_outcome: nil)
    experiment = experiments(:one)
    assert_equal @user, experiment.document.project.user
    sign_in_in_browser
    visit experiment_path(experiment)
    assert_selector "[data-react-island='product-tour'][data-react-mounted='true']"

    assert_no_selector "[data-testid='product-tour-invite']"
    open_help_and_click "Tour this page"
    assert_selector "[data-react-island='product-tour'] li", text: "This page refreshes while AI work runs."
    assert_no_selector "[data-testid='product-tour']", visible: :all
    assert_nil @user.reload.product_tour_outcome
  end

  # The first click closes the tour; the second click of a double click must
  # not land on whatever was under the card (it could be a submit button).
  test "double clicking Skip closes the tour without clicking the page behind it" do
    sign_in_in_browser
    visit new_translation_reference_path
    open_help_and_click "Full product tour"
    assert_tour_step "1 of 7", "Welcome to Three Heavens"
    page.execute_script(<<~JS)
      window.clicksBehindTour = 0
      document.addEventListener("click", (event) => { if (!event.target.closest("[data-testid='product-tour']")) window.clicksBehindTour++ })
    JS

    find("[data-testid='product-tour-card'] button", text: "Skip tour").double_click

    assert_no_selector "[data-testid='product-tour']", visible: :all
    assert_equal 0, page.evaluate_script("window.clicksBehindTour")
    find("h1").click
    assert_equal 1, page.evaluate_script("window.clicksBehindTour"), "later clicks reach the page"
  end

  test "a target removed while it is shown is skipped instead of leaving a stale spotlight" do
    sign_in_in_browser
    visit new_translation_reference_path
    open_help_and_click "Tour this page"
    click_tour_button "Next"
    assert_tour_step "2 of 3", "Source example"

    page.execute_script("document.querySelector(\"[data-tour-target='reference-source']\").remove()")

    assert_tour_step "3 of 3", "Approved translation"
    assert_spotlight_on "[data-tour-target='reference-translation']"
  end

  test "Back and Forward never restore a tour or duplicate the island" do
    sign_in_in_browser
    visit projects_path
    within("#app-sidebar") { click_link "History" }
    assert_selector "h1", text: "Translation history"
    open_help_and_click "Full product tour"
    assert_tour_step "1 of 7", "Welcome to Three Heavens"

    page.go_back
    assert_selector "h1", text: "Projects"
    assert_no_selector "[data-testid='product-tour']", visible: :all
    page.go_forward
    assert_selector "h1", text: "Translation history"
    assert_no_selector "[data-testid='product-tour']", visible: :all

    assert_equal 1, page.evaluate_script("document.querySelectorAll('[data-react-island=\"product-tour\"][data-react-mounted]').length")
    assert_equal 1, page.evaluate_script("window.ThreeHeavensIslands.mountedCount()")
    open_help_and_click "Full product tour"
    assert_selector "dialog[data-testid='product-tour']", count: 1
  end

  test "on a phone the tour closes the menu, points at the Menu button, and fits the screen in Japanese" do
    @user.update!(locale: "ja")
    page.current_window.resize_to(375, 740)
    sign_in_in_browser
    visit projects_path

    click_button "メニュー"
    within("#app-sidebar") { open_help_and_click I18n.t("product_tour.ui.full_tour", locale: :ja) }
    assert_no_selector "#app-sidebar", visible: true
    assert_selector "[data-testid='product-tour-card']", text: I18n.t("product_tour.global.welcome.title", locale: :ja)

    click_tour_button I18n.t("product_tour.ui.next", locale: :ja)
    assert_spotlight_on "[data-tour-target='nav-menu']"
    assert_card_inside_viewport
    assert_equal "sheet", find("[data-testid='product-tour-card']")["data-placement"]
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "no horizontal scrolling"
  ensure
    page.current_window.resize_to(1400, 1000)
  end

  # 200% zoom on a 1400×1000 window lays the page out at 700×500 CSS pixels.
  test "at 200% zoom and in Vietnamese every step stays reachable" do
    @user.update!(locale: "vi")
    page.current_window.resize_to(700, 500)
    sign_in_in_browser
    visit projects_path
    open_help_via_menu I18n.t("product_tour.ui.full_tour", locale: :vi)

    7.times do |index|
      assert_card_inside_viewport
      assert_selector "[data-testid='product-tour-card']", text: "#{index + 1}/7"
      click_tour_button(index == 6 ? I18n.t("product_tour.ui.finish", locale: :vi) : I18n.t("product_tour.ui.next", locale: :vi))
    end
    assert_no_selector "[data-testid='product-tour']", visible: :all
  ensure
    page.current_window.resize_to(1400, 1000)
  end

  private

  def sign_in_in_browser
    visit login_path
    find("input[type=email]").fill_in with: @user.email
    find("input[type=password]").fill_in with: PASSWORD
    find("input[type=email]").ancestor("form").find("[type=submit]").click
    assert_selector "#app-sidebar", visible: :all
  end

  def open_help_and_click(label)
    help = find("[data-react-island='product-tour'] button[aria-expanded]")
    help.click unless help["aria-expanded"] == "true"
    find("[data-react-island='product-tour'] li button", text: label).click
  end

  def open_help_via_menu(label)
    click_button I18n.t("navigation.menu", locale: @user.reload.locale)
    within("#app-sidebar") { open_help_and_click label }
  end

  def click_tour_button(label)
    within("[data-testid='product-tour-card']") { click_button label, exact_text: true }
  end

  def assert_tour_step(counter, title)
    within("[data-testid='product-tour-card']") do
      assert_text counter
      assert_selector "h2", text: title
    end
  end

  # The spotlight settles around the target's box (6px padding on each side);
  # it animates between steps, so this waits for it like any other assertion.
  def assert_spotlight_on(selector, step: nil, back: 0)
    back.times { click_tour_button "Back" }
    assert_selector "[data-testid='product-tour-card'] h2", text: step if step
    find("[data-testid='product-tour-spotlight']", visible: :all)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    loop do
      boxes = page.evaluate_script(<<~JS, selector)
        (() => {
          const round = (r) => [r.left, r.top, r.width, r.height].map(Math.round)
          const target = Array.from(document.querySelectorAll(arguments[0])).find((e) => e.getClientRects().length > 0)
          const s = document.querySelector("[data-testid='product-tour-spotlight']").getBoundingClientRect()
          return [round(target.getBoundingClientRect()), [s.left + 6, s.top + 6, s.width - 12, s.height - 12].map(Math.round)]
        })()
      JS
      break if boxes[0].zip(boxes[1]).all? { |expected, actual| (expected - actual).abs <= 2 }
      flunk "spotlight #{boxes[1]} does not surround #{selector} #{boxes[0]}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    back.times { click_tour_button "Next" }
  end


  def assert_card_inside_viewport
    inside = page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector("[data-testid='product-tour-card']").getBoundingClientRect(); return r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight })()
    JS
    assert inside, "the tour card and its controls are inside the viewport"
  end

  def assert_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  # The accessible name of the focused element.
  def active_element_text
    page.evaluate_script("document.activeElement.getAttribute('aria-label') || document.activeElement.textContent.trim()")
  end
end
