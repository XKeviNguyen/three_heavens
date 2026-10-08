import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  swap() {
    const source = this.element.querySelector("[name='translation_workspace[source_language]']")
    const target = this.element.querySelector("[name='translation_workspace[target_language]']")
    if (!source || !target) return
    const previous = source.value
    source.value = target.value
    target.value = previous
    for (const field of [source, target]) {
      const visible = field.closest("[data-controller='combobox']")?.querySelector("[data-combobox-target='input']")
      if (visible) visible.value = field.value
      field.dispatchEvent(new Event("input", { bubbles: true }))
      field.dispatchEvent(new Event("change", { bubbles: true }))
    }
    source.closest("[data-controller='combobox']")?.querySelector("[data-combobox-target='input']")?.focus()
  }
}
