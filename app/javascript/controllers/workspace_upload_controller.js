import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["file", "button", "message", "import", "filename"]
  static values = { projectId: String, createUrl: String }

  async upload() {
    const file = this.fileTarget.files[0]
    if (!file) {
      this.messageTarget.textContent = "Choose a TXT, Markdown, or DOCX file."
      return
    }

    this.buttonTarget.disabled = true
    this.messageTarget.textContent = "Extracting source text…"
    const body = new FormData()
    body.append("source_import[source_file]", file)
    if (this.projectIdValue) body.append("source_import[project_id]", this.projectIdValue)

    try {
      const response = await fetch(this.createUrlValue, {
        method: "POST", body, credentials: "same-origin",
        headers: { Accept: "application/json", "X-CSRF-Token": this.csrfToken() }
      })
      const result = await response.json()
      if (!response.ok) throw new Error(result.error || "The file could not be imported.")

      this.field("source_import_id").value = result.id
      this.field("source_import_project_token").value = result.project_binding || ""
      this.field("source_text").value = result.extracted_text
      if (!this.field("document_title").value.trim()) {
        this.field("document_title").value = result.original_filename.replace(/\.[^.]+$/, "")
      }
      this.filenameTarget.textContent = result.original_filename
      document.querySelector("label[for='translation_workspace_source_text']").textContent = "Reviewed source text"
      this.importTarget.classList.remove("hidden")
      this.messageTarget.textContent = "Source text extracted. Review it in the editor."
      this.element.querySelector("[data-source-mode-target='pasteTab']").click()
      this.field("source_text").focus()
      this.element.dispatchEvent(new Event("input", { bubbles: true }))
    } catch (error) {
      this.messageTarget.textContent = error.message || "The file could not be imported."
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
      document.querySelector("label[for='translation_workspace_source_text']").textContent = "Source text"
      this.fileTarget.value = ""
      this.messageTarget.textContent = "Import removed. The reviewed text remains in the editor."
      this.element.dispatchEvent(new Event("input", { bubbles: true }))
    } catch {
      this.messageTarget.textContent = "The import could not be removed. Try again."
    }
  }

  field(name) {
    return document.getElementById(`translation_workspace_${name}`)
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
