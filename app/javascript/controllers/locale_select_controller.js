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

  async switch() {
    const locale = this.selectTarget.value
    if (locale === this.committed || this.switching) return

    this.switching = true
    const pending = []
    const event = this.dispatch("before-switch", { detail: { locale, pending }, cancelable: true })
    const results = await Promise.all(pending)
    this.switching = false

    if (event.defaultPrevented || results.includes(false)) {
      this.selectTarget.value = this.committed
      return
    }
    this.element.requestSubmit()
  }
}
