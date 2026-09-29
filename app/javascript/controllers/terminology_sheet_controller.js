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
  }

  sync() {
    const frame = this.element.querySelector("#workspace-terminology-editor")
    if (frame?.children.length && !this.element.open) {
      this.invoker = document.activeElement
      this.element.showModal()
    }
    if (!frame?.children.length && this.element.open) {
      this.element.close()
      this.restoreFocus()
    }
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
