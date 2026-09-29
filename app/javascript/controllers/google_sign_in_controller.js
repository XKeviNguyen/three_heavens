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

// Renders Google's official Sign in with Google button in redirect mode:
// Google posts the credential to loginUri. One Tap and automatic sign-in are
// never enabled; signing in always starts with the user pressing the button.
export default class extends Controller {
  static targets = ["button", "fallback"]
  static values = { clientId: String, loginUri: String, nonce: String, text: String, locale: String }

  connect() {
    this.render = this.render.bind(this)
    this.colorScheme = window.matchMedia("(prefers-color-scheme: dark)")
    this.colorScheme.addEventListener("change", this.render)
    document.addEventListener("appearance:change", this.render)

    loadIdentityServices()
      .then(() => {
        if (!this.element.isConnected) return
        this.configure()
        this.render()
      })
      .catch(() => { if (this.element.isConnected) this.fallbackTarget.hidden = false })
  }

  disconnect() {
    this.colorScheme.removeEventListener("change", this.render)
    document.removeEventListener("appearance:change", this.render)
    this.buttonTarget.replaceChildren()
  }

  configure() {
    window.google.accounts.id.initialize({
      client_id: this.clientIdValue,
      ux_mode: "redirect",
      login_uri: this.loginUriValue,
      nonce: this.nonceValue,
      auto_select: false,
      cancel_on_tap_outside: true
    })
  }

  render() {
    if (!window.google?.accounts?.id) return

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
