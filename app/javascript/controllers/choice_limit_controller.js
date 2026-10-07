import { Controller } from "@hotwired/stimulus"

// Once the maximum number of boxes is checked the rest are disabled, so the
// form never holds a selection the draft and the launch both refuse.
export default class extends Controller {
  static values = { max: Number }

  connect() {
    this.update()
  }

  update() {
    const boxes = Array.from(this.element.querySelectorAll("input[type='checkbox']"))
    const full = boxes.filter(box => box.checked).length >= this.maxValue
    boxes.forEach(box => { box.disabled = full && !box.checked })
  }
}
