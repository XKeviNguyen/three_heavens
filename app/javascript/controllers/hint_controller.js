import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tooltip"]

  connect() {
    this.onPointerDown = this.onPointerDown.bind(this)
    this.element.addEventListener("pointerdown", this.onPointerDown)
  }

  disconnect() {
    this.element.removeEventListener("pointerdown", this.onPointerDown)
  }

  show() {
    this.tooltipTarget.classList.remove("hidden")
  }

  hide() {
    this.tooltipTarget.classList.add("hidden")
  }

  toggle(event) {
    event.preventDefault()
    if (this.tooltipTarget.classList.contains("hidden")) {
      this.show()
    } else {
      this.hide()
    }
  }

  onPointerDown(event) {
    // Touch devices fire focus before click. Skipping focus-driven display lets
    // the tap toggle open and dismiss the help without a race.
    this.touchInitiated = event.pointerType === "touch"
  }

  showUnlessTouch() {
    if (!this.touchInitiated) this.show()
  }
}
