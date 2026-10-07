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
  // navigates. A saved revision arrives as a Turbo Stream that empties the
  // editor frame and a rejected save re-renders it; either render ends the
  // save, and no other editor loads meanwhile (deferEditor). A response with
  // no body renders nothing, so it ends the save when the request does.
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

  // A glossary chosen while a save is in flight is newer than the save's
  // response, which would select the saved revision again.
  selectionChanged(event) {
    if (this.finishSave && event.target.name === "translation_workspace[glossary_revision_id]") this.chosenDuringSave = true
  }

  // The save's response replaces the panel with the current library and the
  // saved revision selected (replacing the panel also cancels any older panel
  // load). After a newer choice, that choice is selected again; a choice of
  // the saved glossary's previous revision means its saved revision.
  beforeStreamRender(event) {
    if (!this.chosenDuringSave || event.target.target !== "workspace-terminology") return
    const render = event.detail.render
    event.detail.render = async stream => {
      // Read when the render runs, so a choice made just before it counts.
      const chosen = this.glossaryRadio(":checked")
      await render(stream)
      if (!chosen) return
      const { value } = chosen
      const { glossaryId } = chosen.dataset
      const radio = this.glossaryRadio(`[value='${CSS.escape(value)}']`) || (glossaryId && this.glossaryRadio(`[data-glossary-id='${CSS.escape(glossaryId)}']`))
      if (!radio || radio.checked) return
      // A change, as a user's choice would be: the panel reloads for it and the draft saves it.
      radio.checked = true
      radio.dispatchEvent(new Event("change", { bubbles: true }))
    }
  }

  glossaryRadio(filter) {
    return document.querySelector(`input[name='translation_workspace[glossary_revision_id]']${filter}`)
  }

  settleSave() {
    this.finishSave?.()
    this.finishSave = null
    this.chosenDuringSave = false
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
