import { Controller } from "@hotwired/stimulus"

const FOCUSABLE = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])"
].join(",")

// Turbo replaces the page on every visit. Keeping the navigation's scroll
// position stops links from jumping under a resting pointer, where hover
// prefetching would then load a page nobody chose.
let navScrollTop = 0
// Pages without the navigation (sign-in, sign-out) start the next one at the top.
document.addEventListener("turbo:load", () => {
  if (!document.querySelector("[data-sidebar-target='nav']")) navScrollTop = 0
})

export default class extends Controller {
  static targets = ["panel", "scrim", "trigger", "nav"]

  connect() {
    this.onKeydown = this.onKeydown.bind(this)
    // Turbo snapshots the page when leaving it; an open drawer would come
    // back open (without its Escape handler or scroll lock) after Back.
    this.onBeforeCache = () => this.collapse()
    document.addEventListener("turbo:before-cache", this.onBeforeCache)
    this.onBeforeRender = () => { if (this.hasNavTarget) navScrollTop = this.navTarget.scrollTop }
    document.addEventListener("turbo:before-render", this.onBeforeRender)
    if (this.hasNavTarget) this.navTarget.scrollTop = navScrollTop
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    document.removeEventListener("turbo:before-cache", this.onBeforeCache)
    document.removeEventListener("turbo:before-render", this.onBeforeRender)
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
    if (this.collapse()) this.triggerTarget?.focus()
  }

  // Returns whether the drawer was open.
  collapse() {
    if (this.panelTarget.classList.contains("hidden")) return false

    this.panelTarget.classList.add("hidden")
    this.panelTarget.classList.remove("flex")
    this.scrimTarget.classList.add("hidden")
    this.triggerTarget?.setAttribute("aria-expanded", "false")
    document.body.classList.remove("overflow-hidden")
    document.removeEventListener("keydown", this.onKeydown)
    return true
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
