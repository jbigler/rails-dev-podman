// Browser notifications for an agent waiting on a permission or a question.
// The server sends <turbo-stream action="notify" title=… body=… tag=…>; the
// header's button (the "ask" target) asks for permission and hides once the
// browser has an answer.
import { Controller } from "@hotwired/stimulus"
import { StreamActions } from "@hotwired/turbo"

StreamActions.notify = function () {
  if (!("Notification" in window) || Notification.permission !== "granted") return

  new Notification(this.getAttribute("title") ?? "", { body: this.getAttribute("body") ?? "", tag: this.getAttribute("tag") ?? "" })
}

export default class extends Controller {
  static targets = ["ask"]

  // The header is replaced by streamed frames, so each new button gets its state here.
  askTargetConnected(button) {
    button.hidden = !("Notification" in window) || Notification.permission !== "default"
  }

  async ask() {
    if (!("Notification" in window)) return

    await Notification.requestPermission()
    this.askTargets.forEach((button) => this.askTargetConnected(button))
  }
}
