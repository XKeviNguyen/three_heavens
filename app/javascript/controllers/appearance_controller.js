import { Controller } from "@hotwired/stimulus"

// Saves run one after another so rapid choices persist in the order made, and
// the latest unsaved choice survives Turbo visits that render an older value.
let saves = Promise.resolve()
let pendingAppearance = null
let savedAppearance = null
// Each choice is numbered in the order made and the server renders the number
// of the latest one it saved. A visit the server rendered before a newer
// choice was saved (one already on its way, or prefetched) carries an older
// number, so its appearance is out of date and the newer saved one stays.
let savedRevision = 0
let lastRevision = 0

// System / Light / Dark. The server renders the saved preference into
// <html data-appearance>, so first paint is already correct and CSS follows the
// OS in System mode; this controller only applies and saves changes.
export default class extends Controller {
  static targets = ["summary"]
  static values = { current: String, revision: Number, labels: Object }

  connect() {
    if (savedAppearance === null || this.revisionValue >= savedRevision) {
      savedAppearance = this.currentValue
      savedRevision = this.revisionValue
    }
    this.apply(pendingAppearance ?? savedAppearance)
  }

  choose(event) {
    event.preventDefault()
    const form = event.target
    const body = new FormData(form)
    const appearance = body.get("appearance")
    const revision = lastRevision = Math.max(Date.now(), lastRevision + 1, savedRevision + 1)
    body.set("revision", String(revision))
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
        savedRevision = revision
        // Cached page snapshots still carry the previous preference.
        window.Turbo?.cache?.clear()
        document.dispatchEvent(new CustomEvent("appearance:saved", { detail: { appearance } }))
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
