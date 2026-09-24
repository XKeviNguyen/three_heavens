import { Controller } from "@hotwired/stimulus"

// Keeps the launch summary aligned with the unsaved workspace form. The server
// remains authoritative; this controller only mirrors visible selections.
export default class extends Controller {
  static targets = ["language", "source", "models", "terminology", "workflow"]
  static values = { panelUrl: String, messages: Object }

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
    this.languageTarget.textContent = sourceLanguage && targetLanguage ? `${sourceLanguage} → ${targetLanguage}` : this.messagesValue.not_set

    const importedSource = this.element.querySelector("#workspace-source-import [data-workspace-upload-target='filename']")?.textContent.trim()
    const uploadPanel = this.element.querySelector("[data-source-mode-target='upload']")
    this.sourceTarget.textContent = importedSource || (uploadPanel && !uploadPanel.hidden ? this.messagesValue.uploaded_file : this.messagesValue.pasted_text)

    const mode = this.checkedValue("translation_workspace[workflow_mode]") || "manual"
    this.workflowTarget.textContent = mode === "automatic" ? this.messagesValue.automatic : this.messagesValue.manual
    const count = this.element.querySelectorAll("#workspace-manual-models [data-model-card]").length
    this.modelsTarget.textContent = mode === "automatic" ? this.messagesValue.saved_workflow : this.messagesValue.selected_count.replace("%{count}", String(count))

    const terminology = this.element.querySelector("input[name='translation_workspace[glossary_revision_id]']:checked")
    if (terminology) this.terminologyTarget.textContent = terminology.dataset.workspaceSummaryName || this.messagesValue.none
  }

  value(name) {
    return this.element.querySelector(`[name='${name}']`)?.value.trim() || ""
  }

  checkedValue(name) {
    return this.element.querySelector(`[name='${name}']:checked`)?.value
  }
}
