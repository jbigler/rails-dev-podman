// Turbo for navigation and streamed fragments; Stimulus for the controllers
// (registered here and by later imports through the exported application).
import "@hotwired/turbo"
import { Application } from "@hotwired/stimulus"
import FocusController from "./controllers/focus_controller.js"
import NotifyController from "./controllers/notify_controller.js"

export const application = Application.start()
window.Stimulus = application
application.register("focus", FocusController)
application.register("notify", NotifyController)

// The header carries the tab title ("◆ N · wt · repo"); a streamed header brings a new one.
document.addEventListener("turbo:before-stream-render", (event) => {
  const render = event.detail.render
  event.detail.render = async (stream) => {
    await render(stream)
    const title = document.getElementById("header")?.dataset.title
    if (title) document.title = title
  }
})
