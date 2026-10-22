// A copy button: puts its text value (the branch name) on the clipboard and
// says so on the button for a moment.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { text: String }

  async copy() {
    const label = this.element.textContent
    try {
      await navigator.clipboard.writeText(this.textValue)
      this.element.textContent = "copied"
    } catch {
      this.element.textContent = "copy failed"
    }
    setTimeout(() => { this.element.textContent = label }, 1200)
  }
}
