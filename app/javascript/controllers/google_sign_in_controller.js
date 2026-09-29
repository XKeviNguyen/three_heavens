import { Controller } from "@hotwired/stimulus"

const SCRIPT_URL = "https://accounts.google.com/gsi/client"
const LOAD_TIMEOUT_MS = 10000

let loading = null

// GIS copies its own script element's nonce onto the <style> it injects, so the
// script must carry the nonce this document's CSP was issued with. Read it once
// at first load: after Turbo visits the head meta may belong to a later response.
const documentNonce = document.querySelector("meta[name='csp-nonce']")?.content

// Loads Google Identity Services once per document, only on pages that show
// the button. Email/password forms never depend on it.
function loadIdentityServices() {
  if (window.google?.accounts?.id) return Promise.resolve()

  loading ||= new Promise((resolve, reject) => {
    const script = document.createElement("script")
    const fail = () => {
      window.clearTimeout(timer)
      loading = null
      reject(new Error("Google Identity Services unavailable"))
    }
    const timer = window.setTimeout(fail, LOAD_TIMEOUT_MS)
    script.src = SCRIPT_URL
    script.async = true
    if (documentNonce) script.nonce = documentNonce
    script.addEventListener("load", () => {
      window.clearTimeout(timer)
      if (window.google?.accounts?.id) resolve()
      else fail()
    }, { once: true })
    script.addEventListener("error", () => { script.remove(); fail() }, { once: true })
    document.head.append(script)
  })
  return loading
}

// Withdraw the button this long before its ceremony expires, leaving time to
// finish Google's chooser; renew at most this many times per page view.
const EXPIRY_MARGIN_SECONDS = 60
const MAXIMUM_CEREMONIES = 12

// Renders Google's official Sign in with Google button in redirect mode:
// Google posts the credential to loginUri. One Tap and automatic sign-in are
// never enabled; signing in always starts with the user pressing the button.
//
// The button is only ever bound to a ceremony fetched from the server when it
// is shown, never one baked into the page (which could be stale after a long
// wait or a Turbo cache restore). Before a ceremony can expire the button is
// withdrawn and renewed, but only while the page is visible.
export default class extends Controller {
  static targets = ["button", "fallback", "expired"]
  static values = { clientId: String, loginUri: String, ceremonyUrl: String, intent: String, text: String, locale: String }

  connect() {
    this.rerender = this.rerender.bind(this)
    this.onVisibilityChange = this.onVisibilityChange.bind(this)
    this.colorScheme = window.matchMedia("(prefers-color-scheme: dark)")
    this.colorScheme.addEventListener("change", this.rerender)
    document.addEventListener("appearance:change", this.rerender)
    document.addEventListener("visibilitychange", this.onVisibilityChange)
    this.ceremonies = 0
    this.generation = 0
    this.renew()
  }

  disconnect() {
    this.colorScheme.removeEventListener("change", this.rerender)
    document.removeEventListener("appearance:change", this.rerender)
    document.removeEventListener("visibilitychange", this.onVisibilityChange)
    this.generation++
    this.clear()
  }

  // Also runs on turbo:before-cache, so a cached snapshot never holds a live button.
  clear() {
    window.clearTimeout(this.expiryTimer)
    this.nonce = null
    this.buttonTarget.replaceChildren()
  }

  async renew() {
    this.clear()
    this.stale = false
    if (this.ceremonies >= MAXIMUM_CEREMONIES) {
      this.expiredTarget.hidden = false
      return
    }
    this.ceremonies++
    const generation = ++this.generation
    try {
      const [ceremony] = await Promise.all([this.fetchCeremony(), loadIdentityServices()])
      if (generation !== this.generation || !this.element.isConnected) return

      this.nonce = ceremony.nonce
      this.fallbackTarget.hidden = true
      this.configure()
      this.render()
      const lifetime = Math.max(0, ceremony.expires_in - EXPIRY_MARGIN_SECONDS)
      this.expiryTimer = window.setTimeout(() => this.expire(), lifetime * 1000)
    } catch {
      if (generation === this.generation && this.element.isConnected) this.fallbackTarget.hidden = false
    }
  }

  expire() {
    this.clear()
    if (document.visibilityState === "visible") this.renew()
    else this.stale = true
  }

  onVisibilityChange() {
    if (this.stale && document.visibilityState === "visible") this.renew()
  }

  async fetchCeremony() {
    const response = await fetch(this.ceremonyUrlValue, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || ""
      },
      body: JSON.stringify({ intent: this.intentValue })
    })
    if (!response.ok) throw new Error("ceremony unavailable")

    const ceremony = await response.json()
    if (typeof ceremony.nonce !== "string" || !Number.isFinite(ceremony.expires_in)) throw new Error("invalid ceremony")
    return ceremony
  }

  configure() {
    window.google.accounts.id.initialize({
      client_id: this.clientIdValue,
      ux_mode: "redirect",
      login_uri: this.loginUriValue,
      nonce: this.nonce,
      auto_select: false,
      cancel_on_tap_outside: true
    })
  }

  // Theme changes re-render with the same, still valid ceremony.
  rerender() {
    if (this.nonce) this.render()
  }

  render() {
    this.buttonTarget.replaceChildren()
    window.google.accounts.id.renderButton(this.buttonTarget, {
      type: "standard",
      theme: this.dark() ? "filled_black" : "outline",
      size: "large",
      text: this.textValue,
      shape: "rectangular",
      logo_alignment: "left",
      width: Math.min(400, Math.max(200, Math.floor(this.buttonTarget.clientWidth || 320))),
      locale: this.localeValue
    })
  }

  dark() {
    const appearance = document.documentElement.dataset.appearance
    return appearance === "dark" || (appearance === "system" && this.colorScheme.matches)
  }
}
