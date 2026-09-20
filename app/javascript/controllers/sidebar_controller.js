import { Controller } from "@hotwired/stimulus"

const FOCUSABLE = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])"
].join(",")

export default class extends Controller {
  static targets = ["panel", "scrim", "trigger"]

  connect() {
    this.onKeydown = this.onKeydown.bind(this)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    document.body.classList.remove("overflow-hidden")
  }

  open() {
    this.panelTarget.classList.remove("hidden")
    this.panelTarget.classList.add("flex")
    this.scrimTarget.classList.remove("hidden")
    this.triggerTarget?.setAttribute("aria-expanded", "true")
    document.body.classList.add("overflow-hidden")
    document.addEventListener("keydown", this.onKeydown)
    this.focusableElements()[0]?.focus()
  }

  close() {
    if (this.panelTarget.classList.contains("hidden")) return

    this.panelTarget.classList.add("hidden")
    this.panelTarget.classList.remove("flex")
    this.scrimTarget.classList.add("hidden")
    this.triggerTarget?.setAttribute("aria-expanded", "false")
    document.body.classList.remove("overflow-hidden")
    document.removeEventListener("keydown", this.onKeydown)
    this.triggerTarget?.focus()
  }

  onKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
      return
    }
    if (event.key !== "Tab") return

    const focusable = this.focusableElements()
    if (focusable.length === 0) return

    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  focusableElements() {
    return Array.from(this.panelTarget.querySelectorAll(FOCUSABLE)).filter(
      (element) => element.offsetParent !== null || element === document.activeElement
    )
  }
}
