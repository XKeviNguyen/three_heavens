import { Controller } from "@hotwired/stimulus"
import { randomHex } from "controllers/random_identifier"

export default class extends Controller {
  static targets = ["file", "button", "message", "import", "filename", "metadata"]
  static values = { replayLease: String, projectId: String, createUrl: String, messages: Object }

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
    }
    const requestKey = this.requestKey
    this.buttonTarget.disabled = true
    this.messageTarget.textContent = this.messagesValue.extracting
    const body = new FormData()
    body.append("source_import[source_file]", file)
    body.append("source_import[request_key]", this.requestKey)
    if (this.projectIdValue) body.append("source_import[project_id]", this.projectIdValue)

    try {
      const response = await fetch(this.createUrlValue, {
        method: "POST", body, credentials: "same-origin",
        headers: { Accept: "application/json", "X-CSRF-Token": this.csrfToken() }
      })
      const result = await response.json().catch(() => ({}))
      if (this.requestKey !== requestKey) return
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
      if (!this.field("document_title").value.trim()) {
        this.field("document_title").value = result.original_filename.replace(/\.[^.]+$/, "")
      }
      this.filenameTarget.textContent = result.original_filename
      this.metadataTarget.textContent = `${result.imported_format.toUpperCase()} · ${(result.byte_size / 1024).toFixed(0)} KiB`
      document.querySelector("label[for='translation_workspace_source_text']").textContent = this.messagesValue.reviewedSource
      this.importTarget.classList.remove("hidden")
      this.messageTarget.textContent = this.messagesValue.imported
      this.element.querySelector("[data-source-mode-target='pasteTab']").click()
      this.field("source_text").focus()
      this.element.dispatchEvent(new Event("input", { bubbles: true }))
    } catch (error) {
      if (this.requestKey === requestKey) this.messageTarget.textContent = error.message || this.messagesValue.importFailed
    } finally {
      if (this.requestKey === requestKey) this.buttonTarget.disabled = false
    }
  }

  async remove() {
    const id = this.field("source_import_id").value
    if (!id) return
    const requestKey = this.requestKey
    const selectedFile = this.fileTarget.files[0]

    try {
      const response = await fetch(`/source_imports/${encodeURIComponent(id)}.json`, {
        method: "DELETE", credentials: "same-origin",
        headers: { Accept: "application/json", "X-CSRF-Token": this.csrfToken() }
      })
      if (!response.ok) throw new Error()
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
    }
  }

  field(name) {
    return document.getElementById(`translation_workspace_${name}`)
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
