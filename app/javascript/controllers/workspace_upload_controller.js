import { Controller } from "@hotwired/stimulus"
import { randomHex } from "controllers/random_identifier"

export default class extends Controller {
  static targets = ["file", "button", "message", "import", "filename", "metadata"]
  static values = { replayLease: String, projectId: String, createUrl: String, messages: Object }

  initialize() {
    this.sourceGeneration = 0
    this.titleGeneration = 0
  }

  disconnect() {
    this.invalidateSource()
  }

  changed(event) {
    if (event.target === this.field("document_title")) {
      this.titleGeneration += 1
    } else if (event.target === this.field("source_text") || event.target === this.fileTarget) {
      this.invalidateSource()
      if (event.target === this.fileTarget) this.buttonTarget.disabled = false
    }
  }

  invalidateSource() {
    this.sourceGeneration += 1
    this.messageTarget.textContent = ""
  }

  ownsSource(requestKey, generation) {
    return this.element.isConnected && this.requestKey === requestKey && this.sourceGeneration === generation
  }

  async upload() {
    const file = this.fileTarget.files[0]
    if (!file) {
      this.messageTarget.textContent = this.messagesValue.chooseFile
      return
    }

    // Uploading the same chosen file again (a retry or double click) is the
    // same action, so the server returns its import instead of a second copy.
    if (this.uploadedFile !== file) {
      this.uploadedFile = file
      this.requestKey = `${this.replayLeaseValue}.${randomHex(16)}`
      // Ownership belongs to the action, not each delivery. A transport retry
      // must not regain authority after the user superseded that action.
      this.uploadSourceGeneration = ++this.sourceGeneration
      this.uploadTitleGeneration = this.titleGeneration
    }
    const requestKey = this.requestKey
    const generation = this.uploadSourceGeneration
    const titleGeneration = this.uploadTitleGeneration
    this.buttonTarget.disabled = true
    this.messageTarget.textContent = this.messagesValue.extracting
    const body = new FormData()
    body.append("source_import[source_file]", file)
    body.append("source_import[request_key]", this.requestKey)
    if (this.projectIdValue) body.append("source_import[project_id]", this.projectIdValue)

    const settle = this.announcePending()
    try {
      const response = await fetch(this.createUrlValue, {
        method: "POST", body, credentials: "same-origin",
        headers: { Accept: "application/json", "X-CSRF-Token": this.csrfToken() }
      })
      if (!this.ownsSource(requestKey, generation)) return
      const result = await response.json().catch(() => ({}))
      if (!this.ownsSource(requestKey, generation)) return
      if (!response.ok) {
        // Admission and an in-progress delivery leave the action unresolved.
        // A terminal validation/extraction failure lets an explicit retry
        // begin a new action; ambiguous transport outcomes keep this key.
        if (response.status < 500 && response.status !== 429 && result.code !== "import_in_progress") this.uploadedFile = null
        throw new Error(result.error || this.messagesValue.importFailed)
      }

      this.field("source_import_id").value = result.id
      this.field("source_import_project_token").value = result.project_binding || ""
      this.field("source_text").value = result.extracted_text
      if (this.titleGeneration === titleGeneration && !this.field("document_title").value.trim()) {
        this.field("document_title").value = result.original_filename.replace(/\.[^.]+$/, "")
      }
      this.filenameTarget.textContent = result.original_filename
      this.metadataTarget.textContent = `${result.imported_format.toUpperCase()} · ${(result.byte_size / 1024).toFixed(0)} KiB`
      document.querySelector("label[for='translation_workspace_source_text']").textContent = this.messagesValue.reviewedSource
      this.importTarget.classList.remove("hidden")
      this.element.querySelector("[data-source-mode-target='pasteTab']").click()
      this.messageTarget.textContent = this.messagesValue.imported
      this.field("source_text").focus()
      this.element.dispatchEvent(new Event("input", { bubbles: true }))
    } catch (error) {
      if (this.ownsSource(requestKey, generation)) this.messageTarget.textContent = error.message || this.messagesValue.importFailed
    } finally {
      if (this.requestKey === requestKey) {
        this.buttonTarget.disabled = false
        if (!this.ownsSource(requestKey, generation) && this.messageTarget.textContent === this.messagesValue.extracting) this.messageTarget.textContent = ""
      }
      settle()
    }
  }

  async remove() {
    this.invalidateSource()
    const id = this.field("source_import_id").value
    if (!id) return
    const requestKey = this.requestKey
    const selectedFile = this.fileTarget.files[0]

    const settle = this.announcePending()
    try {
      const response = await fetch(`/source_imports/${encodeURIComponent(id)}.json`, {
        method: "DELETE", credentials: "same-origin",
        headers: { Accept: "application/json", "X-CSRF-Token": this.csrfToken() }
      })
      if (!response.ok && response.status !== 404) throw new Error()
      if (this.field("source_import_id").value !== id) return
      const currentAction = this.requestKey === requestKey
      if (currentAction) {
        this.requestKey = null
        this.uploadedFile = null
        this.buttonTarget.disabled = false
      }
      this.field("source_import_id").value = ""
      this.field("source_import_project_token").value = ""
      this.importTarget.classList.add("hidden")
      document.querySelector("label[for='translation_workspace_source_text']").textContent = this.messagesValue.sourceText
      if (currentAction && this.fileTarget.files[0] === selectedFile) this.fileTarget.value = ""
      if (currentAction) this.messageTarget.textContent = this.messagesValue.removed
      this.element.dispatchEvent(new Event("input", { bubbles: true }))
    } catch {
      if (this.field("source_import_id").value !== id || this.requestKey !== requestKey) return
      this.messageTarget.textContent = this.messagesValue.removeFailed
    } finally {
      settle()
    }
  }

  // The workspace waits for this request before it saves and navigates, so
  // the import or its removal reaches the draft.
  announcePending() {
    let settle
    const work = new Promise(resolve => { settle = resolve })
    this.element.dispatchEvent(new CustomEvent("workspace:pending", { bubbles: true, detail: { work } }))
    return settle
  }

  field(name) {
    return document.getElementById(`translation_workspace_${name}`)
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
