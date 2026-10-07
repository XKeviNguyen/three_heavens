require "tempfile"
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

  teardown { @import_file&.close! }

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

      assert_back_from_projects_restores "Synthetic B protected text"
    end
  end

  test "Leave after a refused Back loads the entry Back reached and keeps the workspace ahead of it" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'fail'")
    fill_in "Project name", with: "Abandoned by Leave after Back"
    assert_status I18n.t("workspace.save_failed")

    page.execute_script("history.back()")
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Leave"
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_selector "h1", text: "Projects"
    # Nothing was added after Projects, so Forward still reaches the workspace.
    page.go_forward
    assert_selector "h1", text: "New translation"
  end

  test "Leave for a link reaches it even after a Back was claimed while the dialog was open" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'fail'")
    fill_in "Project name", with: "Abandoned for the link"
    assert_status I18n.t("workspace.save_failed")
    # History, not Projects, which the claimed Back below reaches.
    within("aside#app-sidebar") { click_link "History" }
    assert_selector "dialog[open]", text: "Leave this translation?"
    page.execute_script("window.__harness.saveMode = 'hold'; history.back()")
    assert_until { page.evaluate_script("window.__harness.heldSaves.length > 0") }

    click_button "Leave"
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_current_path history_path
  end

  test "a link clicked while a claimed Back saves loads natively from the entry Back reached" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'hold'")
    fill_in "Project name", with: "Saved before the History link"
    assert_until { page.evaluate_script("window.__harness.heldSaves.length === 1") }
    page.execute_script("history.back()")
    assert_until { page.evaluate_script("location.pathname === '/projects'") }
    within("aside#app-sidebar") { click_link "History" }

    page.execute_script("window.__harness.saveMode = 'ok'; window.__harness.heldSaves.shift().release()")
    # A browser load, so Turbo starts over with positions that match history.
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_current_path history_path
    assert_selector "h1", text: "Experiment history"
    assert_equal "", page.evaluate_script("location.hash")
    assert_equal "Saved before the History link", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
    page.go_back
    assert_selector "h1", text: "Projects"
  end

  test "a skip link that follows a claimed Back to the same URL loads the saved workspace" do
    visit new_translation_workspace_path
    assert_field "Project name"
    within("aside#app-sidebar") { click_link "History" }
    assert_current_path history_path
    within("aside#app-sidebar") { click_link "New translation" }
    assert_field "Project name"
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'hold'")
    fill_in "Project name", with: "Saved before the skip link"
    assert_until { page.evaluate_script("window.__harness.heldSaves.length === 1") }
    # Two claimed Backs reach the first workspace entry, the same URL as this page.
    page.execute_script("history.go(-2)")
    assert_until { page.evaluate_script("window.__harness.events['history:traverse'] === 1") }
    page.execute_script("document.querySelector(\"a[href='#main-content']\").click()")

    page.execute_script("window.__harness.saveMode = 'ok'; window.__harness.heldSaves.shift().release()")
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_equal "#main-content", page.evaluate_script("location.hash")
    assert_selector "#main-content:target"
    assert_field "Project name", with: "Saved before the skip link"
    assert_not page.evaluate_script("document.querySelector(\"[data-controller='workspace-guard']\").inert")
  end

  test "Leave through the skip link loads a fresh workspace at the requested fragment" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'fail'")
    fill_in "Project name", with: "Abandoned through the skip link"
    assert_status I18n.t("workspace.save_failed")

    page.execute_script("document.querySelector(\"a[href='#main-content']\").click()")
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Leave"

    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_equal "#main-content", page.evaluate_script("location.hash")
    assert_selector "#main-content:target"
    assert_field "Project name", with: ""
    assert_empty users(:normal).translation_workspace_drafts
    assert_not page.evaluate_script("document.querySelector(\"[data-controller='workspace-guard']\").inert")
  end

  test "discard after a claimed Back to a workspace fragment loads a fresh empty document" do
    visit "#{new_translation_workspace_path}#main-content"
    assert_field "Project name"
    within("aside#app-sidebar") { click_link "History" }
    assert_current_path history_path
    within("aside#app-sidebar") { click_link "New translation" }
    assert_field "Project name"
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'hold'")
    fill_in "Project name", with: "Discarded after fragment Back"
    assert_until { page.evaluate_script("window.__harness.heldSaves.length === 1") }
    editor_id = navigation_state.fetch("editorId")
    # Hold the forced-load boundary after DELETE so this also catches browsers
    # that happen to fetch a document for a fragment-only location.assign.
    page.execute_script(<<~JS)
      const element = document.querySelector("[data-controller='workspace-guard']")
      const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "workspace-guard")
      const load = controller.load.bind(controller)
      controller.load = url => { window.__releaseDocumentLoad = () => load(url) }
    JS

    page.execute_script("history.go(-2)")
    assert_until { page.evaluate_script("location.hash === '#main-content' && window.__harness.events['history:traverse'] === 1") }
    accept_confirm { click_button "Discard draft" }
    page.execute_script("window.__harness.saveMode = 'ok'; window.__harness.heldSaves.shift().release()")
    assert_until { page.evaluate_script("!!window.__releaseDocumentLoad") }
    assert_empty users(:normal).translation_workspace_drafts
    page.execute_script("window.__releaseDocumentLoad()")

    # The held save must finish before DELETE; the new server-rendered editor
    # and empty database prove the document was fetched after that DELETE.
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_current_path new_translation_workspace_path, ignore_query: false
    assert_equal "", page.evaluate_script("location.hash")
    assert_field "Project name", with: ""
    assert_empty users(:normal).translation_workspace_drafts
    assert_not_equal editor_id, navigation_state.fetch("editorId")
    assert_not page.evaluate_script("document.querySelector(\"[data-controller='workspace-guard']\").inert")
  end

  test "discard at the same URL reloads a fresh empty workspace" do
    open_workspace_from_projects
    fill_in "Project name", with: "Discarded at the same URL"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    editor_id = navigation_state.fetch("editorId")
    accept_confirm { click_button "Discard draft" }

    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_current_path new_translation_workspace_path, ignore_query: false
    assert_equal "", page.evaluate_script("location.hash")
    assert_field "Project name", with: ""
    assert_empty users(:normal).translation_workspace_drafts
    assert_not_equal editor_id, navigation_state.fetch("editorId")
    assert_not page.evaluate_script("document.querySelector(\"[data-controller='workspace-guard']\").inert")
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
    assert_back_from_projects_restores "Latest after failed discard"
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
    assert_back_from_projects_restores "Kept after failed locale switch"
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

  test "Leave freezes the page, and a newer link replaces its browser load" do
    leave_to_a_download
    click_link "Projects"
    # A browser load, not a Turbo visit that the pending load could override.
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_selector "h1", text: "Projects"
  end

  test "a language switch after Leave replaces its browser load" do
    leave_to_a_download
    within("aside#app-sidebar") { select "日本語", from: "Interface language" }
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_selector "html[lang='ja']"
    assert_equal "ja", users(:normal).reload.locale
  end

  test "Back after Leave replaces its browser load" do
    leave_to_a_download
    page.execute_script("history.back()")
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_selector "h1", text: "Projects"
  end

  test "an import that finishes after a link is clicked reaches the draft before the page leaves" do
    open_workspace_from_projects
    fill_in "Project name", with: "Import before leaving"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    start_held_import("Imported before Projects")
    click_link "Projects"
    # The import is still pending, so the page waits instead of leaving.
    assert_no_page_requests
    assert_selector "h1", text: "New translation"

    page.execute_script("window.__releaseImport()")
    assert_selector "h1", text: "Projects"
    assert_imported_draft "Imported before Projects"
  end

  test "Back during a pending import waits for it, saves, then follows Back" do
    open_workspace_from_projects
    fill_in "Project name", with: "Import before Back"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    start_held_import("Imported before Back")
    page.execute_script("history.back()")
    assert_until { page.evaluate_script("location.pathname === '/projects'") }
    assert_no_page_requests
    assert_selector "h1", text: "New translation"

    page.execute_script("window.__releaseImport()")
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_selector "h1", text: "Projects"
    assert_imported_draft "Imported before Back"
  end

  test "an import that finishes while leaving for the same workspace reaches the draft and the new page" do
    open_workspace_from_projects
    fill_in "Project name", with: "Same draft import"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    start_held_import("Imported for the same draft")
    first("a[href='#{new_translation_workspace_path}']").click
    assert_no_page_requests

    page.execute_script("window.__releaseImport()")
    assert_until { page.evaluate_script("window.__harness.events['turbo:load'] === 1") }
    assert_field "Reviewed source text", with: "Imported for the same draft"
    assert_imported_draft "Imported for the same draft"
    fill_in "Project name", with: "Edited on the new page"
    assert_status I18n.t("workspace.saved")
    assert_equal "Edited on the new page", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
  end

  test "a launch freezes the page so nothing typed is lost when it is rejected" do
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
    assert page.evaluate_script("document.querySelector(\"[data-controller='workspace-guard']\").inert")
    begin
      find_field("Document title").send_keys(" typed during launch")
    rescue Selenium::WebDriver::Error::ElementNotInteractableError
      # An inert field refuses keyboard input outright in some drivers.
    end
    assert_equal "Rejected launch document", find_field("Document title").value

    page.execute_script("window.__releaseLaunch()")
    assert_selector "#form-errors-heading"
    assert_field "Document title", with: "Rejected launch document"
    fill_in "Document title", with: "Fixed after rejection"
    assert_status I18n.t("workspace.saved")
    assert_equal "Fixed after rejection", users(:normal).translation_workspace_drafts.sole.payload.fetch("document_title")
  end

  test "Back during a launch keeps the page frozen until the newer visit replaces it" do
    open_workspace_from_projects
    fill_in "Project name", with: "Launch abandoned by Back"
    choose_known_language("Source language", "Vietnamese")
    choose_known_language("Target language", "Japanese")
    fill_in "Document title", with: "Abandoned launch document"
    fill_in "Source text", with: "Abandoned launch source"
    fill_in "Instructions for the translation", with: "Translate carefully."
    assert_status I18n.t("workspace.saved")
    install_history_harness
    clear_turbo_cache
    page.execute_script(<<~JS)
      window.__harness.holdPages.add("/projects")
      const deliver = window.fetch
      window.fetch = async (url, options = {}) => {
        if (new URL(url, location.origin).pathname === "/translation_workspace" && (options.method || "").toUpperCase() === "POST") {
          window.__launchHeld = true
          return new Promise((_resolve, reject) => {
            options.signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true })
          })
        }
        return deliver(url, options)
      }
      document.addEventListener("turbo:submit-end", () => { window.__submitEnded = true })
    JS
    click_button "Start translation"
    assert_until { page.evaluate_script("window.__launchHeld === true") }
    page.execute_script("history.back()")
    assert_until { page.evaluate_script("window.__submitEnded === true && window.__harness.heldPages.length === 1") }
    assert page.evaluate_script("document.querySelector(\"[data-controller='workspace-guard']\").inert")

    page.execute_script("window.__harness.heldPages[0].release()")
    assert_selector "h1", text: "Projects"
    assert_equal "Launch abandoned by Back", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
  end

  test "the page is frozen while an interface-language switch is in flight" do
    open_workspace_from_projects
    fill_in "Project name", with: "Kept across the language switch"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    page.execute_script(<<~JS)
      const deliver = window.fetch
      window.fetch = async (url, options = {}) => {
        const response = await deliver(url, options)
        if (new URL(url, location.origin).pathname === "/locale") await new Promise(resolve => { window.__releaseLocale = resolve })
        return response
      }
    JS
    within("aside#app-sidebar") { select "日本語", from: "Interface language" }
    assert_until { page.evaluate_script("!!window.__releaseLocale") }
    assert page.evaluate_script("document.querySelector(\"[data-controller='workspace-guard']\").inert")

    page.execute_script("window.__releaseLocale()")
    assert_selector "html[lang='ja']"
    assert_field "プロジェクト名", with: "Kept across the language switch"
  end

  test "signing out from a page that cannot save leaves a usable Stay or Leave choice" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'fail'")
    fill_in "Project name", with: "Unsaved at sign out"
    assert_status I18n.t("workspace.save_failed")

    click_button "Log out"
    assert_selector "dialog[open]", text: "Leave this translation?"
    assert_not page.evaluate_script("document.querySelector(\"[data-controller='workspace-guard']\").inert")
    click_button "Leave"
    assert_current_path login_path
  end

  test "a language switch that cancels a loading visit and fails leaves the page usable" do
    open_workspace_from_projects
    fill_in "Project name", with: "Usable after failed switch"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    clear_turbo_cache
    page.execute_script(<<~JS)
      window.__harness.holdPages.add("/projects")
      const deliver = window.fetch
      window.fetch = (url, options = {}) => {
        if (new URL(url, location.origin).pathname === "/locale") return Promise.reject(new TypeError("Failed to fetch"))
        return deliver(url, options)
      }
      document.addEventListener("turbo:submit-end", () => { window.__localeEnded = true })
    JS
    click_link "Projects"
    assert_until { page.evaluate_script("window.__harness.heldPages.length === 1") }
    within("aside#app-sidebar") { select "日本語", from: "Interface language" }
    assert_until { page.evaluate_script("window.__localeEnded === true && window.__harness.heldPages[0].aborted === true") }

    assert_not page.evaluate_script("document.querySelector(\"[data-controller='workspace-guard']\").inert")
    fill_in "Project name", with: "Edited after failed switch"
    assert_status I18n.t("workspace.saved")
  end

  test "Back pressed while a launch waits for a pending import wins and the launch is never sent" do
    open_workspace_from_projects
    fill_in "Project name", with: "Back wins over launch"
    choose_known_language("Source language", "Vietnamese")
    choose_known_language("Target language", "Japanese")
    fill_in "Document title", with: "Launch waiting document"
    fill_in "Source text", with: "Typed before the import"
    fill_in "Instructions for the translation", with: "Translate carefully."
    assert_status I18n.t("workspace.saved")
    install_history_harness
    start_held_import("Imported while launching")
    page.execute_script(<<~JS)
      document.addEventListener("turbo:before-fetch-request", event => {
        if (event.detail.fetchOptions.method === "POST" && new URL(event.detail.url).pathname === "/translation_workspace") sessionStorage.setItem("launchSent", "true")
      })
    JS
    page.execute_script("document.addEventListener('submit', () => { window.__launchSubmitted = true }, { capture: true, once: true })")
    # Activate the button itself, independent of where the sticky bar is drawn.
    find_button("Start translation").execute_script("this.click()")
    assert_until { page.evaluate_script("window.__launchSubmitted === true") }
    assert_status I18n.t("workspace.saving")
    page.execute_script("history.back()")
    assert_until { page.evaluate_script("location.pathname === '/projects' && window.__harness.events['history:traverse'] === 1") }

    page.execute_script("window.__releaseImport()")
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_selector "h1", text: "Projects"
    assert_nil page.evaluate_script("sessionStorage.getItem('launchSent')")
    assert_imported_draft "Imported while launching"
  end

  test "a discard with no draft after a claimed Back still loads the fresh workspace" do
    open_workspace_from_projects
    install_history_harness
    # Nothing typed, so no draft exists and the discard sends no request; a
    # pending import keeps the page busy, so Back is claimed and waits.
    start_held_import("Never reaches the draft")
    page.execute_script("history.back()")
    assert_until { page.evaluate_script("window.__harness.events['history:traverse'] === 1 && location.pathname === '/projects'") }

    accept_confirm { click_button "Discard draft" }
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_current_path new_translation_workspace_path
    assert_field "Project name", with: ""
    assert_empty users(:normal).translation_workspace_drafts
  end

  test "a discard freezes the page before the fresh workspace loads" do
    open_workspace_from_projects
    fill_in "Project name", with: "Discarded and frozen"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    page.execute_script(<<~JS)
      window.addEventListener("pagehide", () => {
        sessionStorage.setItem("inertAtPagehide", String(document.querySelector("[data-controller='workspace-guard']").inert))
      })
    JS
    accept_confirm { click_button "Discard draft" }
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_field "Project name", with: ""
    assert_equal "true", page.evaluate_script("sessionStorage.getItem('inertAtPagehide')")
    page.execute_script("sessionStorage.removeItem('inertAtPagehide')")
    assert_empty users(:normal).translation_workspace_drafts
  end

  test "a link after a discard replaces the fresh workspace's browser load" do
    open_workspace_from_projects
    fill_in "Project name", with: "Discarded before a link"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    # The fresh workspace's load is stopped as soon as it starts, so the page
    # stays. Whether that load is stopped or still pending, a link must
    # replace it with a browser load, never a Turbo visit.
    page.execute_script(<<~JS)
      const deliver = window.fetch
      window.fetch = async (url, options = {}) => {
        const response = await deliver(url, options)
        if ((options.method || "").toUpperCase() === "DELETE") setTimeout(() => { window.stop(); window.__stopped = true }, 0)
        return response
      }
    JS
    accept_confirm { click_button "Discard draft" }
    assert_until { page.evaluate_script("window.__stopped === true") }
    assert page.evaluate_script("document.querySelector(\"[data-controller='workspace-guard']\").inert")

    click_link "Projects"
    assert_until { page.evaluate_script("!window.__harness && document.readyState === 'complete'") }
    assert_selector "h1", text: "Projects"
    assert_empty users(:normal).translation_workspace_drafts
  end

  test "a refused discard does not resend content the server refused for good" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'conflict'")
    fill_in "Project name", with: "Refused, then discarded"
    # Leaving the field now keeps its change event out of the recording below.
    page.execute_script("document.activeElement.blur()")
    assert_status I18n.t("workspace.save_conflict")
    page.execute_script(<<~JS)
      window.__harness.discardMode = "fail"
      const schedule = window.setTimeout
      window.__delays = []
      window.setTimeout = (callback, delay, ...rest) => {
        window.__delays.push(delay)
        return schedule(callback, delay, ...rest)
      }
    JS
    accept_confirm { click_button "Discard draft" }
    assert_status I18n.t("workspace.discard_failed")
    assert_not_includes page.evaluate_script("window.__delays"), 1000
  end

  test "a refused discard resends content refused earlier once a later save succeeded" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'conflict'")
    fill_in "Project name", with: "Refused once"
    page.execute_script("document.activeElement.blur()")
    assert_status I18n.t("workspace.save_conflict")
    page.execute_script("window.__harness.saveMode = 'ok'")
    fill_in "Project name", with: "Saved in between"
    page.execute_script("document.activeElement.blur()")
    assert_status I18n.t("workspace.saved")
    # The refused content again, now merely unsaved.
    page.execute_script("window.__harness.saveMode = 'fail'")
    fill_in "Project name", with: "Refused once"
    page.execute_script("document.activeElement.blur()")
    assert_status I18n.t("workspace.save_failed")
    page.execute_script(<<~JS)
      window.__harness.discardMode = "fail"
      const schedule = window.setTimeout
      window.__delays = []
      window.setTimeout = (callback, delay, ...rest) => {
        window.__delays.push(delay)
        return schedule(callback, delay, ...rest)
      }
    JS
    accept_confirm { click_button "Discard draft" }
    assert_status I18n.t("workspace.discard_failed")
    assert_includes page.evaluate_script("window.__delays"), 1000
  end

  test "an edit not yet sent when a discard is refused is saved afterwards" do
    open_workspace_from_projects
    fill_in "Project name", with: "Saved before the edit"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    # Autosave debounces wait until the test runs them, so the edit below is
    # still unsent when the discard starts and cancels its debounce.
    page.execute_script(<<~JS)
      const schedule = window.setTimeout
      const cancel = window.clearTimeout
      const debounces = window.__debounces = new Map()
      let next = 0
      window.setTimeout = (callback, delay, ...rest) => {
        if (delay !== 1000) return schedule(callback, delay, ...rest)
        const id = -(++next)
        debounces.set(id, callback)
        return id
      }
      window.clearTimeout = id => id < 0 ? debounces.delete(id) : cancel(id)
      window.__harness.discardMode = "fail"
    JS
    fill_in "Project name", with: "Unsent when the discard was refused"
    accept_confirm { click_button "Discard draft" }
    assert_status I18n.t("workspace.discard_failed")

    page.execute_script("window.__debounces.forEach(callback => callback()); window.__debounces.clear()")
    assert_until { users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name") == "Unsent when the discard was refused" }
    assert_status I18n.t("workspace.discard_failed")
  end

  test "edits typed while a discard is refused are saved afterwards" do
    open_workspace_from_projects
    fill_in "Project name", with: "Before the refused discard"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    page.execute_script("window.__harness.discardMode = 'hold'")
    accept_confirm { click_button "Discard draft" }
    assert_until { page.evaluate_script("window.__harness.heldDiscards.length === 1") }
    fill_in "Project name", with: "Typed during the refused discard"

    page.execute_script("window.__harness.heldDiscards.shift().release()")
    assert_until { users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name") == "Typed during the refused discard" }
    # Saving them does not hide that the discard was refused; the next edit does.
    assert_status I18n.t("workspace.discard_failed")
    fill_in "Project name", with: "Edited after the refused discard"
    assert_status I18n.t("workspace.saved")
  end

  test "a pending import that ends without a change never hides a failed discard" do
    open_workspace_from_projects
    fill_in "Project name", with: "Discard fails during import"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    page.execute_script("window.__harness.discardMode = 'fail'")
    page.execute_script(<<~JS)
      const deliver = window.fetch
      window.fetch = async (url, options = {}) => {
        if (new URL(url, location.origin).pathname === "/source_imports.json") {
          await new Promise(resolve => { window.__releaseImport = resolve })
          return new Response(JSON.stringify({ error: "Rejected import" }), { status: 422, headers: { "Content-Type": "application/json" } })
        }
        return deliver(url, options)
      }
    JS
    click_button "Upload file"
    @import_file = Tempfile.new([ "rejected-import", ".txt" ])
    @import_file.write("Never imported")
    @import_file.flush
    attach_file "Source file", @import_file.path
    click_button "Upload and review"
    assert_until { page.evaluate_script("!!window.__releaseImport") }

    accept_confirm { click_button "Discard draft" }
    assert_status I18n.t("workspace.discard_failed")
    page.execute_script("window.__releaseImport()")
    assert_text "Rejected import"
    assert_status I18n.t("workspace.discard_failed")
  end

  test "a pending import that outlasts the wait offers Stay or Leave and clears the failure once it ends" do
    open_workspace_from_projects
    fill_in "Project name", with: "Waiting for a slow import"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    # Test-side clock: every 30-second timer (the guard's wait for pending work,
    # and its last save retry, which this test never reaches) elapses at once,
    # and autosave debounces wait until the test runs them.
    page.execute_script(<<~JS)
      const schedule = window.setTimeout
      const cancel = window.clearTimeout
      const debounces = window.__debounces = new Map()
      window.setTimeout = (callback, delay, ...rest) => {
        if (delay === 1000 && window.__holdDebounces) {
          const id = -(debounces.size + 1)
          debounces.set(id, callback)
          return id
        }
        return schedule(callback, delay === 30000 ? 20 : delay, ...rest)
      }
      window.clearTimeout = id => id < 0 ? debounces.delete(id) : cancel(id)
      window.__holdDebounces = true
      const deliver = window.fetch
      window.fetch = async (url, options = {}) => {
        if (new URL(url, location.origin).pathname === "/source_imports.json") {
          await new Promise(resolve => { window.__releaseImport = resolve })
          return new Response(JSON.stringify({ error: "Rejected import" }), { status: 422, headers: { "Content-Type": "application/json" } })
        }
        return deliver(url, options)
      }
    JS
    click_button "Upload file"
    @import_file = Tempfile.new([ "slow-import", ".txt" ])
    @import_file.write("Never imported")
    @import_file.flush
    attach_file "Source file", @import_file.path
    click_button "Upload and review"
    assert_until { page.evaluate_script("!!window.__releaseImport") }

    click_link "Projects"
    assert_selector "dialog[open]", text: "Leave this translation?"
    # Leaving the name field queued a save; none may report "saved" now.
    page.execute_script("window.__holdDebounces = false; window.__debounces.forEach(callback => callback()); window.__debounces.clear()")
    assert_status I18n.t("workspace.save_failed")
    click_button "Stay"
    assert_no_page_requests

    # The import still has not reached the draft, so a save of new typing
    # keeps reporting the failure.
    fill_in "Project name", with: "Typed while the import waits"
    assert_until { users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name") == "Typed while the import waits" }
    assert_status I18n.t("workspace.save_failed")

    page.execute_script("window.__releaseImport()")
    assert_text "Rejected import"
    assert_status I18n.t("workspace.saved")
  end

  test "a refused discard stays reported after a wait for pending work settles" do
    open_workspace_from_projects
    fill_in "Project name", with: "Refused discard, then a slow import"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    page.execute_script("window.__harness.discardMode = 'fail'")
    accept_confirm { click_button "Discard draft" }
    assert_status I18n.t("workspace.discard_failed")
    # Test-side clock: the guard's 30-second wait for pending work elapses at once.
    page.execute_script(<<~JS)
      const schedule = window.setTimeout
      window.setTimeout = (callback, delay, ...rest) => schedule(callback, delay === 30000 ? 20 : delay, ...rest)
      const deliver = window.fetch
      window.fetch = async (url, options = {}) => {
        if (new URL(url, location.origin).pathname === "/source_imports.json") {
          await new Promise(resolve => { window.__releaseImport = resolve })
          return new Response(JSON.stringify({ error: "Rejected import" }), { status: 422, headers: { "Content-Type": "application/json" } })
        }
        return deliver(url, options)
      }
    JS
    click_button "Upload file"
    @import_file = Tempfile.new([ "rejected-import", ".txt" ])
    @import_file.write("Never imported")
    @import_file.flush
    attach_file "Source file", @import_file.path
    click_button "Upload and review"
    assert_until { page.evaluate_script("!!window.__releaseImport") }
    click_link "Projects"
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Stay"

    page.execute_script("window.__releaseImport()")
    assert_text "Rejected import"
    assert_status I18n.t("workspace.discard_failed")
  end

  test "Stay cancels a Back pressed while the dialog was open" do
    open_workspace_from_projects
    workspace_path = page.evaluate_script("location.pathname")
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'fail'")
    fill_in "Project name", with: "Kept by Stay"
    assert_status I18n.t("workspace.save_failed")
    click_link "Projects"
    assert_selector "dialog[open]", text: "Leave this translation?"
    page.execute_script("window.__harness.saveMode = 'hold'; history.back()")
    assert_until { page.evaluate_script("window.__harness.heldSaves.length > 0") }

    click_button "Stay"
    assert_until { page.evaluate_script("location.pathname === arguments[0]", workspace_path) }
    page.execute_script("window.__harness.saveMode = 'ok'; window.__harness.heldSaves.splice(0).forEach(held => held.release())")
    assert_status I18n.t("workspace.saved")
    assert page.evaluate_script("!!window.__harness && location.pathname === arguments[0]", workspace_path)
    assert_no_page_requests
  end

  test "an abandoned wait for pending work leaves the newer wait's status alone" do
    open_workspace_from_projects
    fill_in "Project name", with: "Two waits for one import"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    # Test-side clock: the guard's 30-second waits run when the test says.
    page.execute_script(<<~JS)
      const schedule = window.setTimeout
      const cancel = window.clearTimeout
      const waits = window.__waits = []
      window.setTimeout = (callback, delay, ...rest) => {
        if (delay !== 30000) return schedule(callback, delay, ...rest)
        waits.push(callback)
        return -waits.length
      }
      window.clearTimeout = id => id < 0 ? (waits[-id - 1] = () => {}) : cancel(id)
    JS
    start_held_import("Imported after two waits")

    click_link "Projects"
    assert_until { page.evaluate_script("window.__waits.length === 1") }
    within("aside#app-sidebar") { select "日本語", from: "Interface language" }
    assert_until { page.evaluate_script("window.__waits.length === 2") }

    # The link's wait lapsed when the switch took over; its timeout says nothing.
    page.execute_script("window.__waits[0]()")
    assert_status I18n.t("workspace.saving")
    page.execute_script("window.__waits[1]()")
    assert_status I18n.t("workspace.save_failed")
    within("aside#app-sidebar") { assert_field "Interface language", with: "en" }

    page.execute_script("window.__releaseImport()")
    assert_imported_draft("Imported after two waits")
    assert_status I18n.t("workspace.saved")
    assert_no_page_requests
  end

  test "an appearance switch on an unsaved page is not treated as leaving" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'fail'")
    page.execute_script(<<~JS)
      window.__appearanceRequests = 0
      const deliver = window.fetch
      window.fetch = (url, options = {}) => {
        if (new URL(url, location.origin).pathname === "/appearance") window.__appearanceRequests += 1
        return deliver(url, options)
      }
    JS
    fill_in "Project name", with: "Unsaved while switching appearance"
    assert_status I18n.t("workspace.save_failed")

    find("details.appearance-menu summary").click
    within("details.appearance-menu") { click_button "Dark" }
    assert_selector "html[data-appearance='dark'], html.dark", wait: 10
    assert_no_selector "dialog[open]"
    assert_equal 1, page.evaluate_script("window.__appearanceRequests")

    # The guard still owns navigation afterwards.
    click_link "Projects"
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Stay"
    assert_field "Project name", with: "Unsaved while switching appearance"
  end

  test "unsaved text is saved before signing out and restored after signing in again" do
    open_workspace_from_projects
    install_history_harness
    record_requests
    fill_in "Project name", with: "Saved before sign out"
    click_button "Log out"
    assert_current_path login_path
    assert_equal "Saved before sign out", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
    assert_save_then_single_sign_out

    sign_in_again
    assert_field "Project name", with: "Saved before sign out"
  end

  test "signing out waits for a save in flight" do
    open_workspace_from_projects
    install_history_harness
    record_requests
    page.execute_script("window.__harness.saveMode = 'hold'")
    fill_in "Project name", with: "Held at sign out"
    assert_until { page.evaluate_script("window.__harness.heldSaves.length === 1") }
    click_button "Log out"
    assert_status I18n.t("workspace.saving")
    assert_equal 0, page.evaluate_script("window.__requests.filter(request => request === 'session').length")

    page.execute_script("window.__harness.saveMode = 'ok'; window.__harness.heldSaves.shift().release()")
    assert_current_path login_path
    assert_equal "Held at sign out", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
    assert_save_then_single_sign_out
  end

  test "a sign-out answered with an error page keeps the latest edit" do
    open_workspace_from_projects
    install_history_harness
    record_requests(session_status: 500)
    fill_in "Project name", with: "Kept despite failed sign out"
    click_button "Log out"
    assert_until { page.evaluate_script("window.__requests.includes('session')") }
    assert_until { users(:normal).translation_workspace_drafts.first&.payload&.fetch("project_name", nil) == "Kept despite failed sign out" }
    assert_save_then_single_sign_out
  end

  test "a save that fails keeps sign-out waiting for the user's choice" do
    open_workspace_from_projects
    install_history_harness
    record_requests
    page.execute_script("window.__harness.saveMode = 'fail'")
    fill_in "Project name", with: "Not saved yet"
    assert_status I18n.t("workspace.save_failed")

    click_button "Log out"
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Stay"
    assert_field "Project name", with: "Not saved yet"
    assert_equal 0, page.evaluate_script("window.__requests.filter(request => request === 'session').length")

    click_button "Log out"
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Leave"
    assert_current_path login_path
  end

  test "no save is retried after Leave has started signing out" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'fail'")
    # Test-side clock: save retries wait until the test runs them.
    page.execute_script(<<~JS)
      const schedule = window.setTimeout
      window.__retries = []
      window.setTimeout = (callback, delay, ...rest) => {
        // A negative id never matches a real timer the guard might clear.
        if ([2000, 5000, 15000, 30000].includes(delay)) return -window.__retries.push(callback)
        return schedule(callback, delay, ...rest)
      }
      window.__requests = []
      const deliver = window.fetch
      window.fetch = async (url, options = {}) => {
        const path = new URL(url, location.origin).pathname
        if (path === "/translation_workspace_draft") window.__requests.push("draft")
        if (path !== "/session") return deliver(url, options)
        window.__requests.push("session")
        const response = await deliver(url, options)
        await new Promise(resolve => { window.__releaseSession = resolve })
        return response
      }
    JS
    fill_in "Project name", with: "Abandoned at sign out"
    assert_status I18n.t("workspace.save_failed")
    click_button "Log out"
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Leave"
    assert_until { page.evaluate_script("!!window.__releaseSession") }

    # Every retry still scheduled now runs while the ended session's response is held.
    assert_operator page.evaluate_script("window.__retries.length"), :>, 0
    # A retry that saves records its request synchronously, as the fetch starts.
    page.execute_script("window.__retries.splice(0).forEach(retry => retry())")
    requests = page.evaluate_script("window.__requests")
    assert_equal "session", requests.last
    page.execute_script("window.__releaseSession()")
    assert_current_path login_path
  end

  test "a sign-out that fails after Leave keeps guarding and saving the page" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'fail'")
    page.execute_script(<<~JS)
      const deliver = window.fetch
      window.fetch = (url, options = {}) => {
        if (new URL(url, location.origin).pathname === "/session") return Promise.reject(new TypeError("Failed to fetch"))
        return deliver(url, options)
      }
      document.addEventListener("turbo:submit-end", () => { window.__signOutEnded = true })
    JS
    fill_in "Project name", with: "Kept after a failed sign-out"
    assert_status I18n.t("workspace.save_failed")
    click_button "Log out"
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Leave"
    assert_until { page.evaluate_script("window.__signOutEnded === true") }

    # Still here: the edit is saved again once saving works, and leaving is guarded.
    page.execute_script("window.__harness.saveMode = 'ok'")
    fill_in "Project name", with: "Saved after the failed sign-out"
    assert_status I18n.t("workspace.saved")
    assert_equal "Saved after the failed sign-out", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
    page.execute_script("window.__harness.saveMode = 'fail'")
    fill_in "Project name", with: "Guarded again"
    assert_status I18n.t("workspace.save_failed")
    click_link "Projects"
    assert_selector "dialog[open]", text: "Leave this translation?"
  end

  test "Leave after a Back was claimed signs out instead of following that Back" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'fail'")
    page.execute_script(<<~JS)
      const deliver = window.fetch
      window.fetch = async (url, options = {}) => {
        if (new URL(url, location.origin).pathname === "/session") await new Promise(resolve => { window.__releaseSignOut = resolve })
        return deliver(url, options)
      }
    JS
    fill_in "Project name", with: "Abandoned for sign-out"
    assert_status I18n.t("workspace.save_failed")
    click_button "Log out"
    assert_selector "dialog[open]", text: "Leave this translation?"

    page.execute_script("window.__harness.saveMode = 'hold'")
    page.execute_script("history.back()")
    assert_until { page.evaluate_script("window.__harness.heldSaves.length === 1") }
    click_button "Leave"
    assert_until { page.evaluate_script("!!window.__releaseSignOut") }
    page.execute_script("window.__sameDocument = true; window.__harness.saveMode = 'ok'; window.__harness.heldSaves.shift().release()")
    # The claimed Back's save is acknowledged on the page; it must not reload the page to that Back.
    assert_status I18n.t("workspace.saved")
    page.execute_script("window.__releaseSignOut()")
    assert_current_path login_path
    assert page.evaluate_script("window.__sameDocument === true"), "the sign-out was replaced by a reload"
  end

  test "signing out while the saved page reloads to a claimed Back replaces that reload" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'hold'")
    fill_in "Project name", with: "Saved before the reload"
    page.execute_script("history.back()")
    assert_until { page.evaluate_script("window.__harness.heldSaves.length === 1") }

    # The guard freezes the page and starts the reload in the same task; Log out
    # is clicked right after, while that reload is still pending. (WebDriver
    # itself waits for a pending navigation, so the click comes from the page.)
    page.execute_script(<<~JS)
      const guard = document.querySelector("[data-controller='workspace-guard']")
      const observer = new MutationObserver(() => {
        if (!guard.inert) return
        observer.disconnect()
        document.querySelector("form[action='/session'] [type='submit']").click()
      })
      observer.observe(guard, { attributes: true, attributeFilter: ["inert"] })
    JS
    page.execute_script("window.__harness.saveMode = 'ok'; window.__harness.heldSaves.shift().release()")

    assert_current_path login_path
    assert_equal "Saved before the reload", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
  end

  test "Leave for a form no longer on the page keeps guarding and saving" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'fail'")
    fill_in "Project name", with: "Kept when the form is gone"
    assert_status I18n.t("workspace.save_failed")
    click_button "Log out"
    assert_selector "dialog[open]", text: "Leave this translation?"
    page.execute_script("document.querySelector(\"form[action='/session']\").remove()")
    click_button "Leave"

    assert_no_selector "dialog[open]"
    assert_current_path new_translation_workspace_path
    page.execute_script("window.__harness.saveMode = 'ok'")
    fill_in "Project name", with: "Saved after the lapsed Leave"
    assert_status I18n.t("workspace.saved")
    assert_equal "Saved after the lapsed Leave", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
    page.execute_script("window.__harness.saveMode = 'fail'")
    fill_in "Project name", with: "Guarded after the lapsed Leave"
    assert_status I18n.t("workspace.save_failed")
    click_link "Projects"
    assert_selector "dialog[open]", text: "Leave this translation?"
  end

  test "signing out while a language switch waits for its save wins over the switch" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'hold'")
    fill_in "Project name", with: "Saved before signing out"
    within("aside#app-sidebar") { select "日本語", from: "Interface language" }
    assert_until { page.evaluate_script("window.__harness.heldSaves.length === 1") }
    click_button "Log out"

    page.execute_script("window.__harness.saveMode = 'ok'; window.__harness.heldSaves.shift().release()")
    assert_current_path login_path
    assert_selector "html[lang='en']"
    assert_equal "en", users(:normal).reload.locale
    assert_equal "Saved before signing out", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
  end

  test "a newer language choice made after a link took the earlier switch's claim is honored" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'hold'")
    fill_in "Project name", with: "Saved before the second choice"
    within("aside#app-sidebar") { select "日本語", from: "Interface language" }
    assert_until { page.evaluate_script("window.__harness.heldSaves.length === 1") }
    click_link "Projects"
    within("aside#app-sidebar") { select "Tiếng Việt", from: "Interface language" }

    page.execute_script("window.__harness.saveMode = 'ok'; window.__harness.heldSaves.shift().release()")
    assert_selector "html[lang='vi']"
    assert_equal "vi", users(:normal).reload.locale
    assert_equal "Saved before the second choice", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
  end

  test "choosing the current language again while a switch waits cancels the switch" do
    open_workspace_from_projects
    install_history_harness
    page.execute_script(<<~JS)
      window.__harness.saveMode = "hold"
      window.__localeSubmits = 0
      document.addEventListener("submit", event => {
        if (new URL(event.target.action).pathname === "/locale") window.__localeSubmits += 1
      }, true)
    JS
    fill_in "Project name", with: "Saved without a switch"
    within("aside#app-sidebar") { select "日本語", from: "Interface language" }
    assert_until { page.evaluate_script("window.__harness.heldSaves.length === 1") }
    within("aside#app-sidebar") { select "English", from: "Interface language" }

    page.execute_script("window.__harness.saveMode = 'ok'; window.__harness.heldSaves.shift().release()")
    assert_status I18n.t("workspace.saved")
    assert_equal 0, page.evaluate_script("window.__localeSubmits")
    assert_equal "en", users(:normal).reload.locale
    assert_equal "Saved without a switch", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
  end

  test "a language switch during a launch is refused so the launch's outcome is shown" do
    open_workspace_from_projects
    fill_in "Project name", with: "Launch kept over a switch"
    choose_known_language("Source language", "Vietnamese")
    choose_known_language("Target language", "Japanese")
    fill_in "Document title", with: "Switched launch document"
    fill_in "Source text", with: "Switched launch source"
    fill_in "Instructions for the translation", with: "Translate carefully."
    assert_status I18n.t("workspace.saved")
    install_history_harness
    page.execute_script(<<~JS)
      const deliver = window.fetch
      window.fetch = async (url, options = {}) => {
        if (new URL(url, location.origin).pathname === "/translation_workspace" && (options.method || "").toUpperCase() === "POST") {
          window.__launchHeld = true
          return new Promise((_resolve, reject) => {
            options.signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true })
          })
        }
        return deliver(url, options)
      }
    JS
    click_button "Start translation"
    assert_until { page.evaluate_script("window.__launchHeld === true") }
    within("aside#app-sidebar") { select "日本語", from: "Interface language" }

    within("aside#app-sidebar") { assert_field "Interface language", with: "en" }
    assert page.evaluate_script("window.__launchHeld === true && document.querySelector(\"[data-controller='workspace-guard']\").inert")
    assert_equal "en", users(:normal).reload.locale
  end

  test "signing out from a saved workspace or another page stays immediate" do
    open_workspace_from_projects
    fill_in "Project name", with: "Saved earlier"
    assert_status I18n.t("workspace.saved")
    install_history_harness
    record_requests
    click_button "Log out"
    assert_current_path login_path
    assert_equal [ "session" ], page.evaluate_script("window.__requests")

    sign_in_again
    visit projects_path
    click_button "Log out"
    assert_current_path login_path
  end

  private

  # Fails a save, then chooses Leave for a download link. A download keeps
  # this document in place, as a stopped or still-pending browser load would.
  def leave_to_a_download
    project = users(:normal).projects.create!(name: "Download project", source_language: "Vietnamese", target_language: "Japanese")
    document = project.documents.create!(title: "Downloadable", source_text: "Original text", source_format: "txt", original_filename: "original.txt")
    document.source_file.attach(io: StringIO.new("Original text"), filename: "original.txt", content_type: "text/plain")
    open_workspace_from_projects
    install_history_harness
    page.execute_script("window.__harness.saveMode = 'fail'")
    fill_in "Project name", with: "Abandoned by Leave"
    assert_status I18n.t("workspace.save_failed")
    page.execute_script(<<~JS, download_original_document_path(document))
      const link = document.createElement("a")
      link.href = arguments[0]
      link.textContent = "Download the original"
      document.querySelector("main").append(link)
    JS
    click_link "Download the original"
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Leave"
    assert_until { page.evaluate_script("document.querySelector(\"[data-controller='workspace-guard']\").inert") }
    assert page.evaluate_script("!!window.__harness")
  end

  # Records draft saves and the sign-out request in the order they are sent;
  # session_status: answers the sign-out with that status instead.
  def record_requests(session_status: nil)
    page.execute_script(<<~JS, session_status)
      const sessionStatus = arguments[0]
      window.__requests = []
      const deliver = window.fetch
      window.fetch = (url, options = {}) => {
        const path = new URL(url, location.origin).pathname
        if (path === "/translation_workspace_draft") window.__requests.push("draft")
        if (path === "/session") {
          window.__requests.push("session")
          if (sessionStatus) return Promise.resolve(new Response("<html><body><h1>Server error</h1></body></html>", { status: sessionStatus, headers: { "Content-Type": "text/html" } }))
        }
        return deliver(url, options)
      }
    JS
  end

  # The draft is saved first, then the session ends exactly once and nothing
  # tries to save afterwards.
  def assert_save_then_single_sign_out
    requests = page.evaluate_script("window.__requests")
    assert_equal 1, requests.count("session")
    assert_equal "session", requests.last
    assert_includes requests, "draft"
  end

  def sign_in_again
    visit login_path
    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  # Uploads a source file whose import response is held until
  # window.__releaseImport() is called.
  def start_held_import(text)
    page.execute_script(<<~JS)
      const deliver = window.fetch
      window.fetch = async (url, options = {}) => {
        const response = await deliver(url, options)
        if (new URL(url, location.origin).pathname === "/source_imports.json") {
          await new Promise(resolve => { window.__releaseImport = resolve })
        }
        return response
      }
    JS
    click_button "Upload file"
    @import_file = Tempfile.new([ "held-import", ".txt" ])
    @import_file.write(text)
    @import_file.flush
    attach_file "Source file", @import_file.path
    click_button "Upload and review"
    assert_until { page.evaluate_script("!!window.__releaseImport") }
  end

  def assert_imported_draft(text)
    source_import = users(:normal).source_imports.sole
    assert_until { users(:normal).translation_workspace_drafts.sole.payload.values_at("source_import_id", "source_text") == [ source_import.id.to_s, text ] }
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
      // Hover prefetches would be held too and then reused by a later visit;
      // only the visits a test drives are held. <html> survives Turbo visits.
      document.documentElement.dataset.turboPrefetch = "false"
      const deliver = window.fetch.bind(window)
      const harness = window.__harness = { saveMode: "ok", discardMode: "ok", heldSaves: [], heldDiscards: [], holdPages: new Set(), heldPages: [], pageRequests: [], events: {} }
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
          if (method === "POST" && harness.saveMode === "conflict") return new Response("", { status: 409 })
          if (method === "POST" && harness.saveMode === "hold") {
            const held = {}
            await hold(harness.heldSaves, held)
            if (held.fail) return new Response("", { status: 503 })
          }
          if (method === "DELETE" && harness.discardMode === "fail") return new Response("", { status: 503 })
          if (method === "DELETE" && harness.discardMode === "hold") {
            await hold(harness.heldDiscards, {})
            return new Response("", { status: 503 })
          }
          return deliver(url, options)
        }
        // A hover prefetch is not a navigation; the visit still decides.
        if (method === "GET" && options.headers?.["X-Sec-Purpose"] !== "prefetch") harness.pageRequests.push(target.pathname)
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
    # Returning to the workspace's own entry is a traversal, which settles asynchronously.
    assert_until { page.evaluate_script("location.href === arguments[0] && history.state?.turbo?.restorationIdentifier === arguments[1]?.turbo?.restorationIdentifier", before["href"], before["historyState"]) }
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
  # The refused traversal left every history entry as it was, so Back from
  # the workspace still reaches the Projects entry it came from. (A browser
  # reused across tests caps history.length, so entries are not counted.)
  def assert_back_from_projects_restores(project_name)
    page.execute_script("window.__harness.holdPages.clear(); window.__sameDocument = true")
    click_link "Projects"
    assert_selector "h1", text: "Projects"
    page.go_back
    assert_selector "h1", text: "New translation"
    assert_field "Project name", with: project_name
    assert page.evaluate_script("window.__sameDocument === true")
    draft = users(:normal).translation_workspace_drafts.sole
    assert_equal project_name, draft.payload.fetch("project_name")
    restored = navigation_state
    assert_equal [ draft.public_id, draft.lock_version, false ], restored.values_at("draftId", "version", "dirty")
    page.go_back
    assert_selector "h1", text: "Projects"
    assert_current_path projects_path
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
