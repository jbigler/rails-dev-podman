// On <body>: keyboard navigation of the worktree list. ↑/↓ (k/j) open the
// previous/next worktree, Home/End (g/G) the first/last, without wrapping; ↓/j
// on "/" opens the first. Not while typing, while a <dialog> is open, or with
// Ctrl/Alt/Meta (Shift only for G). The selection is read from the DOM each
// time (the row marked selected, else #detail's data-worktree), and the
// selected row is scrolled into view after every visit and key move, and after
// a streamed replace of the list only if it was on screen before (no other
// frame scrolls the page, so reading output further down is never interrupted).
import { Controller } from "@hotwired/stimulus"
import { visit } from "@hotwired/turbo"

const MOVES = { ArrowDown: 1, j: 1, ArrowUp: -1, k: -1, Home: "first", g: "first", End: "last", G: "last" }

export default class extends Controller {
  connect() {
    this.streamed = (event) => {
      if (event.target.getAttribute("target") !== "worktrees") return
      const shown = this.onScreen(this.selected(this.rows()))
      if (!shown) return
      const render = event.detail.render
      event.detail.render = async (stream) => {
        await render(stream)
        this.reveal()
      }
    }
    this.loaded = () => this.reveal()
    document.addEventListener("turbo:before-stream-render", this.streamed)
    document.addEventListener("turbo:load", this.loaded)
    this.reveal()
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.streamed)
    document.removeEventListener("turbo:load", this.loaded)
  }

  key(event) {
    const move = MOVES[event.key]
    if (move === undefined || event.ctrlKey || event.altKey || event.metaKey) return
    if (event.shiftKey && event.key !== "G") return
    if (event.target.closest?.("input, textarea, select, [contenteditable]")) return
    if (document.querySelector("dialog[open]")) return

    const rows = this.rows()
    if (rows.length === 0) return
    const at = rows.indexOf(this.selected(rows))
    let to
    if (move === "first") to = 0
    else if (move === "last") to = rows.length - 1
    else if (at === -1) to = move === 1 ? 0 : -1
    else to = Math.min(Math.max(at + move, 0), rows.length - 1)
    event.preventDefault()
    if (to === -1 || to === at) return
    this.open(rows[at], rows[to])
  }

  rows() {
    return Array.from(document.querySelectorAll("#worktrees a.row"))
  }

  selected(rows) {
    const marked = rows.find((row) => row.classList.contains("selected"))
    if (marked) return marked
    const name = document.getElementById("detail")?.dataset.worktree
    return name ? rows.find((row) => row.querySelector(".c-name")?.textContent === name) : undefined
  }

  // Marks the row at once (so a held key keeps moving while the visit loads), then visits it.
  open(from, to) {
    if (from) {
      from.classList.remove("selected")
      from.removeAttribute("aria-current")
    }
    to.classList.add("selected")
    to.setAttribute("aria-current", "page")
    to.scrollIntoView({ block: "nearest" })
    visit(to.href, { action: "replace" })
  }

  reveal() {
    const rows = this.rows()
    this.selected(rows)?.scrollIntoView({ block: "nearest" })
  }

  // Any part of the row inside the viewport.
  onScreen(row) {
    if (!row) return false
    const box = row.getBoundingClientRect()
    return box.bottom > 0 && box.top < window.innerHeight
  }
}
