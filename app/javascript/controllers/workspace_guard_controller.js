import { Controller } from "@hotwired/stimulus"

const SAVE_DELAY_MS = 1000
const RETRY_DELAYS_MS = [2000, 5000, 15000, 30000]

export default class extends Controller {
  static targets = ["form", "dialog", "status"]
  // The server's draft field lists, so only fields it stores count as edits.
  static values = { editorId: String, sequence: Number, saveUrl: String, resetUrl: String, draftId: String, version: Number, needsSave: Boolean, messages: Object, scalarFields: Array, arrayFields: Array }

  connect() {
    // One editor per page load. Only this random identifier and save counter
    // stay on this page, including Stimulus reconnects and Turbo snapshots.
    // The draft itself is stored encrypted on the server.
    this.editorId = this.editorIdValue
    this.sequence = this.sequenceValue
    this.unacknowledged = null
    this.retryCount = 0
    this.lastSavedState = this.needsSaveValue ? null : this.state()
    this.settledStatus = this.hasStatusTarget ? this.statusTarget.textContent : ""
    this.currentUrl = window.location.href
    this.currentHistoryState = window.history.state
    this.onBeforeRender = this.onBeforeRender.bind(this)
    this.onBeforeVisit = this.onBeforeVisit.bind(this)
    this.onBeforeUnload = this.onBeforeUnload.bind(this)
    this.onPopState = this.onPopState.bind(this)
    this.onOnline = this.onOnline.bind(this)
    document.addEventListener("turbo:before-render", this.onBeforeRender)
    document.addEventListener("turbo:before-visit", this.onBeforeVisit)
    window.addEventListener("beforeunload", this.onBeforeUnload)
    window.addEventListener("popstate", this.onPopState, true)
    window.addEventListener("online", this.onOnline)
    if (this.needsSaveValue) this.scheduleSave()
  }

  disconnect() {
    window.clearTimeout(this.saveTimer)
    document.removeEventListener("turbo:before-render", this.onBeforeRender)
    document.removeEventListener("turbo:before-visit", this.onBeforeVisit)
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    window.removeEventListener("popstate", this.onPopState, true)
    window.removeEventListener("online", this.onOnline)
    if (this.hasDialogTarget) this.dialogTarget.close?.()
  }

  payload() {
    const data = new FormData(this.formTarget)
    const workspace = {}
    for (const field of this.scalarFieldsValue) workspace[field] = data.get("translation_workspace[" + field + "]") || ""
    for (const field of this.arrayFieldsValue) workspace[field] = data.getAll("translation_workspace[" + field + "][]").filter(value => typeof value === "string" && value)
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
    if (!this.draftChange(event)) return
    this.retryCount = 0
    this.needsSaveValue = true
    window.clearTimeout(this.saveTimer)
    if (!this.editPending) {
      this.editPending = true
      this.setStatus(this.messagesValue.saving)
    }
    this.saveTimer = window.setTimeout(() => this.save(), SAVE_DELAY_MS)
  }

  // Only controls in the saved draft count. The model search and filters,
  // the terminology sheet, and the per-launch automatic confirmation, which
  // is deliberately never saved, change nothing that autosave stores. Events
  // dispatched on containers, such as an import or its removal, do count.
  draftChange(event) {
    const target = event?.target
    if (!target || (event.type !== "input" && event.type !== "change")) return true
    if (target.closest("dialog")) return false
    if (target.matches("input, select, textarea")) return this.draftFieldNames.has(target.name)
    return true
  }

  get draftFieldNames() {
    this.fieldNames ||= new Set([
      ...this.scalarFieldsValue.map(field => "translation_workspace[" + field + "]"),
      ...this.arrayFieldsValue.map(field => "translation_workspace[" + field + "][]")
    ])
    return this.fieldNames
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

    if (this.discarding) return false
    this.editPending = false
    const workspace = this.payload()
    const snapshot = JSON.stringify(workspace)
    if (this.unacknowledged === null && snapshot === this.lastSavedState) {
      this.needsSaveValue = false
      this.setStatus(this.settledStatus)
      return true
    }
    // Resending unchanged content whose outcome is unknown is a replay of the
    // same save; any other content is a newer save.
    const sequence = this.unacknowledged?.snapshot === snapshot ? this.unacknowledged.sequence : ++this.sequence
    this.sequenceValue = this.sequence
    this.needsSaveValue = true
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
      this.needsSaveValue = !!this.editPending
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
    if (this.launching || this.discarding) {
      event.preventDefault()
      return
    }
    this.cancelNavigation()
    event.detail.pending.push(this.flush())
  }

  onPopState() {
    if (this.allowVisit || this.launching || this.discarding) return
    if (this.navigation || this.dirty()) this.navigateAfterSave(window.location.href, "history")
  }

  onBeforeVisit(event) {
    if (this.allowVisit || this.launching) return
    if (!this.discarding && !this.navigation && !this.dirty()) return
    event.preventDefault()
    if (!this.discarding) this.navigateAfterSave(event.detail.url, "visit")
  }

  onBeforeRender(event) {
    if (this.allowVisit || this.launching) return
    if (!this.discarding && !this.navigation && (!this.dirty() || window.location.href === this.currentUrl)) return
    // Finish Turbo's render lifecycle without inserting a response fetched
    // before the save. Leaving its render promise suspended would block a
    // later visit after Stay, a failed discard, or a failed save.
    event.detail.render = () => {}
    if (["failed", "cancelled"].includes(this.navigation?.phase)) {
      this.navigation = null
      return
    }
    if (!this.discarding && !this.navigation) this.navigateAfterSave(window.location.href, "history")
  }

  async navigateAfterSave(destination, kind) {
    // One flush owns navigation. Later Back/Forward events replace its
    // destination, including a return to this very URL. No pre-save response
    // may render a workspace with an obsolete draft identity.
    if (this.navigation?.phase === "saving") {
      Object.assign(this.navigation, { destination, kind })
      return
    }
    const navigation = { destination, kind, phase: "saving" }
    this.navigation = navigation
    const saved = await this.flush()
    if (this.discarding || this.navigation !== navigation || navigation.phase !== "saving") return
    if (saved) {
      if (navigation.kind === "history") {
        navigation.phase = "allowed"
        // History already moved. Replace that entry with a fresh document
        // fetched after acknowledgement, preserving the user's latest
        // history position without retaining sensitive draft data in history.
        window.location.replace(navigation.destination)
      } else {
        this.navigation = null
        window.Turbo.visit(navigation.destination)
      }
    } else {
      // Keep ownership until the outstanding history response is ignored,
      // even though the visible URL is restored before it arrives.
      this.navigation = navigation.kind === "history" ? Object.assign(navigation, { phase: "failed" }) : null
      if (navigation.kind === "history") window.history.replaceState(this.currentHistoryState, "", this.currentUrl)
      this.destination = navigation.destination
      this.dialogTarget.showModal()
    }
  }

  cancelNavigation() {
    if (this.navigation?.kind === "history") {
      window.history.replaceState(this.currentHistoryState, "", this.currentUrl)
      // The old history GET can arrive after Discard fails or a locale flush
      // finishes. Retain its provenance until its render is ignored.
      this.navigation.phase = "cancelled"
    } else {
      this.navigation = null
    }
  }

  onBeforeUnload(event) {
    if (this.allowVisit || this.launching || !this.dirty()) return
    event.preventDefault()
    event.returnValue = ""
  }

  async beforeSubmit(event) {
    if (this.discarding) {
      event.preventDefault()
      return
    }
    this.cancelNavigation()
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
    this.cancelNavigation()
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
          editor_id: this.editorId,
          sequence: this.sequence
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
