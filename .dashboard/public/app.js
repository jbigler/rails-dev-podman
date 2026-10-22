// Turbo for navigation and streamed fragments; Stimulus for the controllers
// (registered by later imports through the exported application).
import "@hotwired/turbo"
import { Application } from "@hotwired/stimulus"

export const application = Application.start()
window.Stimulus = application
