require "application_system_test_case"
require "tempfile"
require_relative "../support/translation_reference_test_helper"
require_relative "../support/methodology_profile_test_helper"
require_relative "../support/workflow_profile_test_helper"

class TranslationWorkspaceIntegrityTest < ApplicationSystemTestCase
  include TranslationReferenceTestHelper
  include MethodologyProfileTestHelper
  include WorkflowProfileTestHelper

  setup do
    @reference = create_translation_reference
    @methodology = create_methodology_profile
    @workflow = create_workflow_profile
    @glossary = Glossaries::Create.call(
      user: users(:normal),
      attributes: {
        name: "Workspace terms",
        source_language: "Vietnamese",
        target_language: "Japanese",
        entries: [ { source_term: "Grace", preferred_target_term: "恵み" } ]
      }
    )
    sign_in_in_browser
  end

  test "primary fields and auxiliary editor have separate real DOM form owners" do
    visit new_translation_workspace_path
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    find("#workspace-glossary summary", text: "Choose saved glossary").click
    find("input[name='translation_workspace[glossary_revision_id]'][value='#{@glossary.current_revision_id}']", visible: :all).choose
    assert_selector "#workspace-glossary", text: "Workspace terms"
    find("details > summary", text: /References, methodology/).click
    find("input[name='translation_workspace[translation_reference_revision_ids][]']").check
    find("input[name='translation_workspace[methodology_profile_revision_id]'][value='#{@methodology.current_revision_id}']").choose
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add"
      first("button", text: "Add").click
    end

    names = %w[
      project_name source_language target_language document_title source_text
      experiment_name instruction_prompt workflow_mode glossary_revision_id
      translation_reference_revision_ids methodology_profile_revision_id
      guidance_preference model_identifiers
    ]
    owners = page.evaluate_script(<<~JS)
      #{names.to_json}.map(name => {
        const input = document.querySelector(`[name^="translation_workspace[${name}]"]`)
        return [name, input?.form?.id || null]
      })
    JS
    assert_equal names.map { |name| [ name, "workspace-form" ] }, owners
    assert_equal "workspace-form", page.evaluate_script("document.querySelector('#workspace-launch input[type=submit]').form.id")
    assert_equal 0, page.evaluate_script("document.querySelectorAll('#workspace-form form').length")
    assert_equal 0, page.evaluate_script("document.querySelectorAll('#source-upload-panel form').length")

    click_link "+ Add terminology"
    assert_selector "dialog[open] form[action='#{workspace_terminology_path}']"
    assert_equal 0, page.evaluate_script("document.querySelectorAll('#workspace-form form').length")
    assert_nil page.evaluate_script("document.querySelector('dialog[open] form').closest('#workspace-form')")
  end

  test "saved navigation restores a populated workspace" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Protected project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    fill_in "Document title", with: "Protected source"
    fill_in "Source text", with: "Long source text that must not disappear."
    fill_in "Translation name", with: "Protected translation"
    fill_in "Instructions for the translation", with: "Preserve the meaning."
    find("#workspace-glossary summary", text: "Choose saved glossary").click
    find("input[name='translation_workspace[glossary_revision_id]'][value='#{@glossary.current_revision_id}']", visible: :all).choose
    assert_selector "#workspace-glossary", text: "Workspace terms"
    find("details > summary", text: /References, methodology/).click
    find("input[name='translation_workspace[translation_reference_revision_ids][]']").check
    find("input[name='translation_workspace[methodology_profile_revision_id]'][value='#{@methodology.current_revision_id}']").choose
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add"
      first("button", text: "Add").click
    end

    {
      "References" => translation_references_path,
      "Projects" => projects_path,
      "History" => history_path,
      "Terminology" => glossaries_path,
      "Methodology" => methodology_profiles_path,
      "Workflows" => workflow_profiles_path,
      "Benchmarks" => benchmarks_path
    }.each do |label, path|
      click_link label
      assert_current_path path
      assert_no_selector "dialog[open]", text: "Leave this translation?"
      click_link "New translation"
      assert_field "Project name", with: "Protected project"
      assert_field "Source language", with: "Vietnamese"
      assert_field "Target language", with: "Japanese"
      assert_field "Document title", with: "Protected source", visible: :all
      assert_field "Source text", with: "Long source text that must not disappear.", visible: :all
      assert_field "Translation name", with: "Protected translation"
      assert_field "Instructions for the translation", with: "Preserve the meaning."
      assert_selector "#workspace-manual-models [data-model-card]", count: 1, visible: :all
      assert_checked_field "translation_workspace[translation_reference_revision_ids][]", visible: :all
      assert_checked_field "translation_workspace[methodology_profile_revision_id]", visible: :all
      assert_checked_field "translation_workspace[glossary_revision_id]", visible: :all
      assert_checked_field "translation_workspace[workflow_mode]", with: "manual", visible: :all
    end
  end

  test "browser Back and Forward restore a changed workspace" do
    visit projects_path
    click_link "New translation"
    assert_current_path new_translation_workspace_path
    fill_in "Project name", with: "Back protected"

    page.execute_script("document.body.dataset.historyDocument = 'workspace'")
    page.go_back
    assert_document_replaced "body[data-history-document='workspace']"
    assert_selector "h1", text: "Projects"
    assert_current_path projects_path
    assert_no_selector "dialog[open]", text: "Leave this translation?"
    page.execute_script("document.body.dataset.historyDocument = 'projects'")
    page.go_forward
    assert_document_replaced "body[data-history-document='projects']"
    assert_selector "h1", text: "New translation"
    assert_current_path new_translation_workspace_path
    assert_field "Project name", with: "Back protected"
  end

  test "pristine workspace navigates without a warning" do
    visit new_translation_workspace_path
    click_link "Projects"
    assert_current_path projects_path
    assert_no_selector "dialog[open]", text: "Leave this translation?"
  end

  test "workspace controls preserve the populated source and configuration" do
    visit new_translation_workspace_path
    page.execute_script("window.__workspaceErrors = []; window.addEventListener('error', event => window.__workspaceErrors.push(event.message)); window.addEventListener('unhandledrejection', event => window.__workspaceErrors.push(String(event.reason)))")
    fill_in "Project name", with: "Control project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    fill_in "Document title", with: "Control source"
    fill_in "Source text", with: "Substantial source text for interaction checks."
    fill_in "Translation name", with: "Control translation"
    fill_in "Instructions for the translation", with: "Translate with care."
    find("#workspace-glossary summary", text: "Choose saved glossary").click
    find("input[name='translation_workspace[glossary_revision_id]'][value='#{@glossary.current_revision_id}']", visible: :all).choose
    assert_selector "#workspace-glossary", text: "Workspace terms"
    find("details > summary", text: /References, methodology/).click
    find("input[name='translation_workspace[translation_reference_revision_ids][]']").check
    find("input[name='translation_workspace[methodology_profile_revision_id]'][value='#{@methodology.current_revision_id}']").choose
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add"
      first("button", text: "Add").click
    end
    assert_core_state

    target = find_field("Target language")
    target.fill_in with: "fren"
    target.send_keys(:arrow_down, :enter)
    assert_field "Target language", with: "French"
    assert_core_state(target_language: "French")
    target.fill_in with: "japan"
    target.send_keys(:arrow_down, :enter)
    assert_core_state

    find("button[data-action='language-swap#swap']").click
    assert_core_state(source_language: "Japanese", target_language: "Vietnamese")
    find("button[data-action='language-swap#swap']").click
    assert_core_state

    click_button "Upload file"
    assert_selector "#source-upload-panel", visible: true
    assert_core_state
    click_button "Paste text"
    assert_core_state

    find("details > summary", text: /References, methodology/).click
    assert_core_state
    find("details > summary", text: /References, methodology/).click

    within "#workspace-manual-models" do
      search = find("input[placeholder='Search OpenRouter models…']")
      search.fill_in with: "claude"
      assert_selector "[role='option']", text: /Claude/
      search.fill_in with: ""
      find("select[data-model-browser-target='provider']").select("anthropic")
      assert_selector "[role='option']", text: /Anthropic/
      find("select[data-model-browser-target='provider']").select("All providers")
      assert_equal "true", search[:'aria-expanded']
    end
    find_field("Project name").click
    assert_selector "#workspace-manual-models input[placeholder='Search OpenRouter models…'][aria-expanded='false']"
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "[role='option']", visible: true
    end
    assert_core_state

    choose "Automatic"
    choose "translation_workspace_workflow_profile_revision_id_#{@workflow.current_revision_id}"
    assert_core_state
    choose "Manual"
    assert_core_state

    click_link "Edit terminology"
    assert_selector "dialog[open] form[action='#{workspace_terminology_path}']"
    click_button "Cancel"
    assert_core_state

    click_link "Edit terminology"
    within "dialog[open]" do
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈悲"
      click_button "Save terminology"
    end
    assert_no_selector "dialog[open]"
    assert_equal 2, @glossary.reload.current_revision.version
    assert_core_state

    click_link "+ Add terminology"
    assert_selector "dialog[open] form[action='#{workspace_terminology_path}']"
    within "dialog[open]" do
      fill_in "Glossary name", with: "New workspace terms"
      choose_known_language "Source language", "Vietnamese"
      choose_known_language "Target language", "Japanese"
      first("input[name='glossary[entries][][source_term]']").fill_in with: "Mercy"
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈しみ"
      click_button "Create & select"
    end
    assert_no_selector "dialog[open]"
    assert_core_state(glossary_name: "New workspace terms")
    assert_empty page.evaluate_script("window.__workspaceErrors")
  end

  # Saving replaces the panel that opened the sheet, so focus used to fall to
  # the page body; it must return to the equivalent control in the new panel.
  test "terminology sheet returns focus to the panel after saving and reopens cleanly" do
    visit new_translation_workspace_path
    find("#workspace-glossary summary", text: "Choose saved glossary").click
    find("input[name='translation_workspace[glossary_revision_id]'][value='#{@glossary.current_revision_id}']", visible: :all).choose
    assert_selector "#workspace-glossary", text: "Workspace terms"

    click_link "Edit terminology"
    within "dialog[open]" do
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈悲"
      click_button "Save terminology"
    end
    assert_no_selector "dialog[open]"
    assert_equal [ "A", "Edit terminology" ], page.evaluate_script("[document.activeElement.tagName, document.activeElement.textContent.trim()]")

    click_link "Edit terminology"
    assert_selector "dialog[open] form[action='#{workspace_terminology_path}']"
    click_button "Cancel"
    click_link "+ Add terminology"
    within "dialog[open]" do
      fill_in "Glossary name", with: "Second workspace terms"
      choose_known_language "Source language", "Vietnamese"
      choose_known_language "Target language", "Japanese"
      first("input[name='glossary[entries][][source_term]']").fill_in with: "Mercy"
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈しみ"
      click_button "Create & select"
    end
    assert_no_selector "dialog[open]"
    assert page.evaluate_script("!!document.activeElement.closest('#workspace-terminology')"), "focus must return to the terminology panel"
    created = users(:normal).glossaries.joins(:current_revision).find_by!(glossary_revisions: { name: "Second workspace terms" })
    assert_until { users(:normal).translation_workspace_drafts.first&.payload&.fetch("glossary_revision_id", nil) == created.current_revision_id.to_s }

    # Each reopen replaces the editor; no Stimulus binding may keep an old
    # editor's elements alive (they used to accumulate for the whole session).
    3.times do
      click_link "Edit terminology"
      assert_selector "dialog[open] form[action='#{workspace_terminology_path}']"
      click_button "Cancel"
      assert_no_selector "dialog[open]"
    end
    assert_equal 0, page.evaluate_script("Array.from(window.Stimulus.dispatcher.eventListenerMaps.keys()).filter(target => !target.isConnected).length")

    click_link "Edit terminology"
    assert_selector "dialog[open] form[action='#{workspace_terminology_path}']"
    assert_equal [ 1, 1 ], page.evaluate_script("[document.querySelectorAll('dialog[data-controller=\"terminology-sheet\"]').length, document.querySelectorAll('#workspace-terminology-editor form').length]")
  end

  test "leaving while a closed terminology sheet still saves waits for that save to reach the draft" do
    visit new_translation_workspace_path
    select_workspace_glossary
    hold_terminology_submissions

    click_link "Edit terminology"
    within "dialog[open]" do
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈悲"
      click_button "Save terminology"
    end
    assert_until { page.evaluate_script("window.__terminologyHeld") == 200 }
    find("dialog[open]").send_keys(:escape)
    assert_no_selector "dialog[open]"
    revised = @glossary.reload.current_revision

    # Leaving for another workspace page of the same draft waits for the save.
    page.execute_script("window.__samePage = true; document.body.dataset.leavingDocument = 'old'")
    first("a[href='#{new_translation_workspace_path}']").click
    # The page waits for the save instead of leaving.
    assert_selector "[data-workspace-guard-target='status']", text: I18n.t("workspace.saving")
    page.execute_script("window.__releaseTerminology()")
    assert_until { workspace_draft_glossary == revised.id.to_s }
    # The workspace was replaced by the visit, in the same document.
    assert_until { page.evaluate_script("window.__samePage === true && !document.body.dataset.leavingDocument && document.documentElement.getAttribute('aria-busy') === null") }
    assert_selector "input[name='translation_workspace[glossary_revision_id]'][value='#{revised.id}']:checked", visible: :all
  end

  test "a glossary chosen while a terminology save is in flight stays chosen" do
    other = Glossaries::Create.call(
      user: users(:normal),
      attributes: { name: "Other terms", source_language: "Vietnamese", target_language: "Japanese",
                    entries: [ { source_term: "Peace", preferred_target_term: "平和" } ] }
    )
    visit new_translation_workspace_path
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    choose_glossary(@glossary)
    assert_until { workspace_draft_glossary == @glossary.current_revision_id.to_s }
    hold_terminology_submissions

    click_link "Edit terminology"
    within "dialog[open]" do
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈悲"
      click_button "Save terminology"
    end
    assert_until { page.evaluate_script("window.__terminologyHeld") == 200 }
    find("dialog[open]").send_keys(:escape)
    assert_no_selector "dialog[open]"

    # The newer, explicit choice is made while the save is still in flight.
    choose_glossary(other)
    assert_selector "#workspace-glossary", text: "Other terms"
    page.execute_script("window.__releaseTerminology()")

    assert_until { page.evaluate_script("window.__sheetChanged") == 1 }
    assert_equal 2, @glossary.reload.current_revision.version, "the library save itself still lands"
    assert_selector "input[name='translation_workspace[glossary_revision_id]'][value='#{other.current_revision_id}']:checked", visible: :all
    assert_until { workspace_draft_glossary == other.current_revision_id.to_s }
    assert_selector "[data-workspace-summary-target='terminology']", text: "Other terms"
    refresh
    assert_selector "input[name='translation_workspace[glossary_revision_id]'][value='#{other.current_revision_id}']:checked", visible: :all
  end

  test "re-choosing the glossary being saved selects its saved revision" do
    other = Glossaries::Create.call(
      user: users(:normal),
      attributes: { name: "Other terms", source_language: "Vietnamese", target_language: "Japanese",
                    entries: [ { source_term: "Peace", preferred_target_term: "平和" } ] }
    )
    visit new_translation_workspace_path
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    choose_glossary(@glossary)
    assert_until { workspace_draft_glossary == @glossary.current_revision_id.to_s }
    # Hold the save before it reaches the server, so the panel keeps listing
    # the glossary's old revision until the save commits.
    page.execute_script(<<~JS)
      window.__sheetChanged = 0
      document.addEventListener("terminology-sheet:changed", () => { window.__sheetChanged += 1 })
      const deliver = window.fetch
      window.fetch = async (url, options = {}) => {
        const target = new URL(url, location.origin)
        if (target.pathname.startsWith("/workspace_terminology") && (options.method || "GET").toUpperCase() !== "GET" && !window.__releaseTerminology) {
          await new Promise(resolve => { window.__releaseTerminology = resolve })
        }
        return deliver(url, options)
      }
    JS

    click_link "Edit terminology"
    within "dialog[open]" do
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈悲"
      click_button "Save terminology"
    end
    assert_until { page.evaluate_script("!!window.__releaseTerminology") }
    find("dialog[open]").send_keys(:escape)
    choose_glossary(other)
    # Back to the glossary whose save has not committed, at its old revision.
    choose_glossary(@glossary)
    assert_selector "input[name='translation_workspace[glossary_revision_id]'][value='#{@glossary.current_revision_id}']:checked", visible: :all
    page.execute_script("window.__releaseTerminology()")

    assert_until { page.evaluate_script("window.__sheetChanged") == 1 }
    saved = @glossary.reload.current_revision
    assert_equal 2, saved.version
    assert_selector "input[name='translation_workspace[glossary_revision_id]'][value='#{saved.id}']:checked", visible: :all
    assert_until { workspace_draft_glossary == saved.id.to_s }
    assert_selector "[data-workspace-summary-target='terminology']", text: "Workspace terms"
  end

  test "a page control replaced while its save ran lapses and later saves still come first" do
    TranslationWorkspacesController::CONFIGURATION_OPTION_LIMIT.times do |index|
      Glossaries::Create.call(user: users(:normal), attributes: { name: "Paged terms #{index}", source_language: "Vietnamese",
                                                                  target_language: "Japanese", entries: [ { source_term: "Term", preferred_target_term: "語" } ] })
    end
    @glossary.touch
    visit new_translation_workspace_path
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    choose_glossary(@glossary)
    assert_until { workspace_draft_glossary == @glossary.current_revision_id.to_s }
    visit new_translation_workspace_path
    assert_selector "nav[aria-label='Glossaries pagination']", visible: :all
    hold_terminology_submissions

    click_link "Edit terminology"
    within "dialog[open]" do
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈悲"
      click_button "Save terminology"
    end
    assert_until { page.evaluate_script("window.__terminologyHeld") == 200 }
    find("dialog[open]").send_keys(:escape)
    # The page change waits for the save; the save's panel has no such control.
    find("nav[aria-label='Glossaries pagination'] button[name='glossary_page'][value='2']", visible: :all).execute_script("this.click()")
    page.execute_script("window.__releaseTerminology()")
    assert_until { page.evaluate_script("window.__sheetChanged") == 1 }
    assert_no_selector "nav[aria-label='Glossaries pagination']", visible: :all
    assert_current_path new_translation_workspace_path

    # Signing out afterwards still saves first.
    fill_in "Project name", with: "Saved before signing out"
    click_button "Log out"
    assert_current_path login_path
    assert_equal "Saved before signing out", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
  end

  test "a second terminology save cannot start while one is in flight" do
    visit new_translation_workspace_path
    select_workspace_glossary
    hold_terminology_submissions
    page.execute_script(<<~JS)
      window.__terminologyPosts = 0
      document.addEventListener("turbo:submit-start", event => { if (event.target.closest("#workspace-terminology-editor")) window.__terminologyPosts += 1 })
    JS

    click_link "Edit terminology"
    within "dialog[open]" do
      field = first("input[name='glossary[entries][][preferred_target_term]']")
      field.fill_in with: "慈悲"
      click_button "Save terminology"
      assert_until { page.evaluate_script("window.__terminologyHeld") == 200 }
      field.send_keys(:enter)
    end
    # The submit event of an Enter is handled synchronously, so a second save
    # would already have started; release the first and wait for it to land.
    page.execute_script("window.__releaseTerminology()")
    assert_until { page.evaluate_script("window.__sheetChanged") == 1 }
    assert_equal 1, page.evaluate_script("window.__terminologyPosts")
    assert_until { workspace_draft_glossary == @glossary.reload.current_revision_id.to_s }
  end

  test "another editor opened while a closed sheet still saves loads after that save" do
    visit new_translation_workspace_path
    select_workspace_glossary
    hold_terminology_submissions

    click_link "Edit terminology"
    within "dialog[open]" do
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈悲"
      click_button "Save terminology"
    end
    assert_until { page.evaluate_script("window.__terminologyHeld") == 200 }
    find("dialog[open]").send_keys(:escape)
    assert_no_selector "dialog[open]"
    revised = @glossary.reload.current_revision

    page.execute_script(<<~JS)
      document.addEventListener("turbo:before-fetch-request", event => {
        if (event.target.id === "workspace-terminology-editor") window.__editorDeferred = event.defaultPrevented
      })
    JS
    click_link "+ Add terminology"
    assert_until { !page.evaluate_script("window.__editorDeferred").nil? }
    assert page.evaluate_script("window.__editorDeferred"), "the new editor must wait for the save in flight"
    assert_no_selector "dialog[open]"
    assert_equal 0, page.evaluate_script("window.__sheetChanged")
    page.execute_script("window.__releaseTerminology()")
    assert_until { workspace_draft_glossary == revised.id.to_s }
    assert_selector "dialog[open] form[action='#{workspace_terminology_path}']"
  end

  # The response to a save can arrive after the user has already closed the
  # sheet; the selection it makes must still reach the saved draft.
  test "a terminology save that lands after the sheet was closed early is autosaved" do
    visit new_translation_workspace_path
    select_workspace_glossary
    hold_terminology_submissions

    click_link "Edit terminology"
    within "dialog[open]" do
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈悲"
      click_button "Save terminology"
    end
    assert_until { page.evaluate_script("window.__terminologyHeld") == 200 }
    find("dialog[open]").send_keys(:escape)
    assert_no_selector "dialog[open]"
    revised = @glossary.reload.current_revision
    assert_equal 2, revised.version
    assert_equal 0, page.evaluate_script("window.__sheetChanged")

    page.execute_script("window.__releaseTerminology()")
    assert_selector "input[name='translation_workspace[glossary_revision_id]'][value='#{revised.id}']:checked", visible: :all
    assert_until { workspace_draft_glossary == revised.id.to_s }
    assert_equal 1, page.evaluate_script("window.__sheetChanged")
    assert_no_selector "dialog[open]"

    refresh
    assert_selector "input[name='translation_workspace[glossary_revision_id]'][value='#{revised.id}']:checked", visible: :all
    assert_equal 1, page.evaluate_script("document.querySelectorAll(\"input[name='translation_workspace[glossary_revision_id]']:checked\").length")
  end

  test "a failed or refused terminology save after an early close changes nothing" do
    visit new_translation_workspace_path
    original = @glossary.current_revision_id
    select_workspace_glossary

    # A save the server refuses (the glossary changed meanwhile) re-renders
    # the editor with its error instead of emptying it.
    hold_terminology_submissions
    click_link "Edit terminology"
    assert_selector "dialog[open] input[name='glossary[entries][][preferred_target_term]']"
    Glossaries::Revise.call(glossary: @glossary, expected_version: 1, attributes: {
      name: "Workspace terms", source_language: "Vietnamese", target_language: "Japanese",
      entries: [ { source_term: "Grace", preferred_target_term: "恩寵" } ]
    })
    within "dialog[open]" do
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈悲"
      click_button "Save terminology"
    end
    assert_until { page.evaluate_script("window.__terminologyHeld") == 409 }
    click_button "Cancel"
    assert_no_selector "dialog[open]"
    page.execute_script("window.__releaseTerminology()")
    assert_selector "dialog[open] [role='alert']", text: "This glossary changed while you were editing it"
    click_button "Cancel"
    assert_no_selector "dialog[open]"

    # A request that never reaches the server.
    hold_terminology_submissions(fail: true)
    click_link "+ Add terminology"
    within "dialog[open]" do
      fill_in "Glossary name", with: "Never created terms"
      choose_known_language "Source language", "Vietnamese"
      choose_known_language "Target language", "Japanese"
      first("input[name='glossary[entries][][source_term]']").fill_in with: "Mercy"
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈しみ"
      click_button "Create & select"
    end
    assert_until { page.evaluate_script("window.__terminologyHeld") == "network" }
    find("dialog[open]").send_keys(:escape)
    assert_no_selector "dialog[open]"
    page.execute_script("window.__releaseTerminology()")

    sleep 1.5 # longer than the autosave debounce, so a false change would have saved
    assert_equal 0, page.evaluate_script("window.__sheetChanged")
    assert_equal original.to_s, workspace_draft_glossary
    assert_not users(:normal).glossaries.joins(:current_revision).exists?(glossary_revisions: { name: "Never created terms" })
    assert_selector "input[name='translation_workspace[glossary_revision_id]'][value='#{original}']:checked", visible: :all
  end

  # The paid-provider confirmation authorizes one launch and is never part of
  # the saved draft, so ticking it must not trigger or claim a save.
  test "the automatic launch confirmation is never autosaved or reported as saved" do
    visit new_translation_workspace_path
    choose "Automatic"
    choose "translation_workspace_workflow_profile_revision_id_#{@workflow.current_revision_id}"
    assert_until { users(:normal).translation_workspace_drafts.first&.payload&.fetch("workflow_profile_revision_id", nil) == @workflow.current_revision_id.to_s }
    assert_selector "[data-workspace-guard-target='status']", text: "Saved"
    page.execute_script(<<~JS)
      window.__draftSaves = 0
      window.__statuses = []
      const status = document.querySelector("[data-workspace-guard-target='status']")
      status.textContent = ""
      new MutationObserver(() => window.__statuses.push(status.textContent)).observe(status, { childList: true, characterData: true, subtree: true })
      const deliver = window.fetch.bind(window)
      window.fetch = (url, options = {}) => {
        if (new URL(url, location.origin).pathname === "/translation_workspace_draft" && options.method === "POST") window.__draftSaves += 1
        return deliver(url, options)
      }
    JS

    check "translation_workspace[automatic_confirmation]"
    sleep 1.5 # longer than the autosave debounce
    assert_equal [ 0, [] ], page.evaluate_script("[window.__draftSaves, window.__statuses]")
    assert_checked_field "translation_workspace[automatic_confirmation]"

    fill_in "Translation name", with: "Saved normally"
    assert_selector "[data-workspace-guard-target='status']", text: "Saved"
    assert_equal 1, page.evaluate_script("window.__draftSaves")
    assert_includes page.evaluate_script("window.__statuses"), "Saving…"
    payload = users(:normal).translation_workspace_drafts.sole.payload
    assert_equal "Saved normally", payload.fetch("experiment_name")
    assert_not payload.key?("automatic_confirmation")

    refresh
    assert_field "Translation name", with: "Saved normally"
    assert_no_checked_field "translation_workspace[automatic_confirmation]"
  end

  test "a newer model search aborts an older slow one and is never overwritten by it" do
    visit new_translation_workspace_path
    page.execute_script(<<~JS)
      window.__catalogRequests = []
      const deliver = window.fetch.bind(window)
      window.fetch = (url, options = {}) => {
        const target = new URL(url, location.origin)
        if (target.pathname !== "/open_router_catalog") return deliver(url, options)
        const record = { q: target.searchParams.get("q"), aborted: false }
        window.__catalogRequests.push(record)
        options.signal?.addEventListener("abort", () => { record.aborted = true })
        if (record.q !== "gemini") return deliver(url, options)
        return new Promise((resolve, reject) => {
          setTimeout(() => deliver(url, options).then(resolve, reject), 1500)
          options.signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")))
        })
      }
    JS
    within "#workspace-manual-models" do
      search = find("input[placeholder='Search OpenRouter models…']")
      search.fill_in with: "gemini"
      assert_until { page.evaluate_script("window.__catalogRequests.some(r => r.q === 'gemini')") }
      search.fill_in with: "claude"
      # The search box is not a draft field, so typing in it must not claim a save.
      assert_not_includes page.evaluate_script("document.querySelector(\"[data-workspace-guard-target='status']\").textContent"), "Saving"
      assert_selector "[role='option']", text: "Claude", minimum: 1
      sleep 2
      assert_selector "[role='option']", text: "Claude", minimum: 1
      assert_no_selector "[role='option']", text: "Gemini"
    end
    assert page.evaluate_script("window.__catalogRequests.find(r => r.q === 'gemini').aborted"), "the superseded request must be aborted"
  end

  test "success failure and removal of an import preserve unrelated workspace fields" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Import project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    fill_in "Document title", with: "Original title"
    fill_in "Source text", with: "Prior pasted source"
    fill_in "Translation name", with: "Import translation"
    fill_in "Instructions for the translation", with: "Keep nuance."
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add"
      first("button", text: "Add").click
    end

    click_button "Upload file"
    bad = Tempfile.new([ "bad-source", ".pdf" ])
    bad.write("%PDF-1.4 not allowed")
    bad.flush
    attach_file "Source file", bad.path
    click_button "Upload and review"
    assert_text /not supported|TXT|DOCX|Markdown/i
    assert_field "Project name", with: "Import project"
    assert_field "Source text", with: "Prior pasted source", visible: :all
    assert_selector "#workspace-manual-models [data-model-card]", count: 1

    good = Tempfile.new([ "good-source", ".txt" ])
    good.write("Imported source")
    good.flush
    attach_file "Source file", good.path
    click_button "Upload and review"
    assert_field "Reviewed source text", with: "Imported source"
    assert_field "Project name", with: "Import project"
    assert_field "Translation name", with: "Import translation"
    assert_field "Instructions for the translation", with: "Keep nuance."
    assert_selector "#workspace-manual-models [data-model-card]", count: 1
    assert_selector "#workspace-source-import", visible: true

    click_button "Remove import"
    assert_no_selector "#workspace-source-import", visible: true
    assert_field "Source text", with: "Imported source"
    assert_field "Project name", with: "Import project"
    assert_selector "#workspace-manual-models [data-model-card]", count: 1
  ensure
    bad&.close!
    good&.close!
  end

  test "server validation keeps workspace selections and source text" do
    visit new_translation_workspace_path
    fill_in "Project name", with: "Validation project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Vietnamese")
    fill_in "Document title", with: "Validation source"
    fill_in "Source text", with: "Source retained after server validation."
    fill_in "Translation name", with: "Validation translation"
    fill_in "Instructions for the translation", with: "Retain these instructions."
    find("#workspace-glossary summary", text: "Choose saved glossary").click
    find("input[name='translation_workspace[glossary_revision_id]'][value='#{@glossary.current_revision_id}']", visible: :all).choose
    find("details > summary", text: /References, methodology/).click
    find("input[name='translation_workspace[translation_reference_revision_ids][]']").check
    find("input[name='translation_workspace[methodology_profile_revision_id]'][value='#{@methodology.current_revision_id}']").choose
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add"
      first("button", text: "Add").click
    end

    click_button "Start translation"
    assert_selector "#form-errors-heading"
    assert_field "Project name", with: "Validation project"
    assert_field "Source text", with: "Source retained after server validation."
    assert_field "Instructions for the translation", with: "Retain these instructions."
    assert_checked_field "translation_workspace[glossary_revision_id]", visible: :all
    assert_checked_field "translation_workspace[translation_reference_revision_ids][]", visible: :all
    assert_checked_field "translation_workspace[methodology_profile_revision_id]", visible: :all
    assert_selector "#workspace-manual-models [data-model-card]", count: 1
  end

  test "contextual help supports hover keyboard touch escape and outside dismissal" do
    visit new_translation_workspace_path
    hint = find("[aria-label='More information about Source language']")
    tooltip = find("##{hint[:'aria-describedby']}", visible: :all)
    hint.hover
    assert tooltip.visible?
    find("h1").hover
    assert_not tooltip.visible?

    page.execute_script("arguments[0].focus()", hint)
    assert tooltip.visible?
    hint.send_keys(:escape)
    assert_not tooltip.visible?
    assert_equal "false", hint[:'aria-expanded']

    page.execute_script("arguments[0].dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, pointerType: 'touch' })); arguments[0].click()", hint)
    assert tooltip.visible?
    find("h1").click
    assert_not tooltip.visible?
    page.execute_script("arguments[0].blur(); arguments[0].focus()", hint)
    assert tooltip.visible?
  end

  test "catalog response after an outside click does not reopen model results" do
    visit new_translation_workspace_path
    browser = find("#workspace-manual-models")
    assert_selector "#workspace-manual-models [role='option']", minimum: 1
    page.execute_script(<<~JS)
      window.__originalCatalogFetch = window.fetch
      window.__releaseCatalogResponse = null
      window.fetch = (...args) => {
        if (!String(args[0]).includes("open_router_catalog")) return window.__originalCatalogFetch(...args)
        return new Promise(resolve => {
          window.__releaseCatalogResponse = () => window.__originalCatalogFetch(...args).then(resolve)
        })
      }
    JS

    browser.find("select[data-model-browser-target='provider']").select("anthropic")
    assert_equal "function", page.evaluate_script("typeof window.__releaseCatalogResponse")
    find_field("Project name").click
    assert_selector "#workspace-manual-models input[placeholder='Search OpenRouter models…'][aria-expanded='false']"
    page.execute_script("window.__releaseCatalogResponse()")
    assert_selector "#workspace-manual-models [data-model-browser-target='status']", text: /compatible model/
    assert_selector "#workspace-manual-models input[placeholder='Search OpenRouter models…'][aria-expanded='false']"

    browser.find("input[placeholder='Search OpenRouter models…']").click
    assert_selector "#workspace-manual-models [role='option']", visible: true
  end

  private

  def assert_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  # Restoring a draft keeps a glossary only when its languages match.
  def select_workspace_glossary
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    find("#workspace-glossary summary", text: "Choose saved glossary").click
    find("input[name='translation_workspace[glossary_revision_id]'][value='#{@glossary.current_revision_id}']", visible: :all).choose
    assert_selector "#workspace-glossary", text: "Workspace terms"
    assert_until { workspace_draft_glossary == @glossary.current_revision_id.to_s }
  end

  # With several saved glossaries the open list reaches under the sticky
  # launch bar, so the choice is made with the keyboard.
  def choose_glossary(glossary)
    find("#workspace-glossary summary", text: "Choose saved glossary").click
    radio = find("input[name='translation_workspace[glossary_revision_id]'][data-glossary-id='#{glossary.id}']", visible: :all)
    radio.send_keys(:space)
    assert_selector "#workspace-glossary", text: glossary.current_revision.name
  end

  def workspace_draft_glossary
    users(:normal).translation_workspace_drafts.first&.payload&.fetch("glossary_revision_id", nil)
  end

  # Holds the next terminology submission until window.__releaseTerminology()
  # runs: its response once the server has answered (window.__terminologyHeld
  # is the status), or with fail:, a network error without reaching the server.
  def hold_terminology_submissions(fail: false)
    page.execute_script(<<~JS, fail)
      const fail = arguments[0]
      window.__terminologyHeld = null
      if (window.__sheetChanged === undefined) {
        window.__sheetChanged = 0
        document.addEventListener("terminology-sheet:changed", () => { window.__sheetChanged += 1 })
      }
      window.__deliverTerminology ||= window.fetch.bind(window)
      const deliver = window.__deliverTerminology
      window.fetch = (url, options = {}) => {
        const target = new URL(url, location.origin)
        if (!target.pathname.startsWith("/workspace_terminology") || (options.method || "GET").toUpperCase() === "GET") return deliver(url, options)
        window.fetch = deliver
        if (fail) {
          return new Promise((_resolve, reject) => {
            window.__releaseTerminology = () => reject(new TypeError("Failed to fetch"))
            window.__terminologyHeld = "network"
          })
        }
        return deliver(url, options).then(response => new Promise(resolve => {
          window.__releaseTerminology = () => resolve(response)
          window.__terminologyHeld = response.status
        }))
      }
    JS
  end

  def sign_in_in_browser
    visit login_path
    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  def assert_core_state(source_language: "Vietnamese", target_language: "Japanese", glossary_name: "Workspace terms")
    assert_field "Project name", with: "Control project"
    assert_field "Source language", with: source_language
    assert_field "Target language", with: target_language
    assert_field "Document title", with: "Control source", visible: :all
    assert_field "Source text", with: "Substantial source text for interaction checks.", visible: :all
    assert_field "Translation name", with: "Control translation"
    assert_field "Instructions for the translation", with: "Translate with care."
    assert_selector "#workspace-manual-models [data-model-card]", count: 1, visible: :all
    assert_checked_field "translation_workspace[translation_reference_revision_ids][]", visible: :all
    assert_checked_field "translation_workspace[methodology_profile_revision_id]", visible: :all
    assert_selector "[data-workspace-summary-target='terminology']", text: glossary_name
  end

  def choose_language(label, value)
    choose_known_language(label, value)
  end
end
