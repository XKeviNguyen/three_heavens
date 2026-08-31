import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "template", "count"]
  static values = { maximum: Number }

  add() {
    if (this.listTarget.children.length >= this.maximumValue) return

    this.listTarget.insertAdjacentHTML("beforeend", this.templateTarget.innerHTML)
    this.updateControls()
  }

  remove(event) {
    event.currentTarget.closest("[data-glossary-entries-target='entry']").remove()
    this.updateControls()
  }

  connect() {
    this.updateControls()
  }

  updateControls() {
    const size = this.listTarget.children.length
    this.countTarget.textContent = `${size}/${this.maximumValue} entries`
    this.element.querySelectorAll("[data-glossary-entries-target='remove']").forEach((button) => {
      button.disabled = size <= 1
    })
  }
}
