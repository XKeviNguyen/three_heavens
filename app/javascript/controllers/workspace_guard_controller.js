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
    this.refusedDiscard = null
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
    // After Leave nothing is saved again; signing out may already have ended the session.
    if (this.discarding || this.allowVisit) return false
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
      this.setStatus(this.savedStatus)
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
      this.finallyRejected = null
      this.retryCount = 0
      this.draftIdValue = result.id
      this.versionValue = result.version
      this.formTarget.elements.translation_workspace_draft_id.value = result.id
      this.formTarget.elements.translation_workspace_draft_version.value = result.version
      this.lastSavedState = snapshot
      this.needsSaveValue = !!this.editPending
      this.settledStatus = this.messagesValue.saved
      // Edits made while this save was in flight have their own timer.
      if (!this.editPending) this.setStatus(this.savedStatus)
      return true
    } catch (error) {
      this.setStatus(error.conflict ? this.messagesValue.saveConflict : this.messagesValue.saveFailed)
      if (error.final) this.finallyRejected = snapshot
      else this.scheduleRetry()
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
    if (this.discarding || this.allowVisit || this.retryCount >= RETRY_DELAYS_MS.length) return
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

  // Until work that outlasted a wait ends (flush), the draft lacks its result,
  // so a save meanwhile keeps reporting the failure rather than "saved". A
  // refused discard stays reported until the next edit, even as the edits
  // typed during it are saved.
  get savedStatus() {
    if (this.pendingWaitFailed) return this.messagesValue.saveFailed
    return this.refusedDiscard || this.settledStatus
  }

  // Waits for pending changes, then saves until the persisted draft matches
  // the form; false means edits are not safe.
  async flush() {
    if (this.pending.size > 0) {
      // Edits already typed are saved first, so no queued save can report
      // "saved" over a wait that fails; the pending work may change the form
      // again, which the loop below saves.
      if (!await this.save()) return false
      this.setStatus(this.messagesValue.saving)
      let timer
      const wait = this.pendingWait = {}
      const timeout = new Promise(resolve => { timer = window.setTimeout(() => resolve(false), PENDING_WAIT_MS) })
      const settled = await Promise.race([this.settlePending(), timeout])
      window.clearTimeout(timer)
      if (!settled) {
        // A newer flush still waiting for the same work reports the outcome.
        if (this.pendingWait !== wait) return false
        this.pendingWaitFailed = true
        this.setStatus(this.messagesValue.saveFailed)
        // The work may still finish without changing anything to save; then
        // this failure, unless another message replaced it, no longer applies.
        this.settlePending().then(() => {
          this.pendingWaitFailed = false
          if (!this.busy() && this.statusTarget.textContent === this.messagesValue.saveFailed) this.setStatus(this.savedStatus)
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
    // Nothing here is kept any more: a browser load is replacing it. Like a
    // link (onBeforeVisit), the switch replaces that load (beforeSubmit).
    if (this.navigation?.phase === "allowed") return
    // A launch's response shows what became of paid work, so the switch
    // waits for neither it nor a discard still deciding, and is refused.
    if (this.launching || this.discarding) {
      event.preventDefault()
      return
    }
    // A Leave's form is replacing the page; the switch replaces it instead.
    if (this.allowVisit) return
    this.cancelNavigation()
    // Like a form, the switch holds the claim while it saves; a newer action
    // (a link, Back, another form, a discard) takes it, and the switch lapses.
    const claim = this.pendingSubmission = {}
    event.detail.pending.push(this.flush().then(saved => saved && this.pendingSubmission === claim))
  }

  // Runs before Turbo sees Back or Forward (see history_traversal.js). A
  // traversal claimed here never becomes a Turbo visit, so nothing fetched
  // before the save can change this page, its head, or Turbo's history and
  // snapshot state, whatever the user decides afterwards.
  onTraverse(event) {
    // The page returning to its own entry (restoreHistory) is no traversal.
    // Any traversal ends the wait for that return.
    const returned = this.returning && this.atHomeEntry()
    this.returning = false
    if (returned) {
      event.preventDefault()
      return
    }
    // A browser load is already replacing this page (see onBeforeVisit);
    // only another browser load of the new entry can replace it.
    if (this.navigation?.phase === "allowed") {
      event.preventDefault()
      window.location.reload()
      return
    }
    if (this.allowVisit || this.launching) return
    if (this.discarding) {
      // A discard ends in a fresh workspace or keeps this page, so the
      // traversal is never followed.
      event.preventDefault()
      this.restoreHistory()
      return
    }
    if (!this.navigation && !this.busy()) return
    event.preventDefault()
    this.navigateAfterSave(window.location.href, "history")
  }

  onBeforeVisit(event) {
    // In the "allowed" phase a browser load is already replacing this page:
    // the post-save reload of a claimed history entry, a Leave's destination,
    // or a discard's fresh workspace (or a form that replaced one of those).
    // A newer link replaces that navigation, even if it was stopped; Turbo's
    // own fetch could not.
    if (this.navigation?.phase === "allowed") {
      event.preventDefault()
      window.location.assign(event.detail.url)
      return
    }
    if (this.allowVisit || this.launching) return
    if (!this.discarding && !this.navigation && !this.busy()) return
    event.preventDefault()
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
    this.pendingSubmission = null
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
      } else if (navigation.historyMoved) {
        // A link followed a claimed Back or Forward: the browser alone moved
        // to another entry, so Turbo's history position is stale and a Turbo
        // visit would push from the wrong place. A browser load replaces the
        // entry reached instead, frozen and replaceable like the reload above.
        navigation.phase = "allowed"
        this.element.inert = true
        window.location.assign(navigation.destination)
      } else {
        this.navigation = null
        window.Turbo.visit(navigation.destination)
      }
    } else {
      // Leave repeats a Back or Forward over the same distance.
      const traversal = navigation.kind === "history" ? this.historyOffset() : 0
      this.cancelNavigation()
      this.destination = traversal ? { traversal } : navigation.destination
      this.element.inert = false
      this.dialogTarget.showModal()
    }
  }

  cancelNavigation() {
    if (this.navigation?.historyMoved) this.restoreHistory()
    this.navigation = null
    this.pendingSubmission = null
  }

  // Turbo never saw a claimed traversal, so the browser alone moved to
  // another entry. Going back to this page's own entry keeps every entry as
  // it was; one without Turbo's position instead takes this page's URL and
  // state, so history still matches the page.
  restoreHistory() {
    const offset = this.historyOffset()
    if (offset === null) {
      window.history.replaceState(this.currentHistoryState, "", this.currentUrl)
    } else if (offset !== 0) {
      this.returning = true
      window.history.go(-offset)
    }
  }

  // How far the browser moved from this page's entry, by Turbo's positions.
  historyOffset() {
    const home = this.currentHistoryState?.turbo?.restorationIndex
    const here = window.history.state?.turbo?.restorationIndex
    return Number.isInteger(home) && Number.isInteger(here) ? here - home : null
  }

  atHomeEntry() {
    const home = this.currentHistoryState?.turbo?.restorationIdentifier
    return !!home && window.history.state?.turbo?.restorationIdentifier === home
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

  // Any form that replaces this page — a launch, a configuration page change,
  // signing out — is sent only once the draft is saved, so nothing is lost and
  // an action that ends the session cannot run before the save it needs. This
  // listens on the document, which Turbo leaves to run before its own handler.
  async beforeSubmit(event) {
    const form = event.target
    const submitter = event.submitter
    // A form whose own handler took over (such as the appearance switch)
    // leaves nothing to save for; Turbo skips it as well.
    if (event.defaultPrevented || !this.replacesPage({ formElement: form, submitter })) return
    // A browser load is already replacing this page (see onBeforeVisit). A
    // newer form replaces that navigation with a full page submission, as a
    // newer link does: Turbo, whose handler runs after this one, leaves the
    // form to the browser. Turbo's own fetch could not cancel a browser
    // navigation already under way.
    if (this.navigation?.phase === "allowed") {
      this.allowVisit = true
      form.dataset.turbo = "false"
      return
    }
    if (this.allowVisit) return
    if (this.discarding) {
      event.preventDefault()
      return
    }
    this.cancelNavigation()
    if (this.allowSubmit || !this.busy()) return
    event.preventDefault()
    // The latest action wins: Back, a link, a language switch or a discard
    // made while this flush runs takes over, and this submission is never sent.
    const claim = this.pendingSubmission = {}
    const saved = await this.flush()
    if (this.pendingSubmission !== claim) return
    if (saved) {
      this.send(form, submitter)
    } else if (form !== this.formTarget) {
      this.destination = { form, submitter }
      this.element.inert = false
      this.dialogTarget.showModal()
    }
  }

  // The clicked control may have been replaced while the save ran (a panel
  // re-render); the same control is found again, or the action lapses.
  send(form, submitter) {
    if (!form.isConnected) return false
    if (submitter && submitter.form !== form) {
      submitter = Array.from(form.elements).find(element => element.type === "submit" &&
        element.name === submitter.name && element.value === submitter.value &&
        element.getAttribute("formaction") === submitter.getAttribute("formaction"))
      if (!submitter) return false
    }
    this.allowSubmit = true
    try {
      form.requestSubmit(submitter)
    } finally {
      this.allowSubmit = false
    }
    return true
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
    // A browser load is replacing the page (see onBeforeVisit); it stays frozen.
    if (this.visiting || this.submission || this.navigation?.phase === "allowed") return
    this.launching = false
    this.element.inert = false
    // A Leave whose form did not replace the page leaves nothing abandoned.
    if (this.allowVisit && !this.discarding) this.resumeGuarding()
  }

  // The page stayed after all, so its edits are guarded and saved again.
  resumeGuarding() {
    this.allowVisit = false
    this.scheduleSave()
  }

  // Turbo sends a form inside a frame, or one that names a frame, to that frame.
  replacesPage({ formElement, submitter }) {
    const frame = submitter?.getAttribute("data-turbo-frame") || formElement.getAttribute("data-turbo-frame")
    return frame ? frame === "_top" : !formElement.closest("turbo-frame")
  }

  // Stay is the latest action: a traversal claimed meanwhile gives way too.
  stay() {
    this.destination = null
    this.dialogTarget.close()
    this.cancelNavigation()
  }

  leave() {
    const destination = this.destination
    this.dialogTarget.close()
    // Leave is the latest action: a traversal claimed meanwhile gives way. A
    // browser load replaces whatever entry that traversal reached, so only a
    // form or a repeated traversal needs this page's own entry back first.
    if (destination.form || destination.traversal) this.cancelNavigation()
    else this.navigation = this.pendingSubmission = null
    this.allowVisit = true
    window.clearTimeout(this.saveTimer)
    if (destination.form) {
      if (!this.send(destination.form, destination.submitter)) this.resumeGuarding()
      return
    }
    // Edits typed while it loads would be lost unguarded, as would any made
    // if the load is stopped, so the page is frozen first, and a newer
    // action replaces this browser load (see onBeforeVisit).
    this.element.inert = true
    this.navigation = { phase: "allowed" }
    // Back or Forward again, to the entry whose save failed (navigateAfterSave);
    // that browser load replaces this page (onTraverse).
    if (destination.traversal) {
      window.history.go(destination.traversal)
      return
    }
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
        this.refusedDiscard = response?.status === 409 ? this.messagesValue.discardConflict : this.messagesValue.discardFailed
        this.setStatus(this.refusedDiscard)
        // Saving resumes for anything unsaved, including edits typed during
        // the discard (changed() ignored them) and a debounce or retry it
        // cancelled, but not content the server already refused for good.
        if (this.dirty() && this.state() !== this.finallyRejected) this.saveTimer = window.setTimeout(() => this.save(), SAVE_DELAY_MS)
        return
      }
    }
    this.allowVisit = true
    // As with Leave, nothing typed while the fresh workspace loads, or after
    // that load is stopped, would be guarded, and a newer action replaces it.
    this.element.inert = true
    this.navigation = { phase: "allowed" }
    window.location.assign(this.resetUrlValue)
  }

  setStatus(message) {
    this.statusTarget.textContent = message
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
