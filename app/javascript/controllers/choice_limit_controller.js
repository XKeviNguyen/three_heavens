import { Controller } from "@hotwired/stimulus"

// Once the maximum number of boxes is checked the rest are disabled, so the
// form never holds a selection the draft and the launch both refuse. The
// optional count reads the boxes themselves: the browser may restore checked
// boxes on reload that the server-rendered count never saw.
export default class extends Controller {
  static targets = ["count"]
  static values = { max: Number, countTemplate: String }

  connect() {
    this.update()
  }

  update() {
    const boxes = Array.from(this.element.querySelectorAll("input[type='checkbox']"))
    const checked = boxes.filter(box => box.checked).length
    const full = checked >= this.maxValue
    boxes.forEach(box => { box.disabled = full && !box.checked })
    if (this.hasCountTarget && this.countTemplateValue) {
      this.countTarget.textContent = this.countTemplateValue.replace("__COUNT__", String(checked))
    }
  }
}
