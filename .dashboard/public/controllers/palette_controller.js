// On <body>: the task palette. Opens from the header's "tasks" button, ":" or
// Ctrl-K (on a worktree's page) as a dialog holding GET /palette?w=<W>; typing
// filters the names by fuzzy subsequence, arrows move, Enter runs the selected
// task (prompting for its arguments when the row says required/optional, and
// asking first when the row carries data-palette-confirm) by POSTing task and
// args to the list's url.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["item"]

  key(event) {
    const typing = event.target.closest?.("input, textarea, select, [contenteditable]")
    const ctrlK = (event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k"
    if (ctrlK || (event.key === ":" && !typing && !event.ctrlKey && !event.metaKey && !event.altKey)) {
      event.preventDefault()
      this.open()
    }
  }

  async open() {
    const name = this.worktree()
    if (name === null || this.dialog) return
    const response = await fetch(`/palette?w=${encodeURIComponent(name)}`)
    if (!response.ok) {
      window.alert(await response.text())
      return
    }
    this.show(await response.text())
  }

  // The worktree the page shows, from its /w/<name> path; null elsewhere.
  worktree() {
    const match = location.pathname.match(/^\/w\/([^/]+)$/)
    return match ? decodeURIComponent(match[1]) : null
  }

  show(html) {
    const dialog = document.createElement("dialog")
    dialog.className = "palette"
    const filter = document.createElement("input")
    filter.type = "search"
    filter.placeholder = "task"
    filter.setAttribute("aria-label", "filter tasks")
    const holder = document.createElement("div")
    holder.innerHTML = html // the server's escaped fragment
    dialog.append(filter, holder)
    filter.addEventListener("input", () => this.filter(filter.value))
    filter.addEventListener("keydown", (event) => this.navigate(event))
    dialog.addEventListener("close", () => {
      dialog.remove()
      this.dialog = null
    })
    this.dialog = dialog
    this.list = holder.querySelector("[data-palette-url]")
    document.body.append(dialog)
    dialog.showModal()
    this.filter("")
  }

  filter(query) {
    const q = query.toLowerCase()
    this.visible = this.itemTargets.filter((item) => {
      const shown = this.matches(item.dataset.paletteName.toLowerCase(), q)
      item.hidden = !shown
      return shown
    })
    this.select(0)
  }

  // Every character of q appears in name, in order.
  matches(name, q) {
    let at = 0
    for (const char of q) {
      at = name.indexOf(char, at)
      if (at === -1) return false
      at += 1
    }
    return true
  }

  select(index) {
    this.itemTargets.forEach((item) => item.classList.remove("selected"))
    if (this.visible.length === 0) return
    this.index = (index + this.visible.length) % this.visible.length
    const item = this.visible[this.index]
    item.classList.add("selected")
    item.scrollIntoView({ block: "nearest" })
  }

  navigate(event) {
    if (event.key === "ArrowDown") this.select(this.index + 1)
    else if (event.key === "ArrowUp") this.select(this.index - 1)
    else if (event.key === "Enter" && this.visible.length) this.run(this.visible[this.index])
    else return
    event.preventDefault()
  }

  pick(event) {
    this.run(event.currentTarget.closest("[data-palette-name]"))
  }

  async run(item) {
    const { paletteName: task, paletteArgs: kind, paletteConfirm: question } = item.dataset
    if (question && !window.confirm(question)) return
    let args = ""
    if (kind) {
      const answer = window.prompt(`${task} arguments (${kind}):`)
      if (answer === null) return
      if (kind === "required" && answer.trim() === "") return
      args = answer.trim()
    }
    const url = this.list.dataset.paletteUrl
    this.dialog.close()
    const token = document.querySelector('meta[name="dashboard-token"]')?.content ?? ""
    try {
      const response = await fetch(url, { method: "POST", headers: { "X-Dashboard-Token": token }, body: new URLSearchParams({ task, args }) })
      if (response.status === 403 && response.headers.get("X-Dashboard-Reload") === "1") location.reload()
      else if (response.status >= 400) window.alert(await response.text())
    } catch {
      window.alert("The dashboard is not reachable.")
    }
  }
}
