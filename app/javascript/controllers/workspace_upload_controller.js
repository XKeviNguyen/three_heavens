import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["file", "button", "message", "import", "filename", "metadata"]
  static values = { projectId: String, createUrl: String, messages: Object }

  async upload() {
    const file = this.fileTarget.files[0]
    if (!file) {
      this.messageTarget.textContent = this.messagesValue.chooseFile
      return
    }

    this.buttonTarget.disabled = true
    this.messageTarget.textContent = this.messagesValue.extracting
    const body = new FormData()
    body.append("source_import[source_file]", file)
    if (this.projectIdValue) body.append("source_import[project_id]", this.projectIdValue)

    try {
      const response = await fetch(this.createUrlValue, {
        method: "POST", body, credentials: "same-origin",
        headers: { Accept: "application/json", "X-CSRF-Token": this.csrfToken() }
      })
      const result = await response.json()
      if (!response.ok) throw new Error(result.error || this.messagesValue.importFailed)

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
      this.messageTarget.textContent = error.message || this.messagesValue.importFailed
    } finally {
      this.buttonTarget.disabled = false
    }
  }

  async remove() {
    const id = this.field("source_import_id").value
    if (!id) return

    try {
      const response = await fetch(`/source_imports/${encodeURIComponent(id)}.json`, {
        method: "DELETE", credentials: "same-origin",
        headers: { Accept: "application/json", "X-CSRF-Token": this.csrfToken() }
      })
      if (!response.ok) throw new Error()
      this.field("source_import_id").value = ""
      this.field("source_import_project_token").value = ""
      this.importTarget.classList.add("hidden")
      document.querySelector("label[for='translation_workspace_source_text']").textContent = this.messagesValue.sourceText
      this.fileTarget.value = ""
      this.messageTarget.textContent = this.messagesValue.removed
      this.element.dispatchEvent(new Event("input", { bubbles: true }))
    } catch {
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
