import { Controller } from "@hotwired/stimulus"

// Saves run one after another so rapid choices persist in the order made, and
// the latest unsaved choice survives Turbo visits that render an older value.
let saves = Promise.resolve()
let pendingAppearance = null
let savedAppearance = null

// System / Light / Dark. The server renders the saved preference into
// <html data-appearance>, so first paint is already correct and CSS follows the
// OS in System mode; this controller only applies and saves changes.
export default class extends Controller {
  static targets = ["summary"]
  static values = { current: String, labels: Object }

  connect() {
    savedAppearance ??= this.currentValue
    this.apply(pendingAppearance ?? this.currentValue)
  }

  choose(event) {
    event.preventDefault()
    const form = event.target
    const body = new FormData(form)
    const appearance = body.get("appearance")
    pendingAppearance = appearance
    this.apply(appearance)
    if (this.hasSummaryTarget) {
      this.element.open = false
      this.summaryTarget.focus()
    }

    saves = saves.then(async () => {
      try {
        const response = await fetch(form.action, {
          method: "POST", body, credentials: "same-origin", headers: { Accept: "application/json" }
        })
        if (!response.ok) throw new Error("appearance not saved")
        savedAppearance = appearance
        // Cached page snapshots still carry the previous preference.
        window.Turbo?.cache?.clear()
      } catch {
        // Only the most recent choice decides what is shown after a failure.
        if (pendingAppearance === appearance) this.apply(savedAppearance)
      } finally {
        if (pendingAppearance === appearance) pendingAppearance = null
      }
    })
  }

  apply(appearance) {
    this.currentValue = appearance
    document.documentElement.dataset.appearance = appearance
    document.querySelector("meta[name='color-scheme']")?.setAttribute("content", appearance === "system" ? "light dark" : appearance)
    // A page can show more than one copy of the control (e.g. landing header and mobile menu).
    document.querySelectorAll(".appearance-option").forEach(option => option.setAttribute("aria-pressed", String(option.dataset.appearance === appearance)))
    document.querySelectorAll("[data-appearance-target='summary']").forEach(summary => summary.setAttribute("aria-label", `${this.labelsValue.heading}: ${this.labelsValue[appearance]}`))
    document.dispatchEvent(new CustomEvent("appearance:change", { detail: { appearance } }))
  }
}
