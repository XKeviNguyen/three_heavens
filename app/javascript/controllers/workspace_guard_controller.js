import { Controller } from "@hotwired/stimulus"

const SAVE_DELAY_MS = 1000
const RETRY_DELAYS_MS = [2000, 5000, 15000, 30000]
// How long navigation waits for an import or terminology save before it asks
// the user to stay or leave instead.
const PENDING_WAIT_MS = 30000

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
    this.pending = new Set()
    this.retryCount = 0
    this.lastSavedState = this.needsSaveValue ? null : this.state()
    this.settledStatus = this.hasStatusTarget ? this.statusTarget.textContent : ""
    this.currentUrl = window.location.href
    this.currentHistoryState = window.history.state
    this.onBeforeVisit = this.onBeforeVisit.bind(this)
    this.onVisit = this.onVisit.bind(this)
    this.onLoad = this.onLoad.bind(this)
    this.onBeforeUnload = this.onBeforeUnload.bind(this)
    this.onTraverse = this.onTraverse.bind(this)
    this.onPageShow = this.onPageShow.bind(this)
    this.onOnline = this.onOnline.bind(this)
    document.addEventListener("turbo:before-visit", this.onBeforeVisit)
    document.addEventListener("turbo:visit", this.onVisit)
    document.addEventListener("turbo:load", this.onLoad)
    window.addEventListener("beforeunload", this.onBeforeUnload)
    window.addEventListener("history:traverse", this.onTraverse)
    window.addEventListener("pageshow", this.onPageShow)
    window.addEventListener("online", this.onOnline)
    if (this.needsSaveValue) this.scheduleSave()
  }

  disconnect() {
    window.clearTimeout(this.saveTimer)
    document.removeEventListener("turbo:before-visit", this.onBeforeVisit)
    document.removeEventListener("turbo:visit", this.onVisit)
    document.removeEventListener("turbo:load", this.onLoad)
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    window.removeEventListener("history:traverse", this.onTraverse)
    window.removeEventListener("pageshow", this.onPageShow)
    window.removeEventListener("online", this.onOnline)
    this.element.inert = false
    if (this.hasDialogTarget) this.dialogTarget.close?.()
    // A detached page never navigates.
    this.navigation = null
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

  // An import, its removal, or a terminology save changes the form when its
  // request finishes, without typing. Until then the page is not settled.
  trackPending(event) {
    const work = event.detail.work
    this.pending.add(work)
    work.finally(() => this.pending.delete(work))
  }

  busy() {
    return this.pending.size > 0 || this.dirty()
  }

  async settlePending() {
    while (this.pending.size > 0) await Promise.allSettled(this.pending)
    return true
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

  // Waits for pending changes, then saves until the persisted draft matches
  // the form; false means edits are not safe.
  async flush() {
    if (this.pending.size > 0) {
      this.setStatus(this.messagesValue.saving)
      let timer
      const timeout = new Promise(resolve => { timer = window.setTimeout(() => resolve(false), PENDING_WAIT_MS) })
      const settled = await Promise.race([this.settlePending(), timeout])
      window.clearTimeout(timer)
      if (!settled) {
        this.setStatus(this.messagesValue.saveFailed)
        // The work may still finish without changing anything to save; then
        // this failure, unless another message replaced it, no longer applies.
        this.settlePending().then(() => {
          if (!this.busy() && this.statusTarget.textContent === this.messagesValue.saveFailed) this.setStatus(this.settledStatus)
        })
        return false
      }
    }
    let saved = false
    for (let attempt = 0; attempt < 3; attempt++) {
      saved = await this.save()
      if (!saved || !this.dirty()) break
    }
    return saved && !this.busy()
  }

  // The interface-language switch waits for this before navigating, and is
  // abandoned (keeping the page and its edits) unless the draft is saved.
  persistBeforeLocaleSwitch(event) {
    if (this.launching || this.discarding || this.navigation?.phase === "allowed") {
      event.preventDefault()
      return
    }
    this.cancelNavigation()
    event.detail.pending.push(this.flush())
  }

  // Runs before Turbo sees Back or Forward (see history_traversal.js). A
  // traversal claimed here never becomes a Turbo visit, so nothing fetched
  // before the save can change this page, its head, or Turbo's history and
  // snapshot state, whatever the user decides afterwards.
  onTraverse(event) {
    if (this.allowVisit || this.launching) return
    if (this.discarding) {
      // A discard ends in a fresh workspace or keeps this page, so the
      // traversal is never followed.
      event.preventDefault()
      window.history.replaceState(this.currentHistoryState, "", this.currentUrl)
      return
    }
    if (!this.navigation && !this.busy()) return
    event.preventDefault()
    this.navigateAfterSave(window.location.href, "history")
  }

  onBeforeVisit(event) {
    if (this.allowVisit || this.launching) return
    if (!this.discarding && !this.navigation && !this.busy()) return
    event.preventDefault()
    // The saved page is already reloading to the claimed history entry; a
    // newer link replaces that load, even if the reload was stopped.
    if (this.navigation?.phase === "allowed") {
      window.location.assign(event.detail.url)
      return
    }
    // A cancelled visit replaces nothing, so a submission that froze the page
    // for it (such as signing out) leaves the page usable.
    this.element.inert = false
    if (!this.discarding) this.navigateAfterSave(event.detail.url, "visit")
  }

  // Turbo only starts a visit from a settled page (or a launch), and the
  // visit replaces this page when it renders. Freezing the page meanwhile
  // keeps an edit, an import, or a terminology save from starting on a page
  // that is about to be replaced. A visit that renders nothing, such as
  // following a redirect, still ends with turbo:load.
  onVisit() {
    this.visiting = true
    this.element.inert = true
  }

  onLoad() {
    this.visiting = false
    this.element.inert = false
  }

  async navigateAfterSave(destination, kind) {
    // One flush owns navigation. Later Back/Forward events replace its
    // destination, including a return to this very URL. No pre-save response
    // may render a workspace with an obsolete draft identity.
    this.pendingLaunch = null
    if (this.navigation?.phase === "saving") {
      Object.assign(this.navigation, { destination, kind, historyMoved: this.navigation.historyMoved || kind === "history" })
      return
    }
    const navigation = { destination, kind, phase: "saving", historyMoved: kind === "history" }
    this.navigation = navigation
    const saved = await this.flush()
    if (this.discarding || this.navigation !== navigation) return
    if (saved) {
      if (navigation.kind === "history") {
        navigation.phase = "allowed"
        // History already moved to the destination. Load that entry as a
        // fresh document fetched after acknowledgement, preserving the user's
        // latest history position without retaining sensitive draft data in
        // history. Replacing it with its own URL would only scroll to a
        // fragment and claim the traversal again. Edits typed while it loads
        // would be lost, so the page is frozen first.
        this.element.inert = true
        window.location.reload()
      } else {
        this.navigation = null
        window.Turbo.visit(navigation.destination)
      }
    } else {
      this.cancelNavigation()
      this.destination = navigation.destination
      this.element.inert = false
      this.dialogTarget.showModal()
    }
  }

  // Turbo never saw a claimed traversal, so restoring this entry's URL and
  // state is all it takes to keep history consistent with this page.
  cancelNavigation() {
    if (this.navigation?.historyMoved) window.history.replaceState(this.currentHistoryState, "", this.currentUrl)
    this.navigation = null
    this.pendingLaunch = null
  }

  // The back/forward cache can restore this page long after other pages saved
  // newer drafts, which the Turbo cache exemption cannot prevent. Reload the
  // current draft unless the page still guards unsaved edits; those are kept
  // so their saves either succeed or report the conflict. After Leave or a
  // discard the page no longer guards anything, so it always reloads.
  onPageShow(event) {
    if (event.persisted && (this.allowVisit || this.discarding || !this.busy())) window.location.reload()
  }

  onBeforeUnload(event) {
    if (this.allowVisit || this.launching || !this.busy()) return
    event.preventDefault()
    event.returnValue = ""
  }

  async beforeSubmit(event) {
    if (this.discarding) {
      event.preventDefault()
      return
    }
    this.cancelNavigation()
    if (this.allowSubmit || !this.busy()) return
    event.preventDefault()
    const submitter = event.submitter
    // The latest action wins: Back, a link, a language switch or a discard
    // made while this flush runs takes over, and this submission is never sent.
    const launch = this.pendingLaunch = {}
    const saved = await this.flush()
    if (this.pendingLaunch !== launch) return
    if (saved) {
      this.allowSubmit = true
      this.formTarget.requestSubmit(submitter)
      this.allowSubmit = false
    }
  }

  // A Turbo form submission that is not for a frame, such as a launch or the
  // interface-language switch, replaces this page with its response; a
  // rejected launch renders the submitted values. The page is frozen
  // meanwhile so nothing is typed that the response would discard.
  submitStart(event) {
    const submission = event.detail.formSubmission
    if (!this.replacesPage(submission)) return
    this.submission = submission
    // Submitting cancels any visit still loading.
    this.visiting = false
    this.element.inert = true
    if (submission.formElement === this.formTarget && new URL(submission.action).pathname === new URL(this.formTarget.action).pathname) this.launching = true
  }

  // The page stays frozen while something may still replace it: a newer
  // visit that cancelled the submission is loading, or the response is a
  // page that Turbo renders or follows (its redirect visit starts after this
  // event). Otherwise, including a Turbo Stream response, the page stays and
  // is editable again. A visit this guard cancels unfreezes the page in
  // onBeforeVisit.
  async submitEnd(event) {
    if (event.detail.formSubmission !== this.submission) return
    this.submission = null
    const response = event.detail.fetchResponse
    if (this.visiting) return
    if (response && !response.contentType?.startsWith("text/vnd.turbo-stream.html") && await response.responseHTML) return
    // A visit or another submission may have started while the body was read.
    if (this.visiting || this.submission) return
    this.launching = false
    this.element.inert = false
  }

  // Turbo sends a form inside a frame, or one that names a frame, to that frame.
  replacesPage({ formElement, submitter }) {
    const frame = submitter?.getAttribute("data-turbo-frame") || formElement.getAttribute("data-turbo-frame")
    return frame ? frame === "_top" : !formElement.closest("turbo-frame")
  }

  stay() {
    this.destination = null
    this.dialogTarget.close()
  }

  leave() {
    const destination = this.destination
    this.allowVisit = true
    this.dialogTarget.close()
    // Assigning a URL that differs only by its fragment would keep this page.
    if (new URL(destination).href.split("#")[0] === window.location.href.split("#")[0]) window.location.reload()
    else window.location.assign(destination)
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
