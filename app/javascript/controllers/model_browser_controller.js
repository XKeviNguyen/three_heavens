import { Controller } from "@hotwired/stimulus"

const SEARCH_DEBOUNCE_MS = 220

// Live OpenRouter model browser. Results are always fetched from the
// authenticated catalog endpoint. New selections submit identifiers for
// trusted server-side resolution; existing saved selections retain their IDs.
export default class extends Controller {
  static targets = ["search", "list", "selected", "count", "status", "provider", "free", "sort", "meta", "empty"]
  static values = { role: String, name: String, max: Number, endpoint: String, messages: Object }

  connect() {
    this.onDocumentPointerDown = this.onDocumentPointerDown.bind(this)
    this.activeIndex = -1
    this.results = []
    this.resultsVisible = true
    this.requestSequence ||= 0
    this.providersLoaded = false
    this.updateCount()
    this.fetchResults()
    document.addEventListener("pointerdown", this.onDocumentPointerDown)
  }

  disconnect() {
    document.removeEventListener("pointerdown", this.onDocumentPointerDown)
    window.clearTimeout(this.debounceTimer)
    window.clearTimeout(this.outsideTimer)
    this.requestSequence += 1
    this.pendingRequest?.abort()
  }

  onDocumentPointerDown(event) {
    window.clearTimeout(this.outsideTimer)
    if (this.element.contains(event.target)) return
    this.resultsVisible = false
    // Close after the outside control receives its click; collapsing results
    // during pointerdown can move that control out from under the pointer.
    this.outsideTimer = window.setTimeout(() => this.closeList(), 0)
  }

  openResults() {
    this.resultsVisible = true
    if (this.results.length > 0) this.openList()
    else this.fetchResults()
  }

  search() {
    this.resultsVisible = true
    window.clearTimeout(this.debounceTimer)
    this.debounceTimer = window.setTimeout(() => this.fetchResults(), SEARCH_DEBOUNCE_MS)
  }

  filter() {
    this.resultsVisible = true
    this.fetchResults()
  }

  // Only the newest request matters: starting one aborts the previous one, and
  // a response is applied only if it is still the newest.
  async fetchResults() {
    const requestSequence = ++this.requestSequence
    this.pendingRequest?.abort()
    const request = new AbortController()
    this.pendingRequest = request
    this.setStatus(this.copy("searching"))
    const url = new URL(this.endpointValue, window.location.origin)
    url.searchParams.set("role", this.roleValue)
    const query = this.searchTarget.value.trim()
    if (query) url.searchParams.set("q", query)
    if (this.hasProviderTarget && this.providerTarget.value) url.searchParams.set("provider", this.providerTarget.value)
    if (this.hasFreeTarget && this.freeTarget.checked) url.searchParams.set("free", "true")
    if (this.hasSortTarget) url.searchParams.set("sort", this.sortTarget.value)

    try {
      const response = await fetch(url.toString(), { headers: { Accept: "application/json" }, signal: request.signal })
      if (!response.ok) throw new Error("catalog request failed")
      const payload = await response.json()
      if (requestSequence !== this.requestSequence) return
      this.results = Array.isArray(payload.models) ? payload.models : []
      this.total = payload.total
      this.loadProviders(payload.providers || [], payload.source)
      this.renderResults(payload)
      const sourceLabel = payload.source === "fallback" ? this.copy("saved_prefix") : ""
      const totalLabel = typeof this.total === "number" ? this.total : this.results.length
      this.setStatus(this.results.length === 0 ? this.copy("no_results") : `${sourceLabel}${this.copy("compatible_count", { count: totalLabel })}`)
    } catch {
      if (requestSequence !== this.requestSequence) return
      this.results = []
      this.renderResults({ source: "error" })
      this.setStatus(this.copy("unavailable"))
    } finally {
      if (this.pendingRequest === request) this.pendingRequest = null
    }
  }

  loadProviders(providers, source) {
    if (!this.hasProviderTarget) return
    if (this.providersLoaded && source === "fallback") return

    const current = this.providerTarget.value
    const options = [`<option value="">${this.escape(this.copy("all_providers"))}</option>`].concat(
      providers.map((provider) => `<option value="${this.escape(provider)}">${this.escape(provider)}</option>`)
    )
    this.providerTarget.innerHTML = options.join("")
    this.providerTarget.value = providers.includes(current) ? current : ""
    this.providersLoaded = true
  }

  renderResults(payload) {
    this.listTarget.innerHTML = ""
    this.options = []

    if (payload.source === "error") {
      this.listTarget.appendChild(this.message(this.copy("live_unavailable")))
      this.closeList()
      return
    }
    if (this.results.length === 0) {
      this.listTarget.appendChild(this.message(this.copy("no_results")))
      this.closeList()
      return
    }

    this.results.forEach((model, index) => {
      const option = this.buildOption(model, index)
      this.listTarget.appendChild(option)
      this.options.push(option)
    })
    if (this.resultsVisible) this.openList()
    else this.closeList()
  }

  buildOption(model, index) {
    const selected = this.selectedIdentifiers().includes(model.identifier)
    const atMax = this.selectedIdentifiers().length >= this.maxValue

    const option = document.createElement("div")
    option.setAttribute("role", "option")
    option.setAttribute("aria-selected", "false")
    option.id = `${this.element.id}-model-${index}`
    option.dataset.identifier = model.identifier
    option.className = "border-b border-slate-100 px-3 py-3 last:border-b-0 hover:bg-slate-50/80"
    option.tabIndex = -1

    const row = document.createElement("div")
    row.className = "flex items-start justify-between gap-3"

    const details = document.createElement("div")
    details.className = "min-w-0"

    const title = document.createElement("p")
    title.className = "flex items-center gap-2 text-sm font-semibold text-slate-900"
    title.appendChild(document.createTextNode(model.name))
    if (model.free) title.appendChild(this.badge(this.copy("free"), "bg-emerald-100 text-emerald-800"))
    details.appendChild(title)

    const identifier = document.createElement("p")
    identifier.className = "mt-0.5 truncate font-mono text-xs text-slate-500"
    identifier.textContent = `${model.provider} · ${model.identifier}`
    details.appendChild(identifier)

    const meta = document.createElement("div")
    meta.className = "mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-slate-500"
    meta.appendChild(this.metaItem(`${this.copy("context")} ${this.compactNumber(model.context_length)}`))
    meta.appendChild(this.compatItem(this.copy("translator"), model.translator))
    meta.appendChild(this.compatItem(this.copy("structured"), model.structured))
    meta.appendChild(this.metaItem(`${this.pricePerMillion(model.prompt_price)} ${this.copy("price_in")}`))
    meta.appendChild(this.metaItem(`${this.pricePerMillion(model.completion_price)} ${this.copy("price_out")}`))
    details.appendChild(meta)

    const action = document.createElement("button")
    action.type = "button"
    action.className = "shrink-0 rounded-lg px-3 py-1.5 text-xs font-semibold " +
      (selected
        ? "bg-emerald-50 text-emerald-700 ring-1 ring-emerald-200"
        : atMax
          ? "bg-slate-100 text-slate-400"
          : "bg-blue-700 text-white hover:bg-blue-800")
    action.textContent = selected ? this.copy("added") : this.copy("add")
    action.disabled = selected || atMax
    action.setAttribute("aria-label", selected ? this.copy("is_selected", { name: model.name }) : this.copy("add_model", { name: model.name }))
    action.addEventListener("click", (event) => {
      event.stopPropagation()
      if (!selected) this.add(model)
    })

    row.appendChild(details)
    row.appendChild(action)
    option.appendChild(row)
    option.addEventListener("click", () => {
      if (!this.selectedIdentifiers().includes(model.identifier) && this.selectedIdentifiers().length < this.maxValue) {
        this.add(model)
      }
    })
    return option
  }

  add(model) {
    if (this.selectedIdentifiers().includes(model.identifier)) return
    if (this.selectedIdentifiers().length >= this.maxValue) {
      this.setStatus(this.copy("max_models", { count: this.maxValue }))
      return
    }

    const card = document.createElement("div")
    card.dataset.modelCard = "true"
    card.dataset.identifier = model.identifier
    card.className = "flex items-start justify-between gap-3 rounded-xl border border-slate-200 bg-white px-3 py-2.5"

    const hidden = document.createElement("input")
    hidden.type = "hidden"
    hidden.name = this.nameValue
    hidden.value = model.identifier
    card.appendChild(hidden)

    const details = document.createElement("div")
    details.className = "min-w-0"
    const name = document.createElement("p")
    name.className = "truncate text-sm font-semibold text-slate-900"
    name.textContent = model.name
    details.appendChild(name)
    const provider = document.createElement("p")
    provider.className = "truncate text-xs text-slate-500"
    provider.textContent = `${model.provider} · ${model.identifier}`
    details.appendChild(provider)
    card.appendChild(details)

    const remove = document.createElement("button")
    remove.type = "button"
    remove.dataset.action = "model-browser#remove"
    remove.className = "shrink-0 rounded-lg px-2.5 py-1 text-xs font-semibold text-red-700 hover:bg-red-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-red-500"
    remove.textContent = this.copy("remove")
    remove.setAttribute("aria-label", this.copy("remove_model", { name: model.name }))
    card.appendChild(remove)

    this.selectedTarget.appendChild(card)
    this.updateCount()
    this.dispatchSelectionChange()
    this.renderResults({ source: "live" })
    this.setStatus(this.copy("model_added", { name: model.name }))
  }

  remove(event) {
    const card = event.currentTarget.closest("[data-model-card]")
    if (card) card.remove()
    this.updateCount()
    this.dispatchSelectionChange()
    this.renderResults({ source: "live" })
    this.setStatus(this.copy("model_removed"))
  }

  keydown(event) {
    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.move(1)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.move(-1)
    } else if (event.key === "Enter" && this.activeIndex >= 0) {
      event.preventDefault()
      const model = this.results[this.activeIndex]
      if (model) this.add(model)
    } else if (event.key === "Escape") {
      this.closeList()
    }
  }

  move(delta) {
    if (!this.options || this.options.length === 0) return
    this.activeIndex = (this.activeIndex + delta + this.options.length) % this.options.length
    this.options.forEach((option, index) => option.setAttribute("aria-selected", index === this.activeIndex ? "true" : "false"))
    const active = this.options[this.activeIndex]
    this.searchTarget.setAttribute("aria-activedescendant", active.id)
    active.scrollIntoView({ block: "nearest" })
  }

  openList() {
    this.listTarget.classList.remove("hidden")
    this.searchTarget.setAttribute("aria-expanded", "true")
  }

  closeList() {
    this.listTarget.classList.add("hidden")
    this.searchTarget.setAttribute("aria-expanded", "false")
    this.searchTarget.removeAttribute("aria-activedescendant")
    this.activeIndex = -1
  }

  selectedIdentifiers() {
    return Array.from(this.selectedTarget.querySelectorAll("[data-model-card]"))
      .map((card) => card.dataset.identifier)
      .filter(Boolean)
  }

  updateCount() {
    const count = this.selectedIdentifiers().length
    if (this.hasCountTarget) this.countTarget.textContent = `${count}/${this.maxValue}`
    if (this.hasMetaTarget) this.metaTarget.textContent = count === 1 ? this.copy("selected_one") : this.copy("selected_many", { count })
    if (this.hasEmptyTarget) this.emptyTarget.hidden = count > 0
  }

  copy(key, replacements = {}) {
    return Object.entries(replacements).reduce(
      (text, [name, value]) => text.replaceAll(`%{${name}}`, String(value)),
      this.messagesValue[key]
    )
  }

  setStatus(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message
  }

  dispatchSelectionChange() {
    this.element.dispatchEvent(new CustomEvent("workspace-models:changed", { bubbles: true }))
  }

  message(text) {
    const node = document.createElement("p")
    node.className = "px-3 py-6 text-center text-sm text-slate-500"
    node.textContent = text
    return node
  }

  badge(text, classes) {
    const span = document.createElement("span")
    span.className = `rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide ${classes}`
    span.textContent = text
    return span
  }

  metaItem(text) {
    const span = document.createElement("span")
    span.textContent = text
    return span
  }

  compatItem(label, compatible) {
    const span = document.createElement("span")
    span.className = compatible ? "font-medium text-emerald-700" : "text-slate-400"
    span.textContent = `${label} ${compatible ? "✓" : "—"}`
    return span
  }

  pricePerMillion(value) {
    if (value === null || value === undefined || value === "") return "—"
    const numeric = Number(value)
    if (!Number.isFinite(numeric)) return "—"
    const perMillion = numeric * 1_000_000
    return `$${perMillion >= 1 ? perMillion.toFixed(2) : perMillion.toFixed(3)}/M`
  }

  compactNumber(value) {
    const numeric = Number(value)
    if (!Number.isFinite(numeric) || numeric <= 0) return "—"
    if (numeric >= 1_000_000) return `${Number((numeric / 1_000_000).toFixed(1))}M`
    if (numeric >= 1_000) return `${Math.round(numeric / 1_000)}K`
    return `${numeric}`
  }

  escape(value) {
    return String(value).replace(/[&<>"']/g, (character) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;"
    })[character])
  }
}
