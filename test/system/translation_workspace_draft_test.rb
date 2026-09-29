require "application_system_test_case"

class TranslationWorkspaceDraftTest < ApplicationSystemTestCase
  setup do
    sign_in_in_browser
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

    accept_confirm do
      click_button "Discard draft"
    end
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

    accept_confirm { click_button "Discard draft" }
    assert_current_path new_translation_workspace_path
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
    click_link "Projects"
    click_link "New translation"
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
