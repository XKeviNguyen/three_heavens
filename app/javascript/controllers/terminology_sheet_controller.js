import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.observer = new MutationObserver(() => this.sync())
    this.observer.observe(this.element, { childList: true, subtree: true })
    this.sync()
  }

  disconnect() {
    this.observer.disconnect()
    this.element.close?.()
  }

  sync() {
    const frame = this.element.querySelector("#workspace-terminology-editor")
    if (frame?.children.length && !this.element.open) this.element.showModal()
    if (!frame?.children.length && this.element.open) this.element.close()
  }

  close() {
    this.element.close()
  }
}
