import { Controller } from "@hotwired/stimulus"

// Keeps the launch summary aligned with the unsaved workspace form. The server
// remains authoritative; this controller only mirrors visible selections.
export default class extends Controller {
  static targets = ["language", "source", "models", "terminology", "workflow"]
  static values = { panelUrl: String }

  connect() {
    this.panelObserver = new MutationObserver(() => this.update())
    const panel = this.element.querySelector("#workspace-glossary")
    if (panel) this.panelObserver.observe(panel, { childList: true, subtree: true })
    this.update()
  }

  disconnect() {
    this.panelObserver.disconnect()
  }

  changed(event) {
    if (event.target.name === "translation_workspace[glossary_revision_id]") {
      const details = event.target.closest("details")
      if (details) details.open = false
      const frame = this.element.querySelector("#workspace-terminology")
      const url = new URL(this.panelUrlValue, window.location.origin)
      if (event.target.value) url.searchParams.set("selected_revision_id", event.target.value)
      frame.src = url.toString()
    }
    this.update()
  }

  update() {
    const sourceLanguage = this.value("translation_workspace[source_language]")
    const targetLanguage = this.value("translation_workspace[target_language]")
    this.languageTarget.textContent = sourceLanguage && targetLanguage ? `${sourceLanguage} → ${targetLanguage}` : "Not set"

    const importedSource = this.element.querySelector("#workspace-source-import [data-workspace-upload-target='filename']")?.textContent.trim()
    const uploadPanel = this.element.querySelector("[data-source-mode-target='upload']")
    this.sourceTarget.textContent = importedSource || (uploadPanel && !uploadPanel.hidden ? "Uploaded file" : "Pasted text")

    const mode = this.checkedValue("translation_workspace[workflow_mode]") || "manual"
    this.workflowTarget.textContent = mode === "automatic" ? "Automatic" : "Manual"
    const count = this.element.querySelectorAll("#workspace-manual-models [data-model-card]").length
    this.modelsTarget.textContent = mode === "automatic" ? "Saved workflow" : `${count} selected`

    const terminology = this.element.querySelector("input[name='translation_workspace[glossary_revision_id]']:checked")
    if (terminology) this.terminologyTarget.textContent = terminology.dataset.workspaceSummaryName || "None"
  }

  value(name) {
    return this.element.querySelector(`[name='${name}']`)?.value.trim() || ""
  }

  checkedValue(name) {
    return this.element.querySelector(`[name='${name}']:checked`)?.value
  }
}
