import { Controller } from "@hotwired/stimulus"

// Choosing an interface language is the action: no separate Apply button.
// Before navigating, listeners (the workspace draft guard) may add promises to
// event.detail.pending; if any resolves false the switch is abandoned and the
// select returns to the committed language, so unsaved work is never dropped.
export default class extends Controller {
  static targets = ["select"]

  connect() {
    this.committed = this.selectTarget.value
  }

  // The newest choice wins: a switch still waiting lapses when another choice
  // is made, including a return to the committed language, which needs none.
  async switch() {
    const locale = this.selectTarget.value
    const attempt = this.attempt = {}
    if (locale === this.committed) return

    const pending = []
    const event = this.dispatch("before-switch", { detail: { locale, pending }, cancelable: true })
    const results = await Promise.all(pending)
    if (this.attempt !== attempt) return

    if (event.defaultPrevented || results.includes(false)) {
      this.selectTarget.value = this.committed
      return
    }
    this.element.requestSubmit()
  }
}
