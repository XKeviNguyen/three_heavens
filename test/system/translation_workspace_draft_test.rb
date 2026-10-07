require "application_system_test_case"
require "tempfile"

class TranslationWorkspaceDraftTest < ApplicationSystemTestCase
  setup do
    sign_in_in_browser
  end

  test "reconnecting the same page preserves autosave ordering" do
    visit new_translation_workspace_path
    fill_in "Source text", with: "Before reconnect"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    page.execute_script(<<~JS)
      const element = document.querySelector("[data-controller='workspace-guard']")
      const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "workspace-guard")
      controller.disconnect()
      controller.connect()
    JS
    fill_in "Source text", with: "After reconnect"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    assert_equal "After reconnect", users(:normal).translation_workspace_drafts.sole.payload.fetch("source_text")
  end

  test "retrying a committed discard after response loss reaches a fresh workspace" do
    visit new_translation_workspace_path
    fill_in "Source text", with: "Discard once"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    original_editor = page.evaluate_script("document.querySelector('[data-controller=workspace-guard]').dataset.workspaceGuardEditorIdValue")
    page.execute_script(<<~JS)
      const deliver = window.fetch.bind(window)
      window.fetch = async (url, options = {}) => {
        const response = await deliver(url, options)
        if (!window.__discardDropped && new URL(url, location.origin).pathname === "/translation_workspace_draft" && options.method === "DELETE") {
          window.__discardDropped = true
          await response.arrayBuffer()
          throw new TypeError("synthetic response loss")
        }
        return response
      }
    JS
    accept_confirm { click_button "Discard draft" }
    assert_selector "[data-workspace-guard-target='status']", text: I18n.t("workspace.discard_failed"), wait: 10
    assert_empty users(:normal).translation_workspace_drafts.reload
    page.execute_script("document.body.dataset.discardDocument = 'old'")
    accept_confirm { click_button "Discard draft" }
    assert_document_replaced "body[data-discard-document='old']"
    assert_field "Source text", with: ""
    assert_until do
      page.evaluate_script(<<~JS, original_editor)
        (() => {
          const element = document.querySelector("[data-controller='workspace-guard']")
          const controller = element && window.Stimulus.getControllerForElementAndIdentifier(element, "workspace-guard")
          return !!controller?.editorId && controller.editorId !== arguments[0]
        })()
      JS
    end
    fill_in "Source text", with: "Fresh page after retry"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    assert_equal "Fresh page after retry", users(:normal).translation_workspace_drafts.reload.sole.payload.fetch("source_text")
  end

  test "language search requires selection and Escape restores the committed value" do
    visit new_translation_workspace_path
    choose_language("Source language", "Vietnamese")
    source = find_field("Source language")
    assert_equal "Vietnamese", find("input[name='translation_workspace[source_language]']", visible: :all).value

    source.fill_in with: "French"
    assert_equal "Vietnamese", find("input[name='translation_workspace[source_language]']", visible: :all).value
    source.send_keys(:escape)
    assert_field "Source language", with: "Vietnamese"
    assert_equal "Vietnamese", find("input[name='translation_workspace[source_language]']", visible: :all).value

    source.fill_in with: "Japanese"
    source.send_keys(:arrow_down, :enter)
    assert_equal "Japanese", find("input[name='translation_workspace[source_language]']", visible: :all).value
  end

  test "switching English to Japanese to Vietnamese preserves the workspace draft" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Locale draft"
    fill_in "Source text", with: "Private source across locales"

    within "aside#app-sidebar" do
      select "日本語", from: "Interface language"
    end
    assert_selector "html[lang='ja']"
    assert_field "プロジェクト名", with: "Locale draft"
    assert_equal "Private source across locales", find("textarea[name='translation_workspace[source_text]']", visible: :all).value
    assert_selector "[data-workspace-guard-target='status']", text: "下書きを復元しました", wait: 10

    within "aside#app-sidebar" do
      select "Tiếng Việt", from: "表示言語"
    end
    assert_selector "html[lang='vi']"
    assert_field "Tên dự án", with: "Locale draft"
    assert_equal "Private source across locales", find("textarea[name='translation_workspace[source_text]']", visible: :all).value
  end

  test "autosaves source and configuration then restores after navigation and refresh" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Autosaved project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    fill_in "Document title", with: "Autosaved title"
    fill_in "Source text", with: "Private autosaved source"
    fill_in "Instructions for the translation", with: "Preserve nuance."
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    assert_not_includes page.current_url, "Private autosaved source"
    assert_equal false, page.evaluate_script("Object.values(localStorage).join('').includes('Private autosaved source') || Object.values(sessionStorage).join('').includes('Private autosaved source') || JSON.stringify(history.state).includes('Private autosaved source')")

    click_link "Projects"
    assert_current_path projects_path
    assert_no_selector "dialog[open]", text: "Leave this translation?"

    click_link "New translation"
    assert_field "Project name", with: "Autosaved project"
    assert_field "Source text", with: "Private autosaved source"
    assert_field "Instructions for the translation", with: "Preserve nuance."
    refresh
    assert_field "Document title", with: "Autosaved title"
    assert_field "Source text", with: "Private autosaved source"
  end


  test "failed draft save keeps the leave protection and Stay preserves fields" do
    visit new_translation_workspace_path
    page.execute_script(<<~JS)
      window.__originalDraftFetch = window.fetch.bind(window)
      window.fetch = (url, options) => {
        if (new URL(url, location.origin).pathname === "/translation_workspace_draft") {
          return Promise.resolve(new Response("", { status: 503 }))
        }
        return window.__originalDraftFetch(url, options)
      }
    JS
    fill_in "Project name", with: "Unsaved local project"
    fill_in "Source text", with: "Unsaved local source"
    assert_selector "[data-workspace-guard-target='status']", text: "Could not save", wait: 10

    click_link "Projects"
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Stay"
    assert_current_path new_translation_workspace_path
    assert_field "Project name", with: "Unsaved local project"
    assert_field "Source text", with: "Unsaved local source"

    click_link "Projects"
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Leave without saving"
    assert_current_path projects_path
    click_link "New translation"
    assert_field "Project name", with: ""
    assert_field "Source text", with: ""
  end

  test "explicit discard clears a saved draft after confirmation" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Discard me"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10

    page.execute_script("document.body.dataset.discardDocument = 'old'")
    accept_confirm do
      click_button "Discard draft"
    end
    assert_document_replaced "body[data-discard-document='old']"
    assert_current_path new_translation_workspace_path
    assert_field "Project name", with: ""
    assert_equal 0, users(:normal).translation_workspace_drafts.count
  end

  test "validation failure retains the draft through refresh" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Retry project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    fill_in "Document title", with: "Retry document"
    fill_in "Source text", with: "Private retry source"
    fill_in "Instructions for the translation", with: "Translate carefully."
    click_button "Start translation"
    assert_selector "#form-errors-heading"
    assert_equal 1, users(:normal).translation_workspace_drafts.count

    refresh
    assert_field "Source text", with: "Private retry source"
  end


  test "successful Start translation consumes the saved draft" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Launch project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    fill_in "Document title", with: "Launch document"
    fill_in "Source text", with: "Private launch source"
    fill_in "Instructions for the translation", with: "Translate carefully."
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add"
      first("button", text: "Add").click
    end
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    assert_equal 1, users(:normal).translation_workspace_drafts.count

    click_button "Start translation"
    assert_current_path(/\A\/experiments\/\d+\z/)
    assert_equal 0, users(:normal).translation_workspace_drafts.count
    assert_equal 0, AiProviderAttempt.count
  end

  # Commit success + response unknown to the client: the wrapped fetch lets
  # the real request reach the server and waits for its complete response,
  # so the draft transaction has committed, then discards it and rejects
  # exactly like a connection dropped after the server finished.
  test "an autosave committed without a delivered response never loses the next edit" do
    visit new_translation_workspace_path
    drop_next_draft_save_responses(1)
    fill_in "Project name", with: "Ambiguous project"
    fill_in "Source text", with: "Edit A committed without a response"
    assert_selector "[data-workspace-guard-target='status']", text: "Could not save", wait: 10
    assert_equal "Edit A committed without a response", users(:normal).translation_workspace_drafts.sole.payload.fetch("source_text")

    fill_in "Source text", with: "Edit B written after the lost response"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    assert_equal 0, page.evaluate_script("window.__pendingDraftDrops")

    refresh
    assert_field "Source text", with: "Edit B written after the lost response"
    assert_equal 1, users(:normal).translation_workspace_drafts.count
  end

  # Serializing the whole form on every keystroke made typing in a near-limit
  # source lag. Serialization must scale with saves, not with keystrokes.
  test "typing in a large source serializes the form once per save, not per keystroke" do
    visit new_translation_workspace_path
    page.execute_script(<<~JS)
      const unit = "聖書の翻訳 Kinh Thánh dịch thuật 🙏🏽 mixed script. "
      let text = ""
      while (text.length < 90000) text += unit
      const area = document.querySelector("textarea[name='translation_workspace[source_text]']")
      area.value = text.slice(0, 90000)
      area.dispatchEvent(new Event("input", { bubbles: true }))
    JS
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 20
    page.execute_script(<<~JS)
      window.__serializations = 0
      window.__draftSaves = 0
      const OriginalFormData = window.FormData
      window.FormData = function(...args) { window.__serializations += 1; return new OriginalFormData(...args) }
      window.FormData.prototype = OriginalFormData.prototype
      const deliver = window.fetch.bind(window)
      window.fetch = (url, options = {}) => {
        if (new URL(url, location.origin).pathname === "/translation_workspace_draft" && options.method === "POST") window.__draftSaves += 1
        return deliver(url, options)
      }
      const area = document.querySelector("textarea[name='translation_workspace[source_text]']")
      area.focus()
      area.setSelectionRange(area.value.length, area.value.length)
    JS

    find("textarea[name='translation_workspace[source_text]']").send_keys("typed" * 4)
    assert_equal 0, page.evaluate_script("window.__serializations"), "typing must not serialize the form"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 20
    assert_equal [ 1, 1 ], page.evaluate_script("[window.__serializations, window.__draftSaves]")
    assert users(:normal).translation_workspace_drafts.sole.payload.fetch("source_text").end_with?("typed" * 4)
  end

  test "importing a source file and removing the import are autosaved" do
    visit new_translation_workspace_path
    click_button "Upload file"
    source = Tempfile.new([ "autosaved-import", ".txt" ])
    source.write("Imported and autosaved")
    source.flush
    attach_file "Source file", source.path
    click_button "Upload and review"
    assert_field "Reviewed source text", with: "Imported and autosaved"
    source_import = users(:normal).source_imports.sole
    draft_value = -> { users(:normal).translation_workspace_drafts.first&.payload&.fetch("source_import_id", nil) }
    assert_until { draft_value.call == source_import.id.to_s }

    click_button "Remove import"
    assert_no_selector "#workspace-source-import", visible: true
    assert_until { draft_value.call == "" }
  ensure
    source&.close!
  end

  test "reverting to acknowledged text after a lost response saves the reverted text" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Acknowledged A"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10

    drop_next_draft_save_responses(1)
    fill_in "Project name", with: "Committed B"
    assert_selector "[data-workspace-guard-target='status']", text: "Could not save", wait: 10
    assert_equal "Committed B", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")

    fill_in "Project name", with: "Acknowledged A"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    assert_equal "Acknowledged A", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
    refresh
    assert_field "Project name", with: "Acknowledged A"
  end

  test "discarding while a save is unresolved never recreates the draft" do
    visit new_translation_workspace_path
    page.execute_script(<<~JS)
      const deliver = window.fetch.bind(window)
      window.__releasePendingDiscardSave = null
      window.fetch = async (url, options = {}) => {
        const draft = new URL(url, location.origin).pathname === "/translation_workspace_draft"
        if (draft && options.method === "POST" && !window.__firstSaveSent) {
          window.__firstSaveSent = true
          const response = await deliver(url, options)
          await new Promise(resolve => { window.__releasePendingDiscardSave = resolve })
          await response.arrayBuffer()
          throw new TypeError("Failed to fetch")
        }
        const response = await deliver(url, options)
        return response
      }
    JS
    fill_in "Project name", with: "Discard while unresolved"
    assert_until { page.evaluate_script("window.__releasePendingDiscardSave !== null") }
    accept_confirm { click_button "Discard draft" }
    page.execute_script("window.__releasePendingDiscardSave()")

    # The reset page is the same URL; wait until the old page has been replaced.
    assert_until(timeout: 15) { page.evaluate_script("window.__firstSaveSent !== true && document.readyState === 'complete'") }
    assert_field "Project name", with: ""
    assert_equal 0, users(:normal).translation_workspace_drafts.count
  end

  test "Back then Forward renders the current draft instead of a stale snapshot" do
    visit projects_path
    click_link "New translation"
    fill_in "Project name", with: "Typed then Back"
    page.go_back
    assert_current_path projects_path
    page.go_forward
    assert_field "Project name", with: "Typed then Back"

    fill_in "Project name", with: "Edited after Forward"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    assert_equal "Edited after Forward", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
  end

  [ false, true ].each do |lose_response|
    test "Forward during an unacknowledged Back save preserves lineage with response loss #{lose_response}" do
      visit projects_path
      click_link "New translation"
      assert_field "Project name"
      page.execute_script(<<~JS)
        document.body.dataset.historyDocument = "old"
        const deliver = window.fetch.bind(window)
        window.__releaseDraftResponse = null
        window.fetch = async (url, options = {}) => {
          if (new URL(url, location.origin).pathname === "/translation_workspace_draft" && options.method === "POST" && !window.__heldDraftResponse) {
            window.__heldDraftResponse = true
            await new Promise(resolve => { window.__releaseDraftResponse = resolve })
          }
          const response = await deliver(url, options)
          if (#{lose_response} && new URL(url, location.origin).pathname === "/translation_workspace_draft" && options.method === "POST" && !window.__lostHistorySave) {
            window.__lostHistorySave = true
            await response.arrayBuffer()
            throw new TypeError("Failed to fetch")
          }
          return response
        }
        window.addEventListener("history:traverse", () => { window.__historyPops = (window.__historyPops || 0) + 1 })
        document.addEventListener("turbo:before-render", () => { window.__historyRenders = (window.__historyRenders || 0) + 1 })
      JS
      fill_in "Project name", with: "Back save still unresolved"
      page.execute_script("history.back()")
      assert_until { page.evaluate_script("window.__releaseDraftResponse !== null && location.pathname === '/projects'") }
      page.execute_script("history.forward()")
      assert_until { page.evaluate_script("window.__historyPops >= 2 && location.pathname === '/translation_workspace/new'") }
      # Both traversals were claimed before Turbo saw them: nothing rendered.
      assert_nil page.evaluate_script("window.__historyRenders")
      page.execute_script("window.__releaseDraftResponse()")
      if lose_response
        assert_selector "dialog[open]", text: "Leave this translation?"
        click_button "Stay"
        page.execute_script("window.dispatchEvent(new Event('online'))")
        assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
      else
        assert_document_replaced "body[data-history-document='old']"
      end
      assert_current_path new_translation_workspace_path
      assert_field "Project name", with: "Back save still unresolved"
      fill_in "Project name", with: "Latest edit after raced Forward"
      assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
      refresh
      assert_field "Project name", with: "Latest edit after raced Forward"
      assert_equal 1, users(:normal).translation_workspace_drafts.count
      choose_language("Source language", "Vietnamese")
      choose_language("Target language", "Japanese")
      fill_in "Document title", with: "Recovered launch"
      fill_in "Source text", with: "Latest visible recovered source"
      fill_in "Instructions for the translation", with: "Translate carefully."
      within "#workspace-manual-models" do
        find("input[placeholder='Search OpenRouter models…']").click
        first("button", text: "Add").click
      end
      click_button "Start translation"
      assert_current_path(/\A\/experiments\/\d+\z/)
      assert_equal 0, users(:normal).translation_workspace_drafts.count
    end
  end

  test "failed discard during a claimed Back save keeps the page usable for the next visit" do
    visit projects_path
    click_link "New translation"
    assert_field "Project name"
    page.execute_script(<<~JS)
      const deliver = window.fetch.bind(window)
      window.__releaseNavigationSave = null
      window.fetch = async (url, options = {}) => {
        const draft = new URL(url, location.origin).pathname === "/translation_workspace_draft"
        if (draft && options.method === "DELETE") return new Response("", { status: 503 })
        if (draft && options.method === "POST" && !window.__heldNavigationSave) {
          window.__heldNavigationSave = true
          await new Promise(resolve => { window.__releaseNavigationSave = resolve })
        }
        return deliver(url, options)
      }
    JS
    fill_in "Project name", with: "Keep after failed discard"
    page.execute_script("history.back()")
    assert_until { page.evaluate_script("window.__releaseNavigationSave !== null && location.pathname === '/projects'") }
    accept_confirm { click_button "Discard draft" }
    page.execute_script("window.__releaseNavigationSave()")
    assert_selector "[data-workspace-guard-target='status']", text: I18n.t("workspace.discard_failed"), wait: 10
    assert_current_path new_translation_workspace_path
    fill_in "Project name", with: "Latest after failed discard"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    click_link "Projects"
    assert_selector "h1", text: "Projects"
    click_link "New translation"
    assert_field "Project name", with: "Latest after failed discard"
  end

  test "failed history save then Stay can recover and render the next ordinary visit" do
    visit projects_path
    click_link "New translation"
    assert_field "Project name"
    page.execute_script(<<~JS)
      const deliver = window.fetch.bind(window)
      window.__rejectHistorySave = true
      window.fetch = (url, options = {}) => {
        if (window.__rejectHistorySave && new URL(url, location.origin).pathname === "/translation_workspace_draft" && options.method === "POST") return Promise.resolve(new Response("", { status: 503 }))
        return deliver(url, options)
      }
    JS
    fill_in "Project name", with: "History save failed"
    assert_selector "[data-workspace-guard-target='status']", text: /Saving|Could not save/, wait: 10
    page.execute_script("history.back()")
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Stay"
    page.execute_script("window.__rejectHistorySave = false; window.dispatchEvent(new Event('online'))")
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    click_link "Projects"
    assert_selector "h1", text: "Projects"
    click_link "New translation"
    assert_field "Project name", with: "History save failed"
  end

  test "locale submission takes ownership from a claimed pending Back" do
    visit projects_path
    click_link "New translation"
    assert_field "Project name"
    page.execute_script(<<~JS)
      window.Turbo.cache.clear()
      const deliver = window.fetch.bind(window)
      window.fetch = async (url, options = {}) => {
        const path = new URL(url, location.origin).pathname
        if (path === "/translation_workspace_draft" && options.method === "POST" && !window.__heldLocaleSave) {
          window.__heldLocaleSave = true
          await new Promise(resolve => { window.__releaseLocaleSave = resolve })
        }
        return deliver(url, options)
      }
    JS
    fill_in "Project name", with: "Keep across cancelled Back and locale"
    page.execute_script("history.back()")
    assert_until { page.evaluate_script("!!window.__releaseLocaleSave && location.pathname === '/projects'") }
    within("aside#app-sidebar") { select "日本語", from: "Interface language" }
    page.execute_script("window.__releaseLocaleSave()")
    assert_selector "html[lang='ja']"
    assert_selector "h1", text: "新しい翻訳"
    assert_field "プロジェクト名", with: "Keep across cancelled Back and locale"
  end

  test "a retry after a lost response resolves the save without another edit" do
    visit new_translation_workspace_path
    drop_next_draft_save_responses(1)
    fill_in "Project name", with: "Retried project"
    assert_selector "[data-workspace-guard-target='status']", text: "Could not save", wait: 10
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    draft = users(:normal).translation_workspace_drafts.sole
    assert_equal draft.public_id, find("#translation_workspace_draft_id", visible: :all).value
    assert_equal draft.lock_version.to_s, find("#translation_workspace_draft_version", visible: :all).value
    assert_equal 0, draft.lock_version

    page.execute_script("document.body.dataset.discardDocument = 'old'")
    accept_confirm { click_button "Discard draft" }
    assert_document_replaced "body[data-discard-document='old']"
    # The reset page is the same URL; wait until it has replaced this one.
    assert_current_path new_translation_workspace_path
    assert_field "Project name", with: ""
    assert_equal 0, users(:normal).translation_workspace_drafts.count
  end

  test "a second tab reports a conflict instead of overwriting the newer draft" do
    visit new_translation_workspace_path
    second_tab = open_new_window
    within_window(second_tab) { visit new_translation_workspace_path }

    fill_in "Project name", with: "First tab project"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    within_window(second_tab) do
      fill_in "Project name", with: "Stale second tab"
      assert_selector "[data-workspace-guard-target='status']", text: "newer draft in another tab", wait: 10
    end

    fill_in "Project name", with: "First tab keeps saving"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10
    assert_equal "First tab keeps saving", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
    second_tab.close

    reopened_tab = open_new_window
    within_window(reopened_tab) do
      visit new_translation_workspace_path
      assert_field "Project name", with: "First tab keeps saving"
    end
    reopened_tab.close
  end

  test "edits made while offline are saved after reconnecting" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Online project"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10

    set_browser_offline(true)
    fill_in "Project name", with: "Edited while offline"
    assert_selector "[data-workspace-guard-target='status']", text: "Could not save", wait: 10
    set_browser_offline(false)

    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 20
    assert_equal "Edited while offline", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
    refresh
    assert_field "Project name", with: "Edited while offline"
  ensure
    set_browser_offline(false)
  end

  test "rendering and preference navigation write no launch rows and a double launch starts once" do
    baseline = TranslationWorkspaceSubmission.count
    visit new_translation_workspace_path
    2.times { refresh }
    # Turbo visits return before the next page renders, and the sidebar is on
    # both pages, so wait for each destination before using the sidebar.
    click_link "Projects"
    assert_selector "h1", text: "Projects"
    click_link "New translation"
    assert_field "Project name"
    within("aside#app-sidebar") { select "日本語", from: "Interface language" }
    assert_selector "html[lang='ja']"
    within("aside#app-sidebar") { select "English", from: "表示言語" }
    assert_selector "html[lang='en']"
    page.execute_script("document.querySelector(\".appearance-option[data-appearance='dark']\").form.requestSubmit()")
    assert_selector "html[data-appearance='dark']"
    assert_equal baseline, TranslationWorkspaceSubmission.count

    fill_in "Project name", with: "Double launch project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    fill_in "Document title", with: "Double launch document"
    fill_in "Source text", with: "Private double launch source"
    fill_in "Instructions for the translation", with: "Translate carefully."
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      first("button", text: "Add").click
    end
    assert_selector "[data-workspace-guard-target='status']", text: "Saved", wait: 10

    experiments = Experiment.count
    page.execute_script(<<~JS)
      const form = document.getElementById("workspace-form")
      const launch = Array.from(form.querySelectorAll("button, input[type='submit']")).find(element => /Start translation/.test(element.textContent || element.value))
      form.requestSubmit(launch)
      form.requestSubmit(launch)
    JS
    assert_current_path(/\A\/experiments\/\d+\z/)
    assert_equal experiments + 1, Experiment.count
    assert_equal baseline + 1, TranslationWorkspaceSubmission.count
    assert TranslationWorkspaceSubmission.order(:id).last.consumed?
    assert_equal 0, AiProviderAttempt.count
  end

  private

  def sign_in_in_browser
    visit login_path
    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  def choose_language(label, value)
    choose_known_language(label, value)
  end

  def assert_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  def drop_next_draft_save_responses(count)
    page.execute_script(<<~JS, count)
      window.__pendingDraftDrops = arguments[0]
      if (!window.__draftFetchWrapped) {
        const deliver = window.fetch.bind(window)
        window.__draftFetchWrapped = true
        window.fetch = async (url, options = {}) => {
          const response = await deliver(url, options)
          const draftSave = new URL(url, location.origin).pathname === "/translation_workspace_draft" && options.method === "POST"
          if (draftSave && window.__pendingDraftDrops > 0) {
            window.__pendingDraftDrops -= 1
            await response.arrayBuffer()
            throw new TypeError("Failed to fetch")
          }
          return response
        }
      }
    JS
  end

  def set_browser_offline(offline)
    page.driver.browser.execute_cdp(
      "Network.emulateNetworkConditions",
      offline: offline, latency: 0, downloadThroughput: -1, uploadThroughput: -1
    )
  end
end
