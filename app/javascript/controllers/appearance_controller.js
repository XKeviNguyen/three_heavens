import { Controller } from "@hotwired/stimulus"

// Saves run one after another so rapid choices persist in the order made, and
// the latest unsaved choice survives Turbo visits that render an older value.
//
// Every tab of this browser shares its cookies and account, so saves from all
// tabs take turns through a Web Lock. The lock is requested when the choice
// is made, so turns follow the order of the choices, and each save holds it
// until its response has arrived and been applied. A later choice can thus
// never reach the server before an earlier one from another tab. Where Web
// Locks are unavailable, saves from this page alone take turns.
//
// Limits: this orders the tabs of one browser profile only. Choices made on
// different devices or browsers are applied in the order they reach the
// server. A request still on its way when its page reloads or crashes has
// released the lock, so it can still reach the server after the next one.
const SAVE_LOCK = "appearance-save"
let saves = Promise.resolve()
let pendingAppearance = null
let savedAppearance = null
// The server numbers each save one past the browser's last saved number and
// renders that number with every page. A visit the server rendered before a
// newer choice was saved (one already on its way, or prefetched) carries an
// older number, so its appearance is out of date and the newer saved one
// stays.
let savedRevision = 0

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
    pendingAppearance = appearance
    this.apply(appearance)
    if (this.hasSummaryTarget) {
      this.element.open = false
      this.summaryTarget.focus()
    }

    inTurn(async () => {
      try {
        const response = await fetch(form.action, {
          method: "POST", body, credentials: "same-origin", headers: { Accept: "application/json" }
        })
        if (!response.ok) throw new Error("appearance not saved")
        const { revision } = await response.json()
        if (!Number.isSafeInteger(revision)) throw new Error("appearance not saved")
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

function inTurn(save) {
  if (navigator.locks) return navigator.locks.request(SAVE_LOCK, save)
  saves = saves.then(save)
  return saves
}
