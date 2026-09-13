import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["automatic", "manual", "submit"]

  connect() {
    this.update()
  }

  update() {
    const selected = this.element.querySelector("input[name='translation_workspace[workflow_mode]']:checked")?.value || "manual"
    this.toggleSection(this.automaticTarget, selected === "automatic")
    this.toggleSection(this.manualTarget, selected === "manual")

    const canSubmit = selected === "automatic" ? this.sectionAvailable(this.automaticTarget) : this.sectionAvailable(this.manualTarget)
    this.submitTarget.disabled = !canSubmit
  }

  toggleSection(section, visible) {
    section.hidden = !visible
    section.querySelectorAll("input, select, textarea").forEach((control) => {
      if (control.type !== "hidden") control.disabled = !visible
    })
  }

  sectionAvailable(section) {
    return section.dataset.available === "true"
  }
}
