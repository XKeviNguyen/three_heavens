import { Controller } from "@hotwired/stimulus"

const SEARCH_DEBOUNCE_MS = 200

export default class extends Controller {
  static targets = ["input", "list", "selected", "status", "count"]
  static values = {
    role: String,
    name: String,
    max: Number,
    endpoint: String,
    selected: Array
  }

  connect() {
    this.activeIndex = -1
    this.visibleOptions = []
    this.results = []
    this.close()
    this.updateCount()
    this.onDocumentPointerDown = (event) => {
      if (!this.element.contains(event.target)) this.close()
    }
    document.addEventListener("pointerdown", this.onDocumentPointerDown)
  }

  disconnect() {
    document.removeEventListener("pointerdown", this.onDocumentPointerDown)
    window.clearTimeout(this.debounceTimer)
  }

  search() {
    window.clearTimeout(this.debounceTimer)
    this.debounceTimer = window.setTimeout(() => this.fetchResults(), SEARCH_DEBOUNCE_MS)
  }

  async fetchResults() {
    const query = this.inputTarget.value.trim()
    this.setStatus("Searching OpenRouter…")
    const url = new URL(this.endpointValue, window.location.origin)
    url.searchParams.set("role", this.roleValue)
    if (query) url.searchParams.set("q", query)

    try {
      const response = await fetch(url.toString(), { headers: { Accept: "application/json" } })
      if (!response.ok) throw new Error("catalog request failed")
      const payload = await response.json()
      this.results = Array.isArray(payload.models) ? payload.models : []
      this.renderResults()
      this.setStatus(this.results.length === 0 ? "No compatible models found." : `${payload.source === "fallback" ? "Saved models · " : ""}${this.results.length} result(s)`)
    } catch {
      this.results = []
      this.renderResults()
      this.setStatus("OpenRouter catalog is unavailable. Try again shortly.")
    }
  }

  renderResults() {
    this.listTarget.innerHTML = ""
    this.visibleOptions = []

    this.results.forEach((model, index) => {
      const option = document.createElement("li")
      option.id = `${this.element.id}-result-${index}`
      option.setAttribute("role", "option")
      option.setAttribute("aria-selected", "false")
      option.className = "cursor-pointer border-b border-slate-100 px-3 py-2 last:border-b-0 hover:bg-blue-50"
      option.appendChild(this.resultContent(model))
      option.addEventListener("mousedown", (event) => {
        event.preventDefault()
        this.select(model)
      })
      this.listTarget.appendChild(option)
      this.visibleOptions.push(option)
    })

    if (this.results.length > 0) {
      this.open()
    } else {
      this.close()
    }
  }

  resultContent(model) {
    const wrapper = document.createElement("div")
    wrapper.className = "flex items-start justify-between gap-3"

    const details = document.createElement("div")
    details.className = "min-w-0"

    const name = document.createElement("p")
    name.className = "flex items-center gap-2 truncate text-sm font-medium text-slate-900"
    name.textContent = model.name
    if (model.free) {
      const badge = document.createElement("span")
      badge.className = "rounded-full bg-emerald-100 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-emerald-800"
      badge.textContent = "Free"
      name.appendChild(badge)
    }
    details.appendChild(name)

    const identifier = document.createElement("p")
    identifier.className = "truncate text-xs text-slate-500"
    identifier.textContent = model.identifier
    details.appendChild(identifier)

    const meta = document.createElement("p")
    meta.className = "mt-1 text-xs text-slate-500"
    const parts = []
    if (model.context_length) parts.push(`${this.compactNumber(model.context_length)} context`)
    if (model.prompt_price) parts.push(`${this.pricePerMillion(model.prompt_price)} in`)
    if (model.completion_price) parts.push(`${this.pricePerMillion(model.completion_price)} out`)
    meta.textContent = parts.join(" · ")
    details.appendChild(meta)

    const role = document.createElement("span")
    role.className = "shrink-0 rounded-full bg-slate-100 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-slate-600"
    role.textContent = this.roleValue

    wrapper.appendChild(details)
    wrapper.appendChild(role)
    return wrapper
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
          this.select(this.results[this.activeIndex])
        }
        break
      case "Escape":
        this.close()
        break
    }
  }

  move(delta) {
    if (this.visibleOptions.length === 0) return

    this.activeIndex = (this.activeIndex + delta + this.visibleOptions.length) % this.visibleOptions.length
    this.visibleOptions.forEach((option, index) => {
      option.setAttribute("aria-selected", index === this.activeIndex ? "true" : "false")
    })
    const active = this.visibleOptions[this.activeIndex]
    this.inputTarget.setAttribute("aria-activedescendant", active.id)
    active.scrollIntoView({ block: "nearest" })
  }

  select(model) {
    if (!model || this.selectedIdentifiers().includes(model.identifier)) {
      this.inputTarget.value = ""
      this.close()
      return
    }
    if (this.selectedIdentifiers().length >= this.maxValue) {
      this.setStatus(`You can select up to ${this.maxValue} models.`)
      return
    }

    this.appendChip(model)
    this.inputTarget.value = ""
    this.close()
    this.updateCount()
    this.setStatus("")
  }

  appendChip(model) {
    const chip = document.createElement("span")
    chip.dataset.modelChip = "true"
    chip.className = "inline-flex max-w-full items-center gap-1 rounded-full border border-slate-200 bg-white py-1 pl-3 pr-1 text-xs text-slate-700 shadow-sm"

    const hidden = document.createElement("input")
    hidden.type = "hidden"
    hidden.name = this.nameValue
    hidden.value = model.identifier
    chip.appendChild(hidden)

    const label = document.createElement("span")
    label.className = "truncate"
    label.textContent = model.name
    chip.appendChild(label)

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "inline-flex size-6 items-center justify-center rounded-full text-slate-400 hover:bg-slate-100 hover:text-slate-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-600"
    remove.setAttribute("aria-label", `Remove ${model.name}`)
    remove.textContent = "×"
    remove.addEventListener("click", () => {
      chip.remove()
      this.updateCount()
    })
    chip.appendChild(remove)

    this.selectedTarget.appendChild(chip)
  }

  remove(event) {
    event.preventDefault()
    event.currentTarget.closest("[data-model-chip]")?.remove()
    this.updateCount()
  }

  selectedIdentifiers() {
    return Array.from(this.selectedTarget.querySelectorAll("input[type='hidden']")).map((input) => input.value)
  }

  updateCount() {
    if (!this.hasCountTarget) return

    this.countTarget.textContent = `${this.selectedIdentifiers().length}/${this.maxValue} selected`
  }

  setStatus(message) {
    if (!this.hasStatusTarget) return

    this.statusTarget.textContent = message
  }

  open() {
    this.listTarget.classList.remove("hidden")
    this.inputTarget.setAttribute("aria-expanded", "true")
  }

  close() {
    this.listTarget.classList.add("hidden")
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.inputTarget.removeAttribute("aria-activedescendant")
    this.activeIndex = -1
  }

  pricePerMillion(value) {
    const numeric = Number(value)
    if (!Number.isFinite(numeric)) return "—"
    const perMillion = numeric * 1_000_000
    return `$${perMillion >= 1 ? perMillion.toFixed(2) : perMillion.toFixed(3)}/M`
  }

  compactNumber(value) {
    const numeric = Number(value)
    if (!Number.isFinite(numeric)) return "—"
    if (numeric >= 1_000_000) return `${(numeric / 1_000_000).toFixed(1)}M`
    if (numeric >= 1_000) return `${Math.round(numeric / 1_000)}K`
    return `${numeric}`
  }
}
