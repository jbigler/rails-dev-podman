// The action panel: remembers whether it is collapsed, opens for a new job, and
// keeps a running job's output scrolled to its end (the fragment is replaced
// with every streamed update).
import { Controller } from "@hotwired/stimulus"

const KEY = "dashboard-panel-open"

export default class extends Controller {
  static targets = ["details", "jobs"]

  connect() {
    const saved = localStorage.getItem(KEY)
    if (saved !== null) this.detailsTarget.open = saved === "1"
    this.observer = new MutationObserver((mutations) => this.changed(mutations))
    this.observer.observe(this.jobsTarget, { childList: true })
    this.autoscroll()
  }

  disconnect() {
    this.observer.disconnect()
  }

  toggle() {
    localStorage.setItem(KEY, this.detailsTarget.open ? "1" : "0")
  }

  changed(mutations) {
    const appended = mutations.some((m) => [...m.addedNodes].some((node) => node.dataset?.jobState === "running" && !m.removedNodes.length))
    if (appended) this.detailsTarget.open = true
    this.autoscroll()
  }

  autoscroll() {
    const running = this.jobsTarget.querySelectorAll('[data-job-state="running"] .job-output')
    running.forEach((output) => { output.scrollTop = output.scrollHeight })
    const last = this.jobsTarget.lastElementChild
    if (last?.dataset.jobState === "running") this.jobsTarget.scrollTop = this.jobsTarget.scrollHeight
  }
}
