import { Controller } from "@hotwired/stimulus"

// Accessible searchable combobox for a bounded, server-rendered option list.
// The text input remains the authoritative form field so historical or custom
// values stay valid; selecting an option simply writes its value into it.
export default class extends Controller {
  static targets = ["input", "list", "option"]

  connect() {
    this.activeIndex = -1
    this.visibleOptions = []
    this.close()
  }

  filter() {
    const query = this.inputTarget.value.trim().toLowerCase()
    this.visibleOptions = this.optionTargets.filter((option) => {
      const value = (option.dataset.value || option.textContent).toLowerCase()
      const match = query === "" || value.includes(query)
      option.hidden = !match
      option.setAttribute("aria-selected", "false")
      return match
    })
    this.activeIndex = -1
    if (this.visibleOptions.length > 0) {
      this.open()
    } else {
      this.close()
    }
  }

  keydown(event) {
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        this.move(1)
        break
      case "ArrowUp":
        event.preventDefault()
        this.move(-1)
        break
      case "Enter":
        if (this.activeIndex >= 0) {
          event.preventDefault()
          this.select(this.visibleOptions[this.activeIndex])
        }
        break
      case "Escape":
        this.close()
        break
      case "Tab":
        this.close()
        break
    }
  }

  choose(event) {
    event.preventDefault()
    this.select(event.currentTarget)
  }

  toggle(event) {
    event.preventDefault()
    if (this.listTarget.classList.contains("hidden")) {
      this.filter()
      this.open()
      this.inputTarget.focus()
    } else {
      this.close()
    }
  }

  move(delta) {
    if (this.listTarget.classList.contains("hidden")) this.filter()
    if (this.visibleOptions.length === 0) return

    this.activeIndex = (this.activeIndex + delta + this.visibleOptions.length) % this.visibleOptions.length
    this.visibleOptions.forEach((option, index) => {
      option.setAttribute("aria-selected", index === this.activeIndex ? "true" : "false")
    })
    const active = this.visibleOptions[this.activeIndex]
    this.inputTarget.setAttribute("aria-activedescendant", active.id)
    active.scrollIntoView({ block: "nearest" })
  }

  select(option) {
    if (!option) return

    this.inputTarget.value = option.dataset.value || option.textContent.trim()
    this.inputTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
    this.close()
    this.inputTarget.focus()
  }

  open() {
    this.listTarget.classList.remove("hidden")
    this.inputTarget.setAttribute("aria-expanded", "true")
  }

  close() {
    this.listTarget.classList.add("hidden")
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.inputTarget.removeAttribute("aria-activedescendant")
    this.optionTargets.forEach((option) => option.setAttribute("aria-selected", "false"))
    this.activeIndex = -1
  }
}
