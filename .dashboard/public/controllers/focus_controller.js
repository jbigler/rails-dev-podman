// On <body>: when the tab becomes visible again, hint the server to refresh
// GitHub now. A 403 that asks for a reload means the server restarted and the
// page's token is stale.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.visible = () => { if (document.visibilityState === "visible") this.refresh() }
    document.addEventListener("visibilitychange", this.visible)
  }

  disconnect() {
    document.removeEventListener("visibilitychange", this.visible)
  }

  async refresh() {
    const token = document.querySelector('meta[name="dashboard-token"]')?.content ?? ""
    const shown = location.pathname.match(/^\/w\/(.+)$/)
    const body = new URLSearchParams(shown ? { w: decodeURIComponent(shown[1]) } : {})
    try {
      const response = await fetch("/refresh", { method: "POST", headers: { "X-Dashboard-Token": token }, body })
      if (response.status === 403 && response.headers.get("X-Dashboard-Reload") === "1") location.reload()
    } catch {
      // server down: the stream's reconnect brings the page back
    }
  }
}
