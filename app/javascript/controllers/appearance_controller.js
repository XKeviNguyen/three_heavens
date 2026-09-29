import { Controller } from "@hotwired/stimulus"

// System / Light / Dark. The server renders the saved preference into
// <html data-appearance>, so first paint is already correct and CSS follows the
// OS in System mode; this controller only applies and saves changes.
export default class extends Controller {
  static targets = ["summary", "option"]
  static values = { current: String, labels: Object }

  connect() {
    this.apply(this.currentValue)
  }

  async choose(event) {
    event.preventDefault()
    const form = event.target
    const appearance = new FormData(form).get("appearance")
    const previous = this.currentValue
    this.apply(appearance)
    this.element.open = false
    this.summaryTarget.focus()

    try {
      const response = await fetch(form.action, {
        method: "POST", body: new FormData(form), credentials: "same-origin", headers: { Accept: "application/json" }
      })
      if (!response.ok) throw new Error("appearance not saved")
      // Cached page snapshots still carry the previous preference.
      window.Turbo?.cache?.clear()
    } catch {
      this.apply(previous)
    }
  }

  apply(appearance) {
    this.currentValue = appearance
    document.documentElement.dataset.appearance = appearance
    document.querySelector("meta[name='color-scheme']")?.setAttribute("content", appearance === "system" ? "light dark" : appearance)
    this.optionTargets.forEach(option => option.setAttribute("aria-pressed", String(option.dataset.appearance === appearance)))
    this.summaryTarget.setAttribute("aria-label", `${this.labelsValue.heading}: ${this.labelsValue[appearance]}`)
    document.dispatchEvent(new CustomEvent("appearance:change", { detail: { appearance } }))
  }
}
