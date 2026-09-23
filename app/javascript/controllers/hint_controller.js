import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tooltip", "trigger"]

  connect() {
    this.onDocumentPointerDown = this.onDocumentPointerDown.bind(this)
    this.onPointerDown = this.onPointerDown.bind(this)
    document.addEventListener("pointerdown", this.onDocumentPointerDown)
    this.triggerTarget.addEventListener("pointerdown", this.onPointerDown)
  }

  disconnect() {
    document.removeEventListener("pointerdown", this.onDocumentPointerDown)
    this.triggerTarget.removeEventListener("pointerdown", this.onPointerDown)
    this.hide()
  }

  show() {
    this.tooltipTarget.classList.remove("hidden")
    this.triggerTarget.setAttribute("aria-expanded", "true")
  }

  hide() {
    this.tooltipTarget.classList.add("hidden")
    this.triggerTarget.setAttribute("aria-expanded", "false")
  }

  showUnlessTouch() {
    if (!this.touchInitiated) this.show()
  }

  resetFocus() {
    this.touchInitiated = false
    this.hide()
  }

  toggle(event) {
    event.preventDefault()
    if (this.touchInitiated && !this.tooltipTarget.classList.contains("hidden")) this.hide()
    else this.show()
    this.touchInitiated = false
  }

  onPointerDown(event) {
    this.touchInitiated = event.pointerType === "touch"
  }

  onDocumentPointerDown(event) {
    if (!this.element.contains(event.target)) this.hide()
  }

  escape(event) {
    event.stopPropagation()
    this.hide()
    this.triggerTarget.focus()
  }
}
