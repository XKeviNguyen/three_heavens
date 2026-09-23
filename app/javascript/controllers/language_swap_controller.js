import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  swap() {
    const source = this.element.querySelector("[name='translation_workspace[source_language]']")
    const target = this.element.querySelector("[name='translation_workspace[target_language]']")
    if (!source || !target) return
    const previous = source.value
    source.value = target.value
    target.value = previous
    source.dispatchEvent(new Event("input", { bubbles: true }))
    target.dispatchEvent(new Event("input", { bubbles: true }))
    source.focus()
  }
}
