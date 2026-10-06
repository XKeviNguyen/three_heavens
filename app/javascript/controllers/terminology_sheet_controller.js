import { Controller } from "@hotwired/stimulus"

// The terminology editor is a modal sheet: it opens when its frame receives an
// editor and closes when the frame is emptied (after a save) or on cancel.
export default class extends Controller {
  connect() {
    this.observer = new MutationObserver(() => this.sync())
    this.observer.observe(this.element, { childList: true, subtree: true })
    this.sync()
  }

  disconnect() {
    this.observer.disconnect()
    this.element.close?.()
    this.invoker = null
    this.hadEditor = false
    this.settleSave()
  }

  // The sheet can be closed while a save is in flight; the workspace waits
  // for its response, which selects the saved revision, before it saves and
  // navigates. Any render of the editor frame ends the save; a request
  // without an HTML response renders nothing.
  saving(event) {
    this.settleSave()
    this.saveSubmission = event.detail.formSubmission
    this.savingEditor = this.editorFrame?.firstElementChild
    const work = new Promise(resolve => { this.finishSave = resolve })
    this.element.dispatchEvent(new CustomEvent("workspace:pending", { bubbles: true, detail: { work } }))
  }

  async submitted(event) {
    const submission = event.detail.formSubmission
    if (submission !== this.saveSubmission || await event.detail.fetchResponse?.responseHTML) return
    // A newer save may have started while the response was read.
    if (submission === this.saveSubmission) this.settleSave()
  }

  // Opening another editor while a save is in flight would render over the
  // save's own response, so that editor loads once the save has settled.
  deferEditor(event) {
    if (!this.finishSave || event.detail.fetchOptions.method !== "GET") return
    event.preventDefault()
    this.resumeEditor = event.detail.resume
  }

  settleSave() {
    this.finishSave?.()
    this.finishSave = null
    const resume = this.resumeEditor
    this.resumeEditor = null
    resume?.()
  }

  get editorFrame() {
    return this.element.querySelector("#workspace-terminology-editor")
  }

  sync() {
    const hasEditor = Boolean(this.element.querySelector("#workspace-terminology-editor")?.children.length)
    if (hasEditor && !this.element.open) {
      this.invoker = document.activeElement
      this.element.showModal()
    }
    // Only a successful save or create empties the editor frame; cancelling
    // just closes the sheet. A save selects a new revision in the replaced
    // panel without any input event, so announce it for autosave, even when
    // the sheet was closed before the response arrived.
    if (this.hadEditor && !hasEditor) {
      if (this.element.open) this.element.close()
      this.restoreFocus()
      this.dispatch("changed")
    }
    this.hadEditor = hasEditor
    if (this.finishSave && this.editorFrame?.firstElementChild !== this.savingEditor) this.settleSave()
  }

  close() {
    this.element.close()
  }

  // Cancel buttons inside the swapped editor are handled by delegation from
  // the dialog. A Stimulus action on an element inside the frame content
  // stays registered with this long-lived controller after the frame is
  // replaced, which kept every previous editor's DOM alive.
  closeFromButton(event) {
    if (event.target.closest("[data-terminology-sheet-close]")) this.close()
  }

  // A save replaces the panel that opened the sheet, so the browser cannot
  // return focus to that link; focus the same control in the new panel.
  restoreFocus() {
    const invoker = this.invoker
    this.invoker = null
    if (document.activeElement && document.activeElement !== document.body) return

    const panel = document.getElementById("workspace-terminology")
    const href = invoker?.getAttribute?.("href")
    const same = href && Array.from(panel?.querySelectorAll("a[href]") || []).find(link => link.getAttribute("href") === href)
    const target = same || panel?.querySelector("a[data-turbo-frame='workspace-terminology-editor']")
    target?.focus()
  }
}
