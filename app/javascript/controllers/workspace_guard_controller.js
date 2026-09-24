import { Controller } from "@hotwired/stimulus"

const SAVE_DELAY_MS = 1000
const SCALARS = [
  "project_name", "source_language", "target_language", "document_title",
  "source_text", "source_import_id", "experiment_name", "instruction_prompt",
  "workflow_mode", "workflow_profile_revision_id", "glossary_revision_id",
  "methodology_profile_revision_id", "guidance_preference"
]
const ARRAYS = ["model_ids", "model_identifiers", "translation_reference_revision_ids"]

export default class extends Controller {
  static targets = ["form", "dialog", "status"]
  static values = { saveUrl: String, resetUrl: String, draftId: String, version: Number, needsSave: Boolean, messages: Object }

  connect() {
    this.lastSavedState = this.needsSaveValue ? null : this.state()
    this.currentUrl = window.location.href
    this.currentHistoryState = window.history.state
    this.onBeforeRender = this.onBeforeRender.bind(this)
    this.onBeforeVisit = this.onBeforeVisit.bind(this)
    this.onBeforeUnload = this.onBeforeUnload.bind(this)
    document.addEventListener("turbo:before-render", this.onBeforeRender)
    document.addEventListener("turbo:before-visit", this.onBeforeVisit)
    window.addEventListener("beforeunload", this.onBeforeUnload)
    if (this.needsSaveValue) this.scheduleSave()
  }

  disconnect() {
    window.clearTimeout(this.saveTimer)
    document.removeEventListener("turbo:before-render", this.onBeforeRender)
    document.removeEventListener("turbo:before-visit", this.onBeforeVisit)
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    if (this.hasDialogTarget) this.dialogTarget.close?.()
  }

  payload() {
    const data = new FormData(this.formTarget)
    const workspace = {}
    for (const field of SCALARS) workspace[field] = data.get("translation_workspace[" + field + "]") || ""
    for (const field of ARRAYS) workspace[field] = data.getAll("translation_workspace[" + field + "][]").filter(value => typeof value === "string" && value)
    return workspace
  }

  state() {
    return JSON.stringify(this.payload())
  }

  dirty() {
    return this.state() !== this.lastSavedState
  }

  changed() {
    if (this.launching) return
    this.scheduleSave()
  }

  scheduleSave() {
    window.clearTimeout(this.saveTimer)
    if (!this.dirty()) return
    this.setStatus(this.messagesValue.saving)
    this.saveTimer = window.setTimeout(() => this.save(), SAVE_DELAY_MS)
  }

  async save() {
    window.clearTimeout(this.saveTimer)
    if (!this.dirty()) return true
    if (this.saving) {
      try { await this.saving } catch { return false }
      if (!this.dirty()) return true
    }

    const workspace = this.payload()
    const snapshot = JSON.stringify(workspace)
    this.setStatus(this.messagesValue.saving)
    this.saving = this.persist(workspace)
    try {
      const result = await this.saving
      this.draftIdValue = result.id
      this.versionValue = result.version
      this.formTarget.elements.translation_workspace_draft_id.value = result.id
      this.formTarget.elements.translation_workspace_draft_version.value = result.version
      this.lastSavedState = snapshot
      if (this.dirty()) this.scheduleSave()
      else this.setStatus(this.messagesValue.saved)
      return true
    } catch (error) {
      this.setStatus(error.conflict ? this.messagesValue.saveConflict : this.messagesValue.saveFailed)
      return false
    } finally {
      this.saving = null
    }
  }

  async persist(workspace) {
    const response = await fetch(this.saveUrlValue, {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": this.csrfToken() },
      body: JSON.stringify({
        project_id: this.formTarget.elements["translation_workspace[project_id]"]?.value || "",
        draft_id: this.draftIdValue || "",
        version: this.draftIdValue ? this.versionValue : "",
        workspace
      })
    })
    if (!response.ok) {
      const error = new Error("draft save failed")
      error.conflict = response.status === 409
      throw error
    }
    return response.json()
  }

  onBeforeVisit(event) {
    if (this.allowVisit || this.launching || !this.dirty()) return
    event.preventDefault()
    this.navigateAfterSave(event.detail.url)
  }

  onBeforeRender(event) {
    if (this.allowVisit || this.launching || !this.dirty() || window.location.href === this.currentUrl) return
    event.preventDefault()
    const destination = window.location.href
    this.pendingRender = event.detail.resume
    this.navigateAfterSave(destination, "render")
  }

  async navigateAfterSave(destination, action) {
    if (this.navigating) return
    this.navigating = true
    let saved = false
    for (let attempt = 0; attempt < 3; attempt++) {
      saved = await this.save()
      if (!saved || !this.dirty()) break
    }
    this.navigating = false
    if (saved && !this.dirty()) {
      this.allowVisit = true
      if (action === "render") this.pendingRender()
      else window.Turbo.visit(destination)
    } else {
      if (action === "render") window.history.pushState(this.currentHistoryState, "", this.currentUrl)
      this.destination = destination
      this.dialogTarget.showModal()
    }
  }

  onBeforeUnload(event) {
    if (this.allowVisit || this.launching || !this.dirty()) return
    event.preventDefault()
    event.returnValue = ""
  }

  async beforeSubmit(event) {
    if (this.allowSubmit || !this.dirty()) return
    event.preventDefault()
    const submitter = event.submitter
    let saved = false
    for (let attempt = 0; attempt < 3; attempt++) {
      saved = await this.save()
      if (!saved || !this.dirty()) break
    }
    if (saved && !this.dirty()) {
      this.allowSubmit = true
      this.formTarget.requestSubmit(submitter)
      this.allowSubmit = false
    }
  }

  submitStart(event) {
    if (event.target !== this.formTarget) return
    const action = event.detail.formSubmission?.submitter?.formAction || this.formTarget.action
    if (new URL(action).pathname === new URL(this.formTarget.action).pathname) this.launching = true
  }

  submitEnd(event) {
    if (event.target === this.formTarget && !event.detail.success) this.launching = false
  }

  stay() {
    this.destination = null
    this.dialogTarget.close()
  }

  leave() {
    const destination = this.destination
    this.allowVisit = true
    this.dialogTarget.close()
    window.location.assign(destination)
  }

  async discard() {
    if (!window.confirm(this.messagesValue.discardConfirm)) return
    if (this.draftIdValue) {
      const response = await fetch(this.saveUrlValue, {
        method: "DELETE", credentials: "same-origin",
        headers: { Accept: "application/json", "X-CSRF-Token": this.csrfToken() },
        body: new URLSearchParams({
          project_id: this.formTarget.elements["translation_workspace[project_id]"]?.value || "",
          draft_id: this.draftIdValue,
          version: this.versionValue
        })
      })
      if (!response.ok) {
        this.setStatus(response.status === 409 ? this.messagesValue.discardConflict : this.messagesValue.discardFailed)
        return
      }
    }
    this.allowVisit = true
    window.location.assign(this.resetUrlValue)
  }

  setStatus(message) {
    this.statusTarget.textContent = message
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
