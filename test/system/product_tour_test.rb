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

    titles = [ "Your workspace", "Your translation library", "Workflow setups", "AI access and payment", "Start a translation", "From drafts to a final translation" ]
    titles.each.with_index(2) do |title, number|
      click_tour_button "Next"
      assert_tour_step "#{number} of 7", title
    end
    assert_spotlight_on "#app-sidebar a[href='#{settings_ai_settings_path}']", step: "AI access and payment", back: 2

    click_tour_button "Done"
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

    open_help_and_click "Product tour"
    assert_tour_step "1 of 7", "Welcome to Three Heavens"
    click_tour_button "Skip"

    assert_no_selector "[data-testid='product-tour']", visible: :all
    assert_equal "preexisting", @user.reload.product_tour_outcome, "a replay writes nothing"
  end

  test "a page tour points at the page's own elements and skips what the page does not show" do
    sign_in_in_browser
    visit translation_references_path
    assert_selector "h1", text: "References"
    assert_no_selector "[data-tour-target='record-list']", visible: :all

    open_help_and_click "Guide to this page"
    # Intro and New reference; the list, form and history steps are absent here.
    assert_tour_step "1 of 2", "References"
    click_tour_button "Next"
    assert_tour_step "2 of 2", "New reference"
    assert_spotlight_on "[data-tour-target='library-new']"
    click_tour_button "Done"
    assert_no_selector "[data-testid='product-tour']", visible: :all

    click_link "New reference"
    assert_selector "[data-react-island='file-field'][data-react-mounted='true']", count: 2
    open_help_and_click "Guide to this page"
    assert_tour_step "1 of 3", "References"
    click_tour_button "Next"
    assert_tour_step "2 of 3", "Source text"
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
    open_help_and_click "Guide to this page"
    assert_selector "[data-react-island='product-tour'] li", text: "This page updates while AI work runs."
    assert_no_selector "[data-testid='product-tour']", visible: :all
    assert_nil @user.reload.product_tour_outcome
  end

  # The first click closes the tour; the second click of a double click must
  # not land on whatever was under the card (it could be a submit button).
  test "double clicking Skip closes the tour without clicking the page behind it" do
    sign_in_in_browser
    visit new_translation_reference_path
    open_help_and_click "Product tour"
    assert_tour_step "1 of 7", "Welcome to Three Heavens"
    page.execute_script(<<~JS)
      window.clicksBehindTour = 0
      document.addEventListener("click", (event) => { if (!event.target.closest("[data-testid='product-tour']")) window.clicksBehindTour++ })
    JS

    find("[data-testid='product-tour-card'] button", text: "Skip").double_click

    assert_no_selector "[data-testid='product-tour']", visible: :all
    assert_equal 0, page.evaluate_script("window.clicksBehindTour")
    find("h1").click
    assert_equal 1, page.evaluate_script("window.clicksBehindTour"), "later clicks reach the page"
  end

  test "a target removed while it is shown is skipped instead of leaving a stale spotlight" do
    sign_in_in_browser
    visit new_translation_reference_path
    open_help_and_click "Guide to this page"
    click_tour_button "Next"
    assert_tour_step "2 of 3", "Source text"

    page.execute_script("document.querySelector(\"[data-tour-target='reference-source']\").remove()")

    assert_tour_step "3 of 3", "Approved translation"
    assert_spotlight_on "[data-tour-target='reference-translation']"
  end

  test "Back and Forward never restore a tour or duplicate the island" do
    sign_in_in_browser
    visit projects_path
    within("#app-sidebar") { click_link "History" }
    assert_selector "h1", text: "Translation history"
    open_help_and_click "Product tour"
    assert_tour_step "1 of 7", "Welcome to Three Heavens"

    page.go_back
    assert_selector "h1", text: "Projects"
    assert_no_selector "[data-testid='product-tour']", visible: :all
    page.go_forward
    assert_selector "h1", text: "Translation history"
    assert_no_selector "[data-testid='product-tour']", visible: :all

    assert_equal 1, page.evaluate_script("document.querySelectorAll('[data-react-island=\"product-tour\"][data-react-mounted]').length")
    assert_equal 1, page.evaluate_script("window.ThreeHeavensIslands.mountedCount()")
    open_help_and_click "Product tour"
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

  test "the invitation is a modal welcome: the page behind is inert and Escape means Not now" do
    @user.update_columns(product_tour_version: nil, product_tour_outcome: nil)
    sign_in_in_browser
    visit projects_path

    invite = find("dialog[open][data-testid='product-tour-invite']")
    assert_equal "Take the tour", active_element_text, "focus starts on the invitation's primary action"
    within(invite) { assert_selector "li", count: 7 }
    assert page.evaluate_script("document.querySelector(\"[data-testid='product-tour-invite']\").matches(':modal')"), "the invitation is a modal dialog, so the page behind it is inert"

    invite.send_keys(:escape)
    assert_no_selector "[data-testid='product-tour-invite']"
    assert_no_selector "[data-testid='product-tour']", visible: :all
    assert_until { @user.reload.product_tour_outcome == "dismissed" }
  end

  # A short phone in the language with the longest text: the actions are
  # pinned, so none of them can be scrolled or clipped out of view.
  test "on a short phone in Vietnamese every tour action stays fully visible" do
    @user.update!(locale: "vi")
    page.current_window.resize_to(375, 667)
    sign_in_in_browser
    visit projects_path
    open_help_via_menu I18n.t("product_tour.ui.full_tour", locale: :vi)

    7.times do |index|
      assert_selector "[data-testid='product-tour-card']", text: "#{index + 1}/7"
      assert_card_inside_viewport
      labels = [ I18n.t("product_tour.ui.skip", locale: :vi), I18n.t("product_tour.ui.back", locale: :vi),
                 I18n.t(index == 6 ? "product_tour.ui.finish" : "product_tour.ui.next", locale: :vi) ]
      labels.each { |label| assert_fully_visible_in_card(label) }
      click_tour_button(labels.last)
    end
    assert_no_selector "[data-testid='product-tour']", visible: :all
  ensure
    page.current_window.resize_to(1400, 1000)
  end

  test "a narrow navigation target gets the card beside it, not over the navigation" do
    sign_in_in_browser
    visit projects_path
    open_help_and_click "Product tour"
    click_tour_button "Next"
    assert_spotlight_on "[data-tour-target='nav-work']"

    sides = page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector("[data-testid='product-tour-card']").getBoundingClientRect()
        const target = document.querySelector("[data-tour-target='nav-work']").getBoundingClientRect()
        return [Math.round(card.left), Math.round(target.right)]
      })()
    JS
    assert_operator sides[0], :>=, sides[1], "the card starts right of the highlighted navigation"
    assert_equal "anchored", find("[data-testid='product-tour-card']")["data-placement"]
  end

  # The account's first visit to each page shows its guide once; ending it
  # (Done, Skip, Escape, or leaving the page) is remembered per page.
  test "after the welcome tour, each page's guide opens by itself once" do
    @user.update_columns(product_tour_version: nil, product_tour_outcome: nil, product_tour_page_guides: false)
    sign_in_in_browser
    visit projects_path
    within("[data-testid='product-tour-invite']") { click_button "Take the tour" }
    6.times { click_tour_button "Next" }
    click_tour_button "Done"
    assert_until { @user.reload.product_tour_page_guides }
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1

    visit glossaries_path
    assert_tour_step "1 of", "Glossaries"
    assert_selector "[data-testid='product-tour-card']", text: "Shown once. Replay it or turn these off under Help."
    click_tour_button "Next"
    click_tour_button "Done"
    assert_until { ProductTour.page_seen?(@user, "glossaries:list") }

    visit glossaries_path
    assert_selector "h1", text: "Glossaries"
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1

    visit translation_references_path
    assert_tour_step "1 of", "References"
    find("[data-testid='product-tour']").send_keys(:escape)
    assert_until { @user.product_tour_page_outcomes.find_by(tour_key: "translation_references:list")&.outcome == "dismissed" }
    visit translation_references_path
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1

    open_help_and_click "Guide to this page"
    assert_tour_step "1 of", "References"
    assert_no_selector "[data-testid='product-tour-card']", text: "Shown once."
    click_tour_button "Skip"
    assert_equal 2, @user.product_tour_page_outcomes.count, "a replay writes nothing more"
  end

  test "dismissing the welcome keeps page guides off until Help turns them on" do
    @user.update_columns(product_tour_version: nil, product_tour_outcome: nil, product_tour_page_guides: false)
    sign_in_in_browser
    visit projects_path
    # Help's border waits for the welcome window to be answered before it plays.
    assert_no_selector "#app-sidebar .th-neon--intro", visible: :all
    within("[data-testid='product-tour-invite']") { click_button "Not now" }
    assert_selector "#app-sidebar .th-neon--intro", visible: :all
    assert_until { @user.reload.product_tour_outcome == "dismissed" }

    visit glossaries_path
    assert_selector "h1", text: "Glossaries"
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1

    help = find("[data-react-island='product-tour'] button[aria-expanded]")
    help.click
    switch = find("[data-react-island='product-tour'] li button[aria-pressed]", text: "Show page guides automatically")
    assert_equal [ "false", "Off" ], [ switch["aria-pressed"], switch.find("span[aria-hidden]").text ]
    switch.click
    assert_until { @user.reload.product_tour_page_guides }
    assert_equal [ "true", "On" ], [ switch["aria-pressed"], switch.find("span[aria-hidden]").text ]

    visit translation_references_path
    assert_tour_step "1 of", "References"
    click_tour_button "Skip"

    find("[data-react-island='product-tour'] button[aria-expanded]").click
    # The appearance menu must not reset Help's switch (both use .appearance-option).
    find("[data-react-island='product-tour'] li button[aria-pressed='true']", text: "Show page guides automatically").click
    assert_until { !@user.reload.product_tour_page_guides }
    visit methodology_profiles_path
    assert_selector "h1", text: "Methodologies"
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1
  end

  test "an established account sees no page guide by itself" do
    sign_in_in_browser
    [ projects_path, glossaries_path, translation_references_path, history_path ].each do |path|
      visit path
      assert_selector "[data-react-island='product-tour'][data-react-mounted='true']"
      assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 0.5
    end
    assert_empty @user.product_tour_page_outcomes
  end

  # Turbo restores a cached copy of the page on Back, with props saying the
  # guide was not seen yet; leaving mid-guide counts as dismissing it.
  test "Back, Forward and leaving mid-guide never reopen a page guide" do
    @user.update_columns(product_tour_page_guides: true)
    sign_in_in_browser
    visit glossaries_path
    assert_tour_step "1 of", "Glossaries"
    click_tour_button "Skip"
    within("#app-sidebar") { click_link "History" }
    assert_tour_step "1 of", "Translation history"
    page.go_back
    assert_selector "h1", text: "Glossaries"
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1
    # Leaving History mid-guide dismissed it.
    assert_until { ProductTour.page_seen?(@user, "history:list") }
    page.go_forward
    assert_selector "h1", text: "Translation history"
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1
    page.refresh
    assert_selector "h1", text: "Translation history"
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1
  end

  test "Help is the first control in the sidebar and in the phone header, with its border still when motion is reduced" do
    sign_in_in_browser
    visit projects_path
    help = find("[data-react-island='product-tour'] button[aria-expanded]")
    assert_equal "Help", help.text
    first_link = find("#app-sidebar nav a", match: :first)
    assert_operator help.rect.y, :<, first_link.rect.y, "Help sits above the navigation"
    # The server reserves Help's height, so mounting it never shifts the
    # navigation under a resting pointer.
    reserved, mounted = page.evaluate_script(<<~JS)
      (() => { const island = document.getElementById("product-tour"); return [parseFloat(getComputedStyle(island).minHeight), island.getBoundingClientRect().height] })()
    JS
    assert_equal reserved, mounted
    intro = page.evaluate_script(<<~JS)
      (() => { const s = getComputedStyle(document.querySelector("#app-sidebar .th-neon__ring"), "::before"); return [s.animationName, s.animationIterationCount, parseFloat(s.animationDuration)] })()
    JS
    assert_equal "th-neon-turn", intro[0]
    assert_equal "1", intro[1]
    assert_operator intro[2], :<, 5, "the intro animation lasts under five seconds"

    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
    visit history_path
    still = page.evaluate_script("getComputedStyle(document.querySelector('#app-sidebar .th-neon__ring'), '::before').animationName")
    assert_equal "none", still
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])

    page.current_window.resize_to(375, 740)
    visit projects_path
    header_help = find("#app-header button[aria-expanded]", text: "Help")
    assert_no_selector "#app-sidebar", visible: true
    header_help.click
    assert_selector "#app-header li button", text: "Product tour"
    find("#app-header li button", text: "Product tour").click
    assert_tour_step "1 of 7", "Welcome to Three Heavens"
    click_tour_button "Skip"
    assert_equal "Help", active_element_text, "focus returns to the header's Help"
  ensure
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: []) rescue nil
    page.current_window.resize_to(1400, 1000)
  end

  private

  test "a newer page guide version opens again in the same visit, without a reload" do
    @user.update_columns(product_tour_page_guides: true)
    sign_in_in_browser
    visit glossaries_path
    assert_tour_step "1 of", "Glossaries"
    click_tour_button "Skip"
    glossaries = ProductTour.page_context_key("glossaries", "index", "GET")
    assert_until { ProductTour.page_seen?(@user, glossaries) }

    with_page_version(ProductTour::PAGE_VERSION + 1) do
      within("#app-sidebar") { click_link "Glossaries" }
      assert_tour_step "1 of", "Glossaries"
    end
  end

  test "turning page guides off and leaving at once never shows a guide on the next page" do
    @user.update_columns(product_tour_page_guides: true)
    @user.product_tour_page_outcomes.create!(tour_key: "projects:list", version: ProductTour::PAGE_VERSION, outcome: "completed")
    sign_in_in_browser
    visit projects_path
    hold_switch_requests
    open_help_and_click "Show page guides automatically"
    within("#app-sidebar") { click_link "Glossaries" }
    assert_selector "h1", text: "Glossaries"
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1
    assert_equal "false", guides_switch["aria-pressed"], "the new page shows the choice being saved"

    release_switch_requests
    assert_until { !@user.reload.product_tour_page_guides }
    assert_equal "false", guides_switch["aria-pressed"]
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1
  end

  test "turning page guides on and leaving at once shows the next page's guide once the choice is saved" do
    @user.product_tour_page_outcomes.create!(tour_key: "projects:list", version: ProductTour::PAGE_VERSION, outcome: "completed")
    sign_in_in_browser
    visit projects_path
    hold_switch_requests
    open_help_and_click "Show page guides automatically"
    within("#app-sidebar") { click_link "Glossaries" }
    assert_selector "h1", text: "Glossaries"
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1
    assert_equal "true", guides_switch["aria-pressed"]

    release_switch_requests
    assert_tour_step "1 of", "Glossaries"
    assert @user.reload.product_tour_page_guides
  end

  test "turning page guides back on and leaving at once never repeats a guide already seen" do
    @user.product_tour_page_outcomes.create!(tour_key: "projects:list", version: ProductTour::PAGE_VERSION, outcome: "completed")
    @user.product_tour_page_outcomes.create!(tour_key: ProductTour.page_context_key("glossaries", "index", "GET"),
                                              version: ProductTour::PAGE_VERSION, outcome: "completed")
    sign_in_in_browser
    visit projects_path
    hold_switch_requests
    open_help_and_click "Show page guides automatically"
    within("#app-sidebar") { click_link "Glossaries" }
    assert_selector "h1", text: "Glossaries"

    release_switch_requests
    assert_until { @user.reload.product_tour_page_guides }
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1
  end

  test "a switch change that fails is undone on the page reached meanwhile" do
    @user.update_columns(product_tour_page_guides: true)
    @user.product_tour_page_outcomes.create!(tour_key: "projects:list", version: ProductTour::PAGE_VERSION, outcome: "completed")
    sign_in_in_browser
    visit projects_path
    hold_switch_requests
    open_help_and_click "Show page guides automatically"
    within("#app-sidebar") { click_link "Glossaries" }
    assert_selector "h1", text: "Glossaries"
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1

    release_switch_requests(fail: true)
    assert_until { guides_switch["aria-pressed"] == "true" }
    assert @user.reload.product_tour_page_guides
    # Not on the page reached while the change was pending; normally afterwards.
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1
    within("#app-sidebar") { click_link "References" }
    assert_tour_step "1 of", "References"
  end

  test "Back and Forward show cached pages without opening their guides" do
    @user.update_columns(product_tour_version: nil, product_tour_outcome: nil, product_tour_page_guides: false)
    sign_in_in_browser
    visit glossaries_path
    within("[data-testid='product-tour-invite']") { click_button "Take the tour" }
    6.times { click_tour_button "Next" }
    click_tour_button "Done"
    assert_until { @user.reload.product_tour_page_guides }

    within("#app-sidebar") { click_link "References" }
    assert_tour_step "1 of", "References"
    click_tour_button "Skip"
    page.go_back
    assert_selector "h1", text: "Glossaries"
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1
    page.go_forward
    assert_selector "h1", text: "References"
    assert_no_selector "[data-testid='product-tour']", visible: :all, wait: 1

    # A fresh page load of the unseen page is a genuine first visit.
    visit glossaries_path
    assert_tour_step "1 of", "Glossaries"
  end

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

  # The button is inside the card's visible box and the viewport (not clipped
  # by the card's scrolling text area).
  def assert_fully_visible_in_card(label)
    visible = page.evaluate_script(<<~JS, label)
      (() => {
        const card = document.querySelector("[data-testid='product-tour-card']")
        const button = Array.from(card.querySelectorAll("button")).find((b) => b.textContent.trim() === arguments[0])
        if (!button) return false
        const c = card.getBoundingClientRect(), b = button.getBoundingClientRect()
        return b.top >= c.top && b.bottom <= c.bottom && b.left >= c.left && b.right <= c.right && b.bottom <= window.innerHeight
      })()
    JS
    assert visible, "#{label} is fully visible"
  end

  def assert_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  # Holds the page-guides switch's requests in this document (it survives
  # Turbo visits) until released, like a slow network; fail: answers 503.
  def hold_switch_requests
    page.execute_script(<<~JS)
      const original = window.fetch
      window.heldSwitchRequests = []
      window.fetch = (input, init) => {
        if (!String(input).includes("/product_tour/preference")) return original(input, init)
        return new Promise((resolve, reject) => window.heldSwitchRequests.push({ go: () => original(input, init).then(resolve, reject), fail: () => resolve(new Response(null, { status: 503 })) }))
      }
    JS
  end

  def release_switch_requests(fail: false)
    assert_until { page.evaluate_script("window.heldSwitchRequests.length") > 0 }
    page.execute_script("window.heldSwitchRequests.splice(0).forEach((request) => request[arguments[0] ? 'fail' : 'go']())", fail)
  end

  def guides_switch
    find("[data-react-island='product-tour'] li button[aria-pressed]", text: "Show page guides automatically", visible: :all)
  end

  def with_page_version(version)
    original = ProductTour::PAGE_VERSION
    ProductTour.send(:remove_const, :PAGE_VERSION)
    ProductTour.const_set(:PAGE_VERSION, version)
    yield
  ensure
    ProductTour.send(:remove_const, :PAGE_VERSION)
    ProductTour.const_set(:PAGE_VERSION, original)
  end

  # The accessible name of the focused element.
  def active_element_text
    page.evaluate_script("document.activeElement.getAttribute('aria-label') || document.activeElement.textContent.trim()")
  end
end
