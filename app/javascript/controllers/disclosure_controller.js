import { Controller } from "@hotwired/stimulus"

// Closes a <details> menu the way people expect a popover to close. Listeners
// are declared as Stimulus @document actions so they are removed on disconnect.
export default class extends Controller {
  closeOutside(event) {
    if (this.element.open && !this.element.contains(event.target)) this.element.open = false
  }

  closeOnEscape() {
    if (!this.element.open) return

    this.element.open = false
    this.element.querySelector("summary")?.focus()
  }

  closeAfterNavigation(event) {
    if (event.target.closest("a")) this.element.open = false
  }
}
