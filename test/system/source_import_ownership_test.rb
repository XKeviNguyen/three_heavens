require "application_system_test_case"

class SourceImportOwnershipTest < ApplicationSystemTestCase
  setup do
    visit login_path
    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
    visit new_translation_workspace_path
    install_upload_barrier
    @sources = []
  end

  teardown do
    @sources.each(&:close!)
  end

  test "clicking the active upload tab preserves the pending action and feedback" do
    start_upload "Import survives a no-op mode click"
    before = upload_ownership
    click_button "Upload file"
    after = upload_ownership
    feedback = find("[data-workspace-upload-target=message]", visible: :all).text(:all)
    release_upload 0
    assert_field "Reviewed source text", with: "Import survives a no-op mode click"
    assert_equal before, after
    assert_equal I18n.t("upload.extracting"), feedback
    assert_selector "#workspace-source-import", text: File.basename(@sources.first.path)
    assert_saved_source "Import survives a no-op mode click"
    draft = users(:normal).translation_workspace_drafts.sole.payload
    import = users(:normal).source_imports.sole
    assert_equal import.id.to_s, draft.fetch("source_import_id")
    binding = find("#translation_workspace_source_import_project_token", visible: :all).value
    assert SourceImports::ProjectBinding.valid?(token: binding, source_import: import, project: nil)
    page.refresh
    assert_field "Reviewed source text", with: "Import survives a no-op mode click"
  end

  test "clicking the active paste tab does not change source ownership or feedback" do
    page.execute_script("document.querySelector('[data-workspace-upload-target=message]').textContent = 'Keep feedback'")
    before = upload_ownership
    click_button "Paste text"
    assert_equal before, upload_ownership
    assert_text "Keep feedback"
    assert_selector "#source-paste-panel", visible: true
    assert_selector "[data-source-mode-target=pasteTab][aria-selected=true]"
    assert_selector "[data-source-mode-target=uploadTab][aria-selected=false]"
  end

  test "explicit same file upload after supersession owns a new action and the old response stays stale" do
    start_upload "Same file deliberately uploaded again"
    click_button "Paste text"
    fill_in "Source text", with: "Intervening newer source"
    click_button "Upload file"
    # Retry with the exact same browser File while the old response is held.
    click_button "Upload and review"
    assert_upload_held 1
    assert_not_equal page.evaluate_script("window.__uploads[0].key"), page.evaluate_script("window.__uploads[1].key")
    release_upload 0, pending: 1, button_disabled: true
    assert_field "Source text", with: "Intervening newer source", visible: :all
    assert_no_import
    release_upload 1
    assert_field "Reviewed source text", with: "Same file deliberately uploaded again"
    assert_saved_source "Same file deliberately uploaded again"
  end

  test "same file transport retry keeps its replay identity and successful adoption does not invalidate itself" do
    start_upload "Replay the current upload"
    generation = upload_ownership.fetch("generation")
    page.execute_script("window.__uploads[0].drop = true")
    release_upload 0
    click_button "Upload and review"
    assert_upload_held 1
    assert_equal generation, upload_ownership.fetch("generation")
    release_upload 1
    assert_field "Reviewed source text", with: "Replay the current upload"
    assert_equal generation, upload_ownership.fetch("generation")
    assert_text I18n.t("upload.imported")
    page.execute_script("window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('#workspace-source'), 'workspace-upload').upload()")
    assert_upload_held 2
    release_upload 2
    assert_equal 1, page.evaluate_script("new Set(window.__uploads.map(upload => upload.key)).size")
    assert_equal 1, users(:normal).source_imports.count
    assert_saved_source "Replay the current upload"
  end

  test "a held upload cannot overwrite newer source in the encrypted draft or after refresh" do
    fill_in "Source text", with: "Initial source before import"
    start_upload "Imported source from older action"
    click_button "Paste text"
    fill_in "Source text", with: "Newer typed source wins"
    release_upload 0

    assert_equal "Newer typed source wins", find("#translation_workspace_source_text").value
    assert_no_import
    assert_saved_source "Newer typed source wins"
    raw = TranslationWorkspaceDraft.connection.select_value("SELECT workspace_payload FROM translation_workspace_drafts WHERE user_id = #{users(:normal).id}")
    assert_not_includes raw, "Newer typed source wins"
    page.refresh
    assert_field "Source text", with: "Newer typed source wins"
    assert_no_import
  end

  test "switching to paste alone supersedes the held upload" do
    fill_in "Source text", with: "Keep the original paste"
    start_upload "Unwanted import"
    click_button "Paste text"
    release_upload 0
    assert_field "Source text", with: "Keep the original paste"
    assert_no_import
    assert_saved_source "Keep the original paste"
  end

  test "typing alone supersedes an upload without a source mode change" do
    start_upload "Older source before typing", keep_paste: true
    fill_in "Source text", with: "Newer typing without switching tabs"
    release_upload 0
    assert_field "Source text", with: "Newer typing without switching tabs"
    assert_no_import
    assert_saved_source "Newer typing without switching tabs"
    page.refresh
    assert_field "Source text", with: "Newer typing without switching tabs"
  end

  test "source ownership is checked again after reading the response body" do
    start_upload "Older body awaiting delivery", keep_paste: true
    page.execute_script("window.__uploads[0].holdBody = true; window.__uploads[0].release()")
    assert_until { page.evaluate_script("!!window.__uploads[0].releaseBody") }
    fill_in "Source text", with: "Newer source while reading body"
    page.execute_script("window.__uploads[0].releaseBody()")
    assert_until { page.evaluate_script("window.__uploads[0].finished === true") }
    assert_field "Source text", with: "Newer source while reading body"
    assert_no_import
    assert_saved_source "Newer source while reading body"
  end

  test "a newer upload wins when responses arrive in reverse order" do
    start_upload "Older upload A"
    start_upload "Newer upload B"
    release_upload 1, pending: 1
    assert_field "Reviewed source text", with: "Newer upload B"
    import_id = find("#translation_workspace_source_import_id", visible: :all).value
    release_upload 0
    assert_field "Reviewed source text", with: "Newer upload B"
    assert_equal import_id, find("#translation_workspace_source_import_id", visible: :all).value
    assert_selector "#workspace-source-import", text: File.basename(@sources.last.path)
    assert_saved_source "Newer upload B"
  end

  test "replacing the file selection supersedes an upload before the replacement starts" do
    start_upload "Older selected file"
    attach_file "Source file", file_for("Replacement selected file").path
    release_upload 0
    assert_no_import
    assert_equal "", find("#translation_workspace_source_text", visible: :all).value
    click_button "Upload and review"
    assert_upload_held 1
    release_upload 1
    assert_field "Reviewed source text", with: "Replacement selected file"
  end

  test "a newer title decision preserves even an explicitly cleared title" do
    fill_in "Document title", with: "Original title"
    start_upload "Current imported source", keep_paste: true
    fill_in "Document title", with: "Newer title"
    fill_in "Document title", with: ""
    release_upload 0
    assert_field "Reviewed source text", with: "Current imported source"
    assert_field "Document title", with: ""
    assert_saved_source "Current imported source"
    assert_equal "", users(:normal).translation_workspace_drafts.sole.payload.fetch("document_title")
  end

  test "unrelated edits preserve current upload authority and title autofill" do
    start_upload "Current source", keep_paste: true
    fill_in "Project name", with: "New project name"
    fill_in "Instructions for the translation", with: "New instructions"
    release_upload 0
    assert_field "Reviewed source text", with: "Current source"
    assert_field "Document title", with: File.basename(@sources.first.path, ".txt")
    assert_field "Project name", with: "New project name"
    assert_saved_source "Current source"
  end

  test "removing an import invalidates a pending replacement before removal completes" do
    start_upload "First imported source"
    release_upload 0
    first_id = find("#translation_workspace_source_import_id", visible: :all).value
    start_upload "Pending replacement"
    page.execute_script(<<~JS)
      const deliver = window.fetch.bind(window)
      window.fetch = async (url, options = {}) => {
        const response = await deliver(url, options)
        if (options.method === "DELETE") await new Promise(resolve => { window.__releaseRemoval = resolve })
        return response
      }
    JS
    click_button "Remove import"
    assert_until { page.evaluate_script("!!window.__releaseRemoval") }
    release_upload 1, pending: 1
    assert_equal first_id, find("#translation_workspace_source_import_id", visible: :all).value
    assert_equal "First imported source", find("#translation_workspace_source_text", visible: :all).value
    page.execute_script("window.__releaseRemoval()")
    assert_no_selector "#workspace-source-import", visible: true
    assert_no_import
    assert_saved_source "First imported source"
  end

  test "explicit retry after a lost superseded response starts a new authorized action" do
    start_upload "Older response lost"
    click_button "Paste text"
    fill_in "Source text", with: "Newer source after response loss"
    page.execute_script("window.__uploads[0].drop = true")
    release_upload 0
    click_button "Upload file"
    click_button "Upload and review"
    assert_upload_held 1
    release_upload 1
    assert_field "Reviewed source text", with: "Older response lost"
    assert_equal 2, users(:normal).source_imports.count
    assert_equal 2, page.evaluate_script("new Set(window.__uploads.map(upload => upload.key)).size")
    assert_no_text I18n.t("upload.extracting")
    assert_saved_source "Older response lost"
    page.refresh
    assert_field "Reviewed source text", with: "Older response lost"
  end

  test "navigation waits for a superseded upload then saves the newer source" do
    start_upload "Older source before navigation"
    click_button "Paste text"
    fill_in "Source text", with: "Newer source before navigation"
    page.execute_script(<<~JS)
      const guard = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector("[data-controller~='workspace-guard']"), "workspace-guard")
      const settle = guard.settlePending.bind(guard)
      guard.settlePending = () => { window.__navigationWaiting = true; return settle() }
    JS
    click_link "Projects"
    assert_until { page.evaluate_script("window.__navigationWaiting === true") }
    assert_selector "h1", text: "New translation"
    page.execute_script("window.__uploads[0].release()")
    assert_selector "h1", text: "Projects"
    draft = users(:normal).translation_workspace_drafts.sole
    assert_equal "Newer source before navigation", draft.payload.fetch("source_text")
    assert_equal "", draft.payload.fetch("source_import_id")
  end

  private

  def upload_ownership
    page.evaluate_script(<<~JS)
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('#workspace-source'), 'workspace-upload')
        return { generation: controller.sourceGeneration, key: controller.requestKey || null }
      })()
    JS
  end

  # Hold actual successful server responses, and observe the complete upload
  # promise (including finally/pending settlement), rather than waiting a delay.
  def install_upload_barrier
    page.execute_script(<<~JS)
      window.__uploads = []
      const deliver = window.fetch.bind(window)
      window.fetch = async (url, options = {}) => {
        if (new URL(url, location.origin).pathname !== "/source_imports.json") return deliver(url, options)
        const delivery = { key: options.body.get("source_import[request_key]") }
        window.__uploads.push(delivery)
        const response = await deliver(url, options)
        await response.clone().arrayBuffer()
        delivery.status = response.status
        await new Promise(resolve => { delivery.release = resolve })
        if (delivery.drop) throw new TypeError("synthetic response loss")
        if (delivery.holdBody) {
          const read = response.json.bind(response)
          response.json = async () => {
            const result = await read()
            await new Promise(resolve => { delivery.releaseBody = resolve })
            return result
          }
        }
        return response
      }
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector("#workspace-source"), "workspace-upload")
      const upload = controller.upload.bind(controller)
      controller.upload = async () => {
        const index = window.__uploads.length
        try { await upload() } finally { window.__uploads[index].finished = true }
      }
    JS
  end

  def file_for(text)
    source = Tempfile.new([ "ownership-source", ".txt" ])
    @sources << source
    source.write(text)
    source.flush
    source
  end

  def start_upload(text, keep_paste: false)
    source = file_for(text)
    index = page.evaluate_script("window.__uploads.length")
    click_button "Upload file"
    attach_file "Source file", source.path
    if keep_paste
      # Exercise title/input ownership independently of a later mode decision.
      click_button "Paste text"
      page.execute_script("window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('#workspace-source'), 'workspace-upload').upload()")
    else
      click_button "Upload and review"
    end
    assert_upload_held index
  end

  def assert_upload_held(index)
    assert_until { page.evaluate_script("!!window.__uploads[#{index}]?.release") }
    assert_equal 201, page.evaluate_script("window.__uploads[#{index}].status")
  end

  def release_upload(index, pending: 0, button_disabled: false)
    page.execute_script("window.__uploads[#{index}].release()")
    assert_until { page.evaluate_script("window.__uploads[#{index}].finished === true") }
    assert_equal button_disabled, find("[data-workspace-upload-target='button']", visible: :all).disabled?
    assert_until do
      page.evaluate_script("window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=workspace-guard]'), 'workspace-guard').pending.size === #{pending}")
    end
  end

  def assert_no_import
    assert_equal "", find("#translation_workspace_source_import_id", visible: :all).value
    assert_equal "", find("#translation_workspace_source_import_project_token", visible: :all).value
    assert_no_selector "#workspace-source-import", visible: true
  end

  def assert_saved_source(text)
    assert_until { users(:normal).translation_workspace_drafts.first&.payload&.fetch("source_text", nil) == text }
    assert_selector "[data-workspace-guard-target='status']", text: I18n.t("workspace.saved")
    assert_equal text, users(:normal).translation_workspace_drafts.sole.payload.fetch("source_text")
  end

  def assert_until
    Timeout.timeout(10) { loop { return if yield; Thread.pass } }
  end
end
