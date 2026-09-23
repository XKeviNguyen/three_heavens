import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "dropzone", "filename", "form"]

  connect() {
    this.dragDepth = 0
  }

  dragover(event) {
    event.preventDefault()
    this.highlight(true)
  }

  dragleave(event) {
    event.preventDefault()
    if (event.relatedTarget && this.dropzoneTarget.contains(event.relatedTarget)) return

    this.highlight(false)
  }

  drop(event) {
    event.preventDefault()
    this.highlight(false)

    const files = event.dataTransfer?.files
    if (!files || files.length === 0) return

    this.inputTarget.files = files
    this.announce()
    this.submit()
  }

  browse() {
    this.inputTarget.click()
  }

  changed() {
    this.announce()
  }

  announce() {
    if (!this.hasFilenameTarget) return

    const file = this.inputTarget.files?.[0]
    this.filenameTarget.textContent = file ? `${file.name} · ${this.humanSize(file.size)}` : ""
  }

  submit() {
    if (this.inputTarget.files && this.inputTarget.files.length > 0) {
      this.formTarget.requestSubmit()
    }
  }

  highlight(active) {
    this.dropzoneTarget.classList.toggle("border-blue-500", active)
    this.dropzoneTarget.classList.toggle("bg-blue-50", active)
  }

  humanSize(bytes) {
    if (bytes >= 1_048_576) return `${(bytes / 1_048_576).toFixed(1)} MiB`
    if (bytes >= 1_024) return `${Math.round(bytes / 1_024)} KiB`
    return `${bytes} B`
  }
}
