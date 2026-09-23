import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["paste", "upload", "pasteTab", "uploadTab"]

  showPaste() {
    this.toggle(true)
  }

  showUpload() {
    this.toggle(false)
  }

  toggle(paste) {
    this.pasteTarget.hidden = !paste
    this.uploadTarget.hidden = paste
    this.pasteTabTarget.setAttribute("aria-selected", String(paste))
    this.uploadTabTarget.setAttribute("aria-selected", String(!paste))
    this.element.dispatchEvent(new CustomEvent("workspace-source:changed", { bubbles: true }))
  }
}
