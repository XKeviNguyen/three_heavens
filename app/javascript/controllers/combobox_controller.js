import { Controller } from "@hotwired/stimulus"

// Search text is separate from the committed value. Custom text requires an
// explicit choice, so a typo cannot silently become a language.
export default class extends Controller {
  static targets = ["input", "value", "list", "option", "custom", "status"]
  static values = { customLabel: String }

  connect() {
    this.activeIndex = -1
    this.committedValue = this.valueTarget.value
    this.visibleOptions = []
    this.boundCloseIfOutside = this.closeIfOutside.bind(this)
    document.addEventListener("pointerdown", this.boundCloseIfOutside)
    this.close()
  }

  disconnect() {
    document.removeEventListener("pointerdown", this.boundCloseIfOutside)
  }

  closeIfOutside(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  rememberValue() {
    this.committedValue = this.valueTarget.value
  }

  filter() {
    const query = this.inputTarget.value.trim().toLocaleLowerCase()
    if (this.inputTarget.value !== this.valueTarget.value) this.valueTarget.value = ""
    this.visibleOptions = this.optionTargets.filter((option) => {
      const match = !query || (option.dataset.search || "").toLocaleLowerCase().includes(query)
      option.hidden = !match
      option.setAttribute("aria-selected", option.dataset.value === this.valueTarget.value ? "true" : "false")
      return match
    })
    const exact = this.optionTargets.some((option) => option.dataset.value.toLocaleLowerCase() === query)
    this.customTarget.hidden = !query || exact || query.length > 100
    this.customTarget.textContent = this.customLabelValue.replace("%{value}", this.inputTarget.value.trim())
    if (!this.customTarget.hidden) this.visibleOptions.push(this.customTarget)
    this.activeIndex = -1
    this.open()
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
      case "Home":
        if (!this.listTarget.classList.contains("hidden")) {
          event.preventDefault()
          this.activeIndex = -1
          this.move(1)
        }
        break
      case "End":
        if (!this.listTarget.classList.contains("hidden")) {
          event.preventDefault()
          this.activeIndex = this.visibleOptions.length
          this.move(-1)
        }
        break
      case "Enter":
        if (this.activeIndex >= 0) {
          event.preventDefault()
          this.select(this.visibleOptions[this.activeIndex])
        }
        break
      case "Escape":
        this.valueTarget.value = this.committedValue
        this.inputTarget.value = this.committedValue
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

  chooseCustom(event) {
    event.preventDefault()
    this.select(this.customTarget)
  }

  toggle(event) {
    event.preventDefault()
    if (this.listTarget.classList.contains("hidden")) {
      this.filter()
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
    const value = option === this.customTarget ? this.inputTarget.value.trim() : option.dataset.value
    this.valueTarget.value = value
    this.committedValue = value
    this.inputTarget.value = value
    this.valueTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.valueTarget.dispatchEvent(new Event("change", { bubbles: true }))
    this.statusTarget.textContent = option === this.customTarget ? value : ""
    this.dispatch("change")
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
    this.visibleOptions.forEach((option) => option.setAttribute("aria-selected", "false"))
    this.activeIndex = -1
  }
}
