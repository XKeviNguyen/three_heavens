require "application_system_test_case"

# Back and Forward against held responses. A traversal the workspace claims
# while it saves must leave no committed navigation state behind: no Turbo
# visit, head merge, snapshot, or history change, whatever arrives later.
class TranslationWorkspaceHistoryTest < ApplicationSystemTestCase
  TURBO_EVENTS = %w[turbo:visit turbo:before-cache turbo:before-render turbo:render turbo:load].freeze

  setup do
    visit login_path
    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  [ true, false ].each do |cache_cleared|
    test "a Back claimed after a failed save leaves no stale navigation state with cache cleared #{cache_cleared}" do
      open_workspace_from_projects
      install_history_harness
      clear_turbo_cache if cache_cleared
      page.execute_script("window.__harness.saveMode = 'fail'; window.__harness.holdPages.add('/projects')")
      fill_in "Project name", with: "Synthetic B protected text"
      assert_status I18n.t("workspace.save_failed")
      before = navigation_state

      page.execute_script("history.back()")
      assert_selector "dialog[open]", text: "Leave this translation?"
      click_button "Stay"
      release_stale_pages
      assert_unchanged_navigation_state before
      assert_no_page_requests

      page.execute_script("window.__harness.saveMode = 'ok'; window.dispatchEvent(new Event('online'))")
      assert_status I18n.t("workspace.saved")
      draft = users(:normal).translation_workspace_drafts.sole
      assert_equal "Synthetic B protected text", draft.payload.fetch("project_name")
      saved = navigation_state
      assert_equal before.slice("editorId", "sequence"), saved.slice("editorId", "sequence")
      assert_equal [ draft.public_id, draft.lock_version ], saved.values_at("draftId", "version")

      assert_back_from_projects_restores "Synthetic B protected text", history_length: before["historyLength"]
    end
  end

  test "Back and Forward churn during a delayed acknowledgement follows only the latest traversal" do
    open_workspace_from_projects
    install_history_harness
    clear_turbo_cache
    page.execute_script("window.__harness.saveMode = 'hold'")
    fill_in "Project name", with: "Acknowledged after churn"
    assert_until { page.evaluate_script("window.__harness.heldSaves.length === 1") }
    before = navigation_state

    [ "/projects", "/translation_workspace/new", "/projects", "/translation_workspace/new" ].each.with_index(1) do |path, count|
      page.execute_script(path == "/projects" ? "history.back()" : "history.forward()")
      assert_until { page.evaluate_script("location.pathname === arguments[0] && window.__harness.events['history:traverse'] === arguments[1]", path, count) }
    end
    assert_equal before["turboEvents"], navigation_state["turboEvents"]
    assert_no_page_requests
    page.execute_script("window.__harness.saveMode = 'ok'; window.__harness.heldSaves.shift().release()")

    # The latest traversal returned to the workspace: a fresh document fetched
    # after the acknowledgement shows the saved draft.
    assert_until { page.evaluate_script("!window.__harness") }
    assert_field "Project name", with: "Acknowledged after churn"
    draft = users(:normal).translation_workspace_drafts.sole
    assert_equal "Acknowledged after churn", draft.payload.fetch("project_name")
    assert_equal [ draft.public_id, draft.lock_version ], navigation_state.values_at("draftId", "version")
  end

  test "a failed discard during a claimed Back leaves no stale navigation state" do
    open_workspace_from_projects
    install_history_harness
    clear_turbo_cache
    page.execute_script("window.__harness.saveMode = 'hold'; window.__harness.discardMode = 'fail'; window.__harness.holdPages.add('/projects')")
    fill_in "Project name", with: "Kept after failed discard"
    assert_until { page.evaluate_script("window.__harness.heldSaves.length === 1") }
    before = navigation_state

    page.execute_script("history.back()")
    assert_until { page.evaluate_script("location.pathname === '/projects'") }
    accept_confirm { click_button "Discard draft" }
    page.execute_script("window.__harness.saveMode = 'ok'; window.__harness.heldSaves.shift().release()")
    assert_status I18n.t("workspace.discard_failed")
    release_stale_pages
    assert_unchanged_navigation_state before.merge("dirty" => false), ignore: %w[draftId version]
    assert_no_page_requests

    page.execute_script("window.__harness.discardMode = 'ok'")
    fill_in "Project name", with: "Latest after failed discard"
    assert_status I18n.t("workspace.saved")
    assert_equal "Latest after failed discard", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
    assert_back_from_projects_restores "Latest after failed discard", history_length: before["historyLength"]
  end

  test "a locale switch that cannot save cancels a claimed Back without stale navigation state" do
    open_workspace_from_projects
    install_history_harness
    clear_turbo_cache
    page.execute_script("window.__harness.saveMode = 'hold'; window.__harness.holdPages.add('/projects')")
    fill_in "Project name", with: "Kept after failed locale switch"
    assert_until { page.evaluate_script("window.__harness.heldSaves.length === 1") }
    before = navigation_state

    page.execute_script("history.back()")
    assert_until { page.evaluate_script("location.pathname === '/projects'") }
    within("aside#app-sidebar") { select "日本語", from: "Interface language" }
    assert_until { page.evaluate_script("location.pathname === '/translation_workspace/new'") }
    page.execute_script("window.__harness.saveMode = 'fail'; const held = window.__harness.heldSaves.shift(); held.fail = true; held.release()")
    within("aside#app-sidebar") { assert_field "Interface language", with: "en" }
    release_stale_pages
    assert_unchanged_navigation_state before
    assert_no_page_requests

    page.execute_script("window.__harness.saveMode = 'ok'; window.dispatchEvent(new Event('online'))")
    assert_status I18n.t("workspace.saved")
    assert_equal "Kept after failed locale switch", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
    assert_back_from_projects_restores "Kept after failed locale switch", history_length: before["historyLength"]
  end

  test "a clean Back freezes the page until its visit replaces it and Forward then Back lets the latest visit win" do
    open_workspace_from_projects
    fill_in "Project name", with: "Saved before leaving"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    clear_turbo_cache
    page.execute_script("window.__harness.holdPages.add('/projects'); window.__harness.holdPages.add('/translation_workspace/new')")

    page.execute_script("history.back()")
    assert_until { page.evaluate_script("window.__harness.heldPages.length === 1") }
    assert page.evaluate_script("document.querySelector(\"[data-controller='workspace-guard']\").inert")
    assert_equal "Saved before leaving", find_field("Project name").value
    page.execute_script("history.forward()")
    assert_until { page.evaluate_script("window.__harness.heldPages.length === 2") }
    page.execute_script("history.back()")
    assert_until { page.evaluate_script("window.__harness.heldPages.length === 3") }

    # The two superseded visits were cancelled; releasing them renders nothing.
    page.execute_script("window.__harness.heldPages.slice(0, 2).forEach(held => held.release())")
    page.execute_script("window.__harness.heldPages[2].release()")
    assert_selector "h1", text: "Projects"
    assert page.evaluate_script("window.__harness.heldPages.slice(0, 2).every(held => held.aborted)")
    assert_equal 1, page.evaluate_script("window.__harness.events['turbo:render']")

    page.execute_script("window.__harness.holdPages.clear()")
    page.go_forward
    assert_field "Project name", with: "Saved before leaving"
  end

  test "of two history visits the older response arriving last never renders" do
    visit settings_account_path
    click_link "Projects"
    # The sidebar on every page links to New translation; wait for Projects so
    # history holds settings, Projects, then the workspace.
    assert_selector "h1", text: "Projects"
    click_link "New translation"
    assert_field "Project name"
    install_history_harness
    clear_turbo_cache
    page.execute_script("window.__harness.holdPages.add('/projects'); window.__harness.holdPages.add('/settings/account')")

    page.execute_script("history.back()")
    assert_until { page.evaluate_script("window.__harness.heldPages.length === 1") }
    page.execute_script("history.back()")
    assert_until { page.evaluate_script("window.__harness.heldPages.length === 2") }
    page.execute_script("window.__harness.heldPages[1].release()")
    assert_current_path settings_account_path
    assert_until { page.evaluate_script("window.__harness.events['turbo:load'] === 1") }
    page.execute_script("window.__harness.heldPages[0].release()")
    assert page.evaluate_script("window.__harness.heldPages[0].aborted")
    assert_equal 1, page.evaluate_script("window.__harness.events['turbo:render']")
    assert_current_path settings_account_path
  end

  test "a late workspace response after a newer navigation never renders the workspace" do
    visit projects_path
    install_history_harness
    page.execute_script("window.__harness.holdPages.add('/translation_workspace/new')")
    click_link "New translation"
    assert_until { page.evaluate_script("window.__harness.heldPages.length === 1") }
    first("a[href='#{settings_account_path}']").click
    assert_current_path settings_account_path
    page.execute_script("window.__harness.heldPages[0].release()")
    assert page.evaluate_script("window.__harness.heldPages[0].aborted")
    assert_no_selector "[data-controller='workspace-guard']"
    assert_current_path settings_account_path
    assert_equal 0, users(:normal).translation_workspace_drafts.count
  end

  [ true, false ].each do |cache_cleared|
    test "clean Back and Forward stay in the same document with cache cleared #{cache_cleared}" do
      open_workspace_from_projects
      fill_in "Project name", with: "Clean history"
      assert_status I18n.t("workspace.saved")
      page.execute_script("window.__sameDocument = true")
      clear_turbo_cache if cache_cleared

      page.go_back
      assert_selector "h1", text: "Projects"
      page.go_forward
      assert_field "Project name", with: "Clean history"
      assert page.evaluate_script("window.__sameDocument === true")
      assert_not page.evaluate_script("document.querySelector(\"[data-controller='workspace-guard']\").inert")
      fill_in "Project name", with: "Edited after clean history"
      assert_status I18n.t("workspace.saved")
      assert_equal "Edited after clean history", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
    end
  end

  test "a workspace restored from the back and forward cache shows the current draft" do
    assert_field "Project name"
    visit projects_path
    click_link "New translation"
    fill_in "Project name", with: "Saved in a later document"
    assert_status I18n.t("workspace.saved")

    # Two steps back is the sign-in landing workspace in the earlier document,
    # which the browser may restore with its draft and editor from before.
    page.go_back
    assert_selector "h1", text: "Projects"
    page.go_back
    assert_field "Project name", with: "Saved in a later document"
    fill_in "Project name", with: "Edited after restoration"
    assert_status I18n.t("workspace.saved")
    assert_equal "Edited after restoration", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
  end

  test "a claimed Back to an entry with a fragment leaves once the save is acknowledged" do
    visit projects_path
    page.execute_script(<<~JS)
      document.addEventListener("turbo:load", () => { window.__fragmentLoaded = true }, { once: true })
      document.querySelector("a[href='#main-content']").click()
    JS
    # Turbo follows the skip link with a visit that replaces the body.
    assert_until { page.evaluate_script("location.hash === '#main-content' && window.__fragmentLoaded === true") }
    click_link "New translation"
    assert_field "Project name"
    install_history_harness
    fill_in "Project name", with: "Saved before fragment Back"
    page.execute_script("history.back()")
    # The entry is reloaded as a fresh document once the save is acknowledged.
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_selector "h1", text: "Projects"
    assert_current_path projects_path
    assert_equal "#main-content", page.evaluate_script("location.hash")
    assert_equal "Saved before fragment Back", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
  end

  test "a workspace restored from the back and forward cache after Leave is guarded again" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'fail'")
    fill_in "Project name", with: "Abandoned by Leave"
    assert_status I18n.t("workspace.save_failed")
    page.execute_script("history.back()")
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Leave"
    assert_selector "h1", text: "Projects"

    page.go_back
    assert_selector "h1", text: "New translation"
    assert_nil page.evaluate_script("window.__harness"), "the restored page must be a fresh document"
    fill_in "Project name", with: "Guarded after restoration"
    assert_status I18n.t("workspace.saved")
    assert_equal "Guarded after restoration", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
  end

  test "a change made by a script while a clean visit loads is still saved" do
    open_workspace_from_projects
    fill_in "Project name", with: "Saved before leaving"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    clear_turbo_cache
    page.execute_script("window.__harness.holdPages.add('/projects')")
    click_link "Projects"
    assert_until { page.evaluate_script("window.__harness.heldPages.length === 1") }
    finish_import_while_leaving

    page.execute_script("window.__harness.heldPages[0].release()")
    assert_selector "h1", text: "Projects"
    assert_until { users(:normal).translation_workspace_drafts.sole.payload.fetch("source_text") == "Arrived while leaving" }
    assert page.evaluate_script("!!window.__harness")
  end

  test "Back while a clean visit loads is Turbo's even after a script changed the page" do
    open_workspace_from_projects
    fill_in "Project name", with: "Saved before leaving"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    clear_turbo_cache
    page.execute_script("window.__harness.holdPages.add('/projects')")
    click_link "Projects"
    assert_until { page.evaluate_script("window.__harness.heldPages.length === 1") }
    finish_import_while_leaving

    page.execute_script("history.back()")
    assert_until { page.evaluate_script("window.__harness.heldPages.length === 2 && window.__harness.heldPages[0].aborted === true") }
    page.execute_script("window.__harness.heldPages.forEach(held => held.release())")
    assert_selector "h1", text: "Projects"
    assert_equal 1, page.evaluate_script("window.__harness.events['turbo:render']")
    assert_until { users(:normal).translation_workspace_drafts.sole.payload.fetch("source_text") == "Arrived while leaving" }
  end

  test "Leave to the same page with a fragment loads a fresh page" do
    open_workspace_from_projects
    page.execute_script(<<~JS)
      document.addEventListener("turbo:load", () => { window.__fragmentLoaded = true }, { once: true })
      document.querySelector("a[href='#main-content']").click()
    JS
    assert_until { page.evaluate_script("location.hash === '#main-content' && window.__fragmentLoaded === true") }
    page.go_back
    assert_until { page.evaluate_script("location.hash === '' && !!document.querySelector(\"[data-controller='workspace-guard']\")") }
    assert_field "Project name"
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'fail'")
    fill_in "Project name", with: "Abandoned by Leave"
    assert_status I18n.t("workspace.save_failed")

    page.execute_script("history.forward()")
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Leave"
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_field "Project name", with: ""
    assert_empty users(:normal).translation_workspace_drafts
  end

  test "a launch rejected after more typing renders a page that can still save" do
    open_workspace_from_projects
    fill_in "Project name", with: "Rejected launch project"
    choose_known_language("Source language", "Vietnamese")
    choose_known_language("Target language", "Japanese")
    fill_in "Document title", with: "Rejected launch document"
    fill_in "Source text", with: "Rejected launch source"
    fill_in "Instructions for the translation", with: "Translate carefully."
    assert_status I18n.t("workspace.saved")
    install_history_harness
    page.execute_script(<<~JS)
      const deliver = window.fetch
      window.fetch = async (url, options = {}) => {
        const response = await deliver(url, options)
        if (new URL(url, location.origin).pathname === "/translation_workspace" && (options.method || "").toUpperCase() === "POST") {
          await new Promise(resolve => { window.__releaseLaunch = resolve })
        }
        return response
      }
    JS
    click_button "Start translation"
    assert_until { page.evaluate_script("!!window.__releaseLaunch") }
    page.execute_script(<<~JS)
      const field = document.querySelector("[name='translation_workspace[source_text]']")
      field.value = "Typed while the launch was checked"
      field.dispatchEvent(new Event("input", { bubbles: true }))
      window.__releaseLaunch()
    JS
    assert_selector "#form-errors-heading"
    fill_in "Document title", with: "Fixed after rejection"
    assert_status I18n.t("workspace.saved")
    assert_equal "Fixed after rejection", users(:normal).translation_workspace_drafts.sole.payload.fetch("document_title")
  end

  private

  # What a source import that completes late does to the form.
  def finish_import_while_leaving
    page.execute_script(<<~JS)
      const field = document.querySelector("[name='translation_workspace[source_text]']")
      field.value = "Arrived while leaving"
      field.dispatchEvent(new Event("input", { bubbles: true }))
    JS
  end

  def open_workspace_from_projects
    visit projects_path
    click_link "New translation"
    assert_field "Project name"
  end

  def clear_turbo_cache
    page.execute_script("window.Turbo.cache.clear()")
  end

  # Draft saves can fail or be held; page GETs for listed paths are held after
  # the server responded and reject like the network would if Turbo aborts.
  def install_history_harness
    page.execute_script(<<~JS, TURBO_EVENTS)
      const turboEvents = arguments[0]
      const deliver = window.fetch.bind(window)
      const harness = window.__harness = { saveMode: "ok", discardMode: "ok", heldSaves: [], holdPages: new Set(), heldPages: [], pageRequests: [], events: {} }
      const hold = (list, entry, signal) => new Promise((resolve, reject) => {
        entry.release = resolve
        list.push(entry)
        signal?.addEventListener("abort", () => { entry.aborted = true; reject(new DOMException("Aborted", "AbortError")) }, { once: true })
      })
      window.fetch = async (url, options = {}) => {
        const target = new URL(url, location.origin)
        const method = (options.method || "GET").toUpperCase()
        if (target.pathname === "/translation_workspace_draft") {
          if (method === "POST" && harness.saveMode === "fail") return new Response("", { status: 503 })
          if (method === "POST" && harness.saveMode === "hold") {
            const held = {}
            await hold(harness.heldSaves, held)
            if (held.fail) return new Response("", { status: 503 })
          }
          if (method === "DELETE" && harness.discardMode === "fail") return new Response("", { status: 503 })
          return deliver(url, options)
        }
        if (method === "GET") harness.pageRequests.push(target.pathname)
        const response = await deliver(url, options)
        if (method === "GET" && harness.holdPages.has(target.pathname)) await hold(harness.heldPages, { path: target.pathname }, options.signal)
        return response
      }
      window.addEventListener("history:traverse", () => { harness.events["history:traverse"] = (harness.events["history:traverse"] || 0) + 1 })
      for (const name of turboEvents) document.addEventListener(name, () => { harness.events[name] = (harness.events[name] || 0) + 1 })
    JS
  end

  # Navigation-critical page state: location and history, the head settings
  # Turbo reads, the root markers a visit leaves, and the editor identity.
  def navigation_state
    JSON.parse(page.evaluate_script(<<~JS, TURBO_EVENTS))
      (() => {
        const element = document.querySelector("[data-controller='workspace-guard']")
        const controller = element && window.Stimulus.getControllerForElementAndIdentifier(element, "workspace-guard")
        const root = document.documentElement
        const events = window.__harness?.events || {}
        return JSON.stringify({
          href: location.href, historyState: history.state, historyLength: history.length, title: document.title,
          turboMeta: Array.from(document.head.querySelectorAll("meta[name^='turbo-']"), meta => [meta.name, meta.content]),
          lang: root.lang, busy: root.getAttribute("aria-busy"), preview: root.hasAttribute("data-turbo-preview"),
          direction: root.getAttribute("data-turbo-visit-direction"), h1: document.querySelector("h1")?.textContent.trim(),
          editorId: controller?.editorId, sequence: controller?.sequence, dirty: controller?.dirty(),
          draftId: controller?.draftIdValue, version: controller?.versionValue,
          projectName: document.querySelector("[name='translation_workspace[project_name]']")?.value,
          turboEvents: arguments[0].map(name => events[name] || 0)
        })
      })()
    JS
  end

  # Wait two frames so a cached snapshot render queued by a history visit has
  # run, then deliver any held page response a superseded visit still owns
  # and wait until Turbo has finished with it.
  def release_stale_pages
    page.evaluate_async_script("const done = arguments[0]; requestAnimationFrame(() => requestAnimationFrame(() => done()))")
    held = page.evaluate_script("window.__harness.heldPages.filter(held => !held.aborted).length")
    return if held.zero?

    loads = page.evaluate_script("window.__harness.events['turbo:load'] || 0")
    page.execute_script("window.__harness.heldPages.forEach(held => held.release())")
    assert_until { page.evaluate_script("(window.__harness.events['turbo:load'] || 0) > arguments[0]", loads) }
  end

  def assert_unchanged_navigation_state(before, ignore: [])
    after = navigation_state
    assert_equal "New translation", after["h1"]
    assert_equal before.except(*ignore), after.except(*ignore)
    assert_includes after["turboMeta"], [ "turbo-cache-control", "no-cache" ]
  end

  def assert_no_page_requests
    assert_empty page.evaluate_script("window.__harness.pageRequests")
  end

  # Projects is a new history entry after the workspace one, so Back returns to
  # the workspace in the same document and renders the acknowledged draft.
  def assert_back_from_projects_restores(project_name, history_length:)
    page.execute_script("window.__harness.holdPages.clear(); window.__sameDocument = true")
    click_link "Projects"
    assert_selector "h1", text: "Projects"
    assert_equal history_length, page.evaluate_script("history.length")
    page.go_back
    assert_selector "h1", text: "New translation"
    assert_field "Project name", with: project_name
    assert page.evaluate_script("window.__sameDocument === true")
    draft = users(:normal).translation_workspace_drafts.sole
    assert_equal project_name, draft.payload.fetch("project_name")
    restored = navigation_state
    assert_equal [ draft.public_id, draft.lock_version, false ], restored.values_at("draftId", "version", "dirty")
  end

  def assert_status(text)
    assert_selector "[data-workspace-guard-target='status']", text:, wait: 10
  end

  def assert_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end
end
