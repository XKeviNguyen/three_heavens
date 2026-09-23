import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  static targets = ["form", "dialog"]

  connect() {
    this.initialState = this.state()
    this.currentUrl = window.location.href
    this.currentHistoryState = window.history.state
    this.onBeforeRender = this.onBeforeRender.bind(this)
    document.addEventListener("turbo:before-render", this.onBeforeRender)
    this.onBeforeVisit = this.onBeforeVisit.bind(this)
    this.onBeforeUnload = this.onBeforeUnload.bind(this)
    document.addEventListener("turbo:before-visit", this.onBeforeVisit)
    window.addEventListener("beforeunload", this.onBeforeUnload)
  }

  disconnect() {
    document.removeEventListener("turbo:before-render", this.onBeforeRender)
    document.removeEventListener("turbo:before-visit", this.onBeforeVisit)
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    this.dialogTarget.close?.()
  }

  state() {
    return JSON.stringify(Array.from(new FormData(this.formTarget).entries())
      .filter(([name]) => !["authenticity_token", "translation_workspace[submission_token]"].includes(name))
      .map(([name, value]) => [name, typeof value === "string" ? value : value.name]))
  }

  dirty() {
    return this.state() !== this.initialState
  }

  onBeforeVisit(event) {
    if (this.allowVisit || this.launching || !this.dirty()) return
    event.preventDefault()
    this.destination = event.detail.url
    this.dialogTarget.showModal()
  }

  onBeforeRender(event) {
    if (this.allowVisit || this.launching || !this.dirty() || window.location.href === this.currentUrl) return

    event.preventDefault()
    this.destination = window.location.href
    window.history.pushState(this.currentHistoryState, "", this.currentUrl)
    this.dialogTarget.showModal()
  }

  onBeforeUnload(event) {
    if (this.allowVisit || this.launching || !this.dirty()) return
    event.preventDefault()
    event.returnValue = ""
  }

  submitStart(event) {
    if (event.target === this.formTarget) this.launching = true
  }

  submitEnd(event) {
    if (event.target === this.formTarget && !event.detail.success) this.launching = false
  }

  stay() {
    this.destination = null
    this.dialogTarget.close()
  }

  leave() {
    const destination = this.destination
    this.allowVisit = true
    this.dialogTarget.close()
    window.location.assign(destination)
  }
}
