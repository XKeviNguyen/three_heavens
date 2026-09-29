import { Controller } from "@hotwired/stimulus"
import { randomHex } from "controllers/random_identifier"

const SAVE_DELAY_MS = 1000
const RETRY_DELAYS_MS = [2000, 5000, 15000, 30000]
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
    // One editor per page load. Only this random identifier and save counter
    // live in memory; the draft itself is stored encrypted on the server.
    this.editorId = randomHex(16)
    this.sequence = 0
    this.unacknowledged = null
    this.retryCount = 0
    this.lastSavedState = this.needsSaveValue ? null : this.state()
    this.settledStatus = this.hasStatusTarget ? this.statusTarget.textContent : ""
    this.currentUrl = window.location.href
    this.currentHistoryState = window.history.state
    this.onBeforeRender = this.onBeforeRender.bind(this)
    this.onBeforeVisit = this.onBeforeVisit.bind(this)
    this.onBeforeUnload = this.onBeforeUnload.bind(this)
    this.onOnline = this.onOnline.bind(this)
    document.addEventListener("turbo:before-render", this.onBeforeRender)
    document.addEventListener("turbo:before-visit", this.onBeforeVisit)
    window.addEventListener("beforeunload", this.onBeforeUnload)
    window.addEventListener("online", this.onOnline)
    if (this.needsSaveValue) this.scheduleSave()
  }

  disconnect() {
    window.clearTimeout(this.saveTimer)
    document.removeEventListener("turbo:before-render", this.onBeforeRender)
    document.removeEventListener("turbo:before-visit", this.onBeforeVisit)
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    window.removeEventListener("online", this.onOnline)
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

  // Content stays unsaved until the server acknowledges it. A save whose
  // outcome is unknown may have stored older or newer content than the page
  // shows, so it keeps the page dirty even if the fields are reverted.
  dirty() {
    return this.unacknowledged !== null || this.state() !== this.lastSavedState
  }

  // Typing only restarts the debounce. The form is serialized once, when the
  // save runs, never per keystroke, so a large source stays responsive.
  changed(event) {
    if (this.launching || this.discarding) return
    // Only draft fields matter: typing in the model search or the terminology
    // sheet bubbles here too but changes nothing that is saved.
    if ((event?.type === "input" || event?.type === "change") && !event.target?.name?.startsWith("translation_workspace[")) return
    this.retryCount = 0
    window.clearTimeout(this.saveTimer)
    if (!this.editPending) {
      this.editPending = true
      this.setStatus(this.messagesValue.saving)
    }
    this.saveTimer = window.setTimeout(() => this.save(), SAVE_DELAY_MS)
  }

  scheduleSave() {
    window.clearTimeout(this.saveTimer)
    if (this.discarding || !this.dirty()) return
    this.setStatus(this.messagesValue.saving)
    this.saveTimer = window.setTimeout(() => this.save(), SAVE_DELAY_MS)
  }

  async save() {
    if (this.discarding) return false
    window.clearTimeout(this.saveTimer)
    // One save at a time, so sequence numbers reach the server in order.
    while (this.saving) {
      try { await this.saving } catch { return false }
    }

    this.editPending = false
    const workspace = this.payload()
    const snapshot = JSON.stringify(workspace)
    if (this.unacknowledged === null && snapshot === this.lastSavedState) {
      this.setStatus(this.settledStatus)
      return true
    }
    // Resending unchanged content whose outcome is unknown is a replay of the
    // same save; any other content is a newer save.
    const sequence = this.unacknowledged?.snapshot === snapshot ? this.unacknowledged.sequence : ++this.sequence
    this.unacknowledged = { sequence, snapshot }
    this.setStatus(this.messagesValue.saving)
    const saving = this.persist(workspace, sequence)
    this.saving = saving
    try {
      const result = await saving
      if (result.sequence !== sequence) throw new Error("draft save was not acknowledged")

      this.unacknowledged = null
      this.retryCount = 0
      this.draftIdValue = result.id
      this.versionValue = result.version
      this.formTarget.elements.translation_workspace_draft_id.value = result.id
      this.formTarget.elements.translation_workspace_draft_version.value = result.version
      this.lastSavedState = snapshot
      this.settledStatus = this.messagesValue.saved
      // Edits made while this save was in flight have their own timer.
      if (!this.editPending) this.setStatus(this.messagesValue.saved)
      return true
    } catch (error) {
      this.setStatus(error.conflict ? this.messagesValue.saveConflict : this.messagesValue.saveFailed)
      if (!error.final) this.scheduleRetry()
      return false
    } finally {
      if (this.saving === saving) this.saving = null
    }
  }

  // A failed request may still have been saved; retrying resolves that with
  // the same editor identity instead of guessing. Retries are bounded; going
  // back online or editing again starts a new round. Conflicts and rejected
  // content are final.
  scheduleRetry() {
    if (this.discarding || this.retryCount >= RETRY_DELAYS_MS.length) return
    const delay = RETRY_DELAYS_MS[this.retryCount]
    this.retryCount += 1
    window.clearTimeout(this.saveTimer)
    this.saveTimer = window.setTimeout(() => this.save(), delay)
  }

  onOnline() {
    if (this.launching || this.discarding || !this.dirty()) return
    this.retryCount = 0
    this.scheduleSave()
  }

  async persist(workspace, sequence) {
    const response = await fetch(this.saveUrlValue, {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": this.csrfToken() },
      body: JSON.stringify({
        project_id: this.formTarget.elements["translation_workspace[project_id]"]?.value || "",
        draft_id: this.draftIdValue || "",
        version: this.draftIdValue ? this.versionValue : "",
        editor_id: this.editorId,
        sequence,
        workspace
      })
    })
    if (!response.ok) {
      const error = new Error("draft save failed")
      error.conflict = response.status === 409 || response.status === 404
      error.final = response.status < 500
      throw error
    }
    return response.json()
  }

  // Saves until the persisted draft matches the form; false means edits are not safe.
  async flush() {
    let saved = false
    for (let attempt = 0; attempt < 3; attempt++) {
      saved = await this.save()
      if (!saved || !this.dirty()) break
    }
    return saved && !this.dirty()
  }

  // The interface-language switch waits for this before navigating, and is
  // abandoned (keeping the page and its edits) unless the draft is saved.
  persistBeforeLocaleSwitch(event) {
    if (this.launching) {
      event.preventDefault()
      return
    }
    event.detail.pending.push(this.flush())
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
    const saved = await this.flush()
    this.navigating = false
    if (saved) {
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
    if (await this.flush()) {
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
    // Discarding is terminal for this page: no timer, retry, or reconnect may
    // save again, or a late save could recreate the discarded draft.
    this.discarding = true
    window.clearTimeout(this.saveTimer)
    while (this.saving) {
      try { await this.saving } catch {}
    }
    window.clearTimeout(this.saveTimer)
    // A save whose response was lost may have created the draft, so this
    // editor asks the server to discard even without a known draft identity.
    if (this.draftIdValue || this.sequence > 0) {
      const response = await fetch(this.saveUrlValue, {
        method: "DELETE", credentials: "same-origin",
        headers: { Accept: "application/json", "X-CSRF-Token": this.csrfToken() },
        body: new URLSearchParams({
          project_id: this.formTarget.elements["translation_workspace[project_id]"]?.value || "",
          draft_id: this.draftIdValue || "",
          version: this.draftIdValue ? this.versionValue : "",
          editor_id: this.editorId
        })
      }).catch(() => null)
      if (!response || (!response.ok && response.status !== 404)) {
        this.discarding = false
        this.setStatus(response?.status === 409 ? this.messagesValue.discardConflict : this.messagesValue.discardFailed)
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
