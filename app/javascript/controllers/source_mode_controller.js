import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["paste", "upload", "pasteTab", "uploadTab"]

  showPaste() {
    this.toggle(true)
  }

  showUpload() {
    this.toggle(false)
  }

  toggle(paste, { notify = true } = {}) {
    const changed = this.pasteTarget.hidden === paste
    this.pasteTarget.hidden = !paste
    this.uploadTarget.hidden = paste
    this.pasteTabTarget.setAttribute("aria-selected", String(paste))
    this.uploadTabTarget.setAttribute("aria-selected", String(!paste))
    if (changed && notify) this.element.dispatchEvent(new CustomEvent("workspace-source:changed", { bubbles: true }))
  }
}
