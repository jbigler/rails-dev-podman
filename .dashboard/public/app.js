// Turbo for navigation and streamed fragments; Stimulus for the controllers
// (registered here and by later imports through the exported application).
import "@hotwired/turbo"
import { Application } from "@hotwired/stimulus"
import FocusController from "./controllers/focus_controller.js"
import NotifyController from "./controllers/notify_controller.js"
import ActionController from "./controllers/action_controller.js"
import PanelController from "./controllers/panel_controller.js"
import ClipboardController from "./controllers/clipboard_controller.js"
import PaletteController from "./controllers/palette_controller.js"
import ListnavController from "./controllers/listnav_controller.js"

export const application = Application.start()
window.Stimulus = application
application.register("focus", FocusController)
application.register("notify", NotifyController)
application.register("action", ActionController)
application.register("panel", PanelController)
application.register("clipboard", ClipboardController)
application.register("palette", PaletteController)
application.register("listnav", ListnavController)

// The header carries the tab title ("◆ N · wt · repo"); a streamed header brings a new one.
document.addEventListener("turbo:before-stream-render", (event) => {
  const render = event.detail.render
  event.detail.render = async (stream) => {
    await render(stream)
    const title = document.getElementById("header")?.dataset.title
    if (title) document.title = title
  }
})
