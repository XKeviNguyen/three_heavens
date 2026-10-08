require "application_system_test_case"
require_relative "../support/upload_budget_clock"

class SourceImportReplayTest < ApplicationSystemTestCase
  include UploadBudgetClock
  setup do
    visit login_path
    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  test "retrying a committed cancellation after response loss clears stale provenance" do
    visit new_translation_workspace_path(project_id: projects(:one).id)
    source = Tempfile.new([ "cancel-response", ".txt" ])
    source.write("Reviewed source retained")
    source.flush
    click_button "Upload file"
    attach_file "Source file", source.path
    click_button "Upload and review"
    assert_field "Reviewed source text", with: "Reviewed source retained"
    page.execute_script(<<~JS)
      const deliver = window.fetch.bind(window)
      window.fetch = async (url, options = {}) => {
        const response = await deliver(url, options)
        if (!window.__cancelDropped && new URL(url, location.origin).pathname.startsWith("/source_imports/") && options.method === "DELETE") {
          window.__cancelDropped = true
          await response.arrayBuffer()
          throw new TypeError("synthetic response loss")
        }
        return response
      }
    JS
    click_button "Remove import"
    assert_text "The import could not be removed. Try again."
    assert_empty users(:normal).source_imports.reload
    click_button "Remove import"
    assert_text "Import removed. The reviewed text remains in the editor."
    assert_equal "", find("#translation_workspace_source_import_id", visible: :all).value
    assert_equal "", find("#translation_workspace_source_import_project_token", visible: :all).value
    assert_field "Source text", with: "Reviewed source retained"
  ensure
    source&.close!
  end

  # The first delivery is stored and answered by the server, but the browser
  # discards the answer as if the connection dropped. Uploading the same chosen
  # file again must resolve to that import rather than storing a second copy.
  test "retrying an upload whose response was lost keeps one import and one blob" do
    9.times { UploadBudget.consume(user: users(:normal)) }
    visit new_translation_workspace_path(project_id: projects(:one).id)
    click_button "Upload file"
    source = Tempfile.new([ "lost-response", ".txt" ])
    source.write("Uploaded once despite a lost response")
    source.flush
    attach_file "Source file", source.path
    page.execute_script(<<~JS)
      const deliver = window.fetch.bind(window)
      window.__pendingUploadDrops = 1
      window.__pendingUploadThrottles = 1
      window.__uploadActionKeys = []
      window.fetch = async (url, options = {}) => {
        if (new URL(url, location.origin).pathname === "/source_imports.json") window.__uploadActionKeys.push(options.body.get("source_import[request_key]"))
        const response = await deliver(url, options)
        if (new URL(url, location.origin).pathname === "/source_imports.json" && window.__pendingUploadDrops > 0) {
          window.__pendingUploadDrops -= 1
          await response.arrayBuffer()
          throw new TypeError("Failed to fetch")
        }
        if (new URL(url, location.origin).pathname === "/source_imports.json" && window.__pendingUploadThrottles > 0) {
          window.__pendingUploadThrottles -= 1
          await response.arrayBuffer()
          return new Response(JSON.stringify({ error: "synthetic unresolved throttle" }), { status: 429, headers: { "Content-Type": "application/json" } })
        }
        return response
      }
    JS

    click_button "Upload and review"
    assert_text "Failed to fetch"
    assert_equal 1, users(:normal).source_imports.count

    click_button "Upload and review"
    assert_text "synthetic unresolved throttle"
    click_button "Upload and review"
    assert_field "Reviewed source text", with: "Uploaded once despite a lost response"
    source_import = users(:normal).source_imports.sole
    assert_equal source_import.id.to_s, find("#translation_workspace_source_import_id", visible: :all).value
    assert_equal 1, ActiveStorage::Attachment.where(record: source_import).count
    assert_equal 10, UploadBudget.find_by!(user: users(:normal)).count
    assert_equal 1, page.evaluate_script("new Set(window.__uploadActionKeys).size")
    binding = find("#translation_workspace_source_import_project_token", visible: :all).value
    assert SourceImports::ProjectBinding.valid?(token: binding, source_import: source_import, project: projects(:one))
  ensure
    source&.close!
  end

  test "an older cancellation response preserves a newer upload selection" do
    visit new_translation_workspace_path
    first = Tempfile.new([ "first-source", ".txt" ])
    second = Tempfile.new([ "second-source", ".txt" ])
    first.write("First imported source")
    second.write("Second imported source")
    [ first, second ].each(&:flush)
    click_button "Upload file"
    attach_file "Source file", first.path
    click_button "Upload and review"
    assert_field "Reviewed source text", with: "First imported source"
    first_id = find("#translation_workspace_source_import_id", visible: :all).value
    page.execute_script(<<~JS)
      const deliver = window.fetch.bind(window)
      window.fetch = async (url, options = {}) => {
        const response = await deliver(url, options)
        if (options.method === "DELETE" && new URL(url, location.origin).pathname.startsWith("/source_imports/")) {
          await new Promise(resolve => { window.__releaseRemoval = resolve })
        }
        return response
      }
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector("[data-controller~='workspace-upload']"), "workspace-upload")
      const remove = controller.remove.bind(controller)
      controller.remove = async () => { await remove(); window.__removalFinished = true }
    JS
    click_button "Remove import"
    assert_until { page.evaluate_script("!!window.__releaseRemoval") }
    click_button "Upload file"
    attach_file "Source file", second.path
    click_button "Upload and review"
    assert_field "Reviewed source text", with: "Second imported source"
    second_id = find("#translation_workspace_source_import_id", visible: :all).value
    assert_not_equal first_id, second_id
    page.execute_script("window.__releaseRemoval()")
    assert_until { page.evaluate_script("window.__removalFinished") }
    assert_equal second_id, find("#translation_workspace_source_import_id", visible: :all).value
    assert_selector "#workspace-source-import", text: File.basename(second.path)
    assert SourceImport.exists?(second_id)
    assert_not SourceImport.exists?(first_id)
  ensure
    first&.close!
    second&.close!
  end

  # A decided failure ends that upload action: choosing Upload again with the
  # same file is a new action, so a storage outage is not repeated forever.
  test "uploading the same file again after a storage failure starts a new upload" do
    failures = 1
    service = ActiveStorage::Blob.service
    service.define_singleton_method(:upload) do |*arguments, **options|
      raise IOError, "synthetic storage outage" if (failures -= 1) >= 0

      super(*arguments, **options)
    end
    visit new_translation_workspace_path
    click_button "Upload file"
    source = Tempfile.new([ "storage-outage", ".txt" ])
    source.write("Stored on the second attempt")
    source.flush
    attach_file "Source file", source.path

    click_button "Upload and review"
    assert_text I18n.t("source_imports.errors.storage_unavailable")
    click_button "Upload and review"
    assert_field "Reviewed source text", with: "Stored on the second attempt"
    assert_equal %w[failed ready], users(:normal).source_imports.order(:id).pluck(:status)
    assert_equal 2, users(:normal).source_imports.distinct.count(:request_key)
  ensure
    singleton = ActiveStorage::Blob.service.singleton_class
    singleton.remove_method(:upload) if singleton.method_defined?(:upload, false)
    source&.close!
  end

  test "a delayed successful upload replay cannot restore a cancelled import" do
    visit new_translation_workspace_path
    source = Tempfile.new([ "cancelled-replay", ".txt" ])
    source.write("Original imported text")
    source.flush
    click_button "Upload file"
    attach_file "Source file", source.path
    click_button "Upload and review"
    assert_field "Reviewed source text", with: "Original imported text"
    source_id = find("#translation_workspace_source_import_id", visible: :all).value
    page.execute_script(<<~JS)
      const deliver = window.fetch.bind(window)
      window.fetch = async (url, options = {}) => {
        const response = await deliver(url, options)
        if (options.method === "POST" && new URL(url, location.origin).pathname === "/source_imports.json") {
          await new Promise(resolve => { window.__releaseUploadReplay = resolve })
        }
        return response
      }
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector("[data-controller~='workspace-upload']"), "workspace-upload")
      controller.upload().then(() => { window.__uploadReplayFinished = true })
    JS
    assert_until { page.evaluate_script("!!window.__releaseUploadReplay") }
    click_button "Remove import"
    assert_field "Source text", with: "Original imported text"
    assert_equal "", find("#translation_workspace_source_import_id", visible: :all).value
    fill_in "Source text", with: "Keep these reviewed edits"
    page.execute_script("window.__releaseUploadReplay()")
    assert_until { page.evaluate_script("window.__uploadReplayFinished") }
    assert_equal "", find("#translation_workspace_source_import_id", visible: :all).value
    assert_field "Source text", with: "Keep these reviewed edits"
    assert_no_selector "#workspace-source-import", visible: true
    assert_not SourceImport.exists?(source_id)
  ensure
    source&.close!
  end

  test "an older successful cancellation clears its import when the newer upload fails" do
    visit new_translation_workspace_path
    first = Tempfile.new([ "cancelled-first", ".txt" ])
    second = Tempfile.new([ "invalid-second", ".txt" ])
    first.write("First reviewed text")
    second.write("Second chosen file")
    [ first, second ].each(&:flush)
    click_button "Upload file"
    attach_file "Source file", first.path
    click_button "Upload and review"
    assert_field "Reviewed source text", with: "First reviewed text"
    first_id = find("#translation_workspace_source_import_id", visible: :all).value
    page.execute_script(<<~JS)
      const deliver = window.fetch.bind(window)
      window.fetch = async (url, options = {}) => {
        if (options.method === "POST" && new URL(url, location.origin).pathname === "/source_imports.json") {
          return new Response(JSON.stringify({ error: "synthetic newer upload failure", code: "invalid_format" }), { status: 422, headers: { "Content-Type": "application/json" } })
        }
        const response = await deliver(url, options)
        if (options.method === "DELETE" && new URL(url, location.origin).pathname.startsWith("/source_imports/")) {
          await new Promise(resolve => { window.__releaseOldCancellation = resolve })
        }
        return response
      }
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector("[data-controller~='workspace-upload']"), "workspace-upload")
      const remove = controller.remove.bind(controller)
      controller.remove = async () => { await remove(); window.__oldCancellationFinished = true }
    JS
    click_button "Remove import"
    assert_until { page.evaluate_script("!!window.__releaseOldCancellation") }
    click_button "Upload file"
    attach_file "Source file", second.path
    click_button "Upload and review"
    assert_text "synthetic newer upload failure"
    page.execute_script("window.__releaseOldCancellation()")
    assert_until { page.evaluate_script("window.__oldCancellationFinished") }
    assert_equal "", find("#translation_workspace_source_import_id", visible: :all).value
    assert_text "synthetic newer upload failure"
    assert_equal File.basename(second.path), page.evaluate_script("document.querySelector('#workspace-upload-file').files[0].name")
    assert_not SourceImport.exists?(first_id)
  ensure
    first&.close!
    second&.close!
  end

  private

  def assert_until
    Timeout.timeout(10) { loop { return if yield; Thread.pass } }
  end
end
