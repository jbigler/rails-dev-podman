// On <body>: the action buttons. `run` POSTs to the button's url param with
// the page's token, after its confirm param (confirm()), its prompt param
// (prompt(), sent as `input`) or, with the discard param, the remove dialog and
// its "discard uncommitted changes" checkbox (sent as `discard=1`). A name
// prompt param asks next, prefilled with the answer's slug (sent as `name`;
// empty for the default). An input param is sent as `input` as is. A job this
// page started that created a worktree opens it when done ("select it when
// done"). A 403 that asks for a reload means the server restarted.
import { Controller } from "@hotwired/stimulus"
import { visit } from "@hotwired/turbo"

const started = new Set() // job ids this page started

// .scripts/lib.sh's sanitize_worktree_name, for the prefill only: the script
// sanitizes whatever is sent again.
const slug = (text) =>
  text.replace(/[^a-zA-Z0-9]/g, "-").toLowerCase().replace(/-+/g, "-").replace(/^-|-$/g, "").slice(0, 40).replace(/-$/, "")

export default class extends Controller {
  static targets = ["job"]

  async run({ params: { url, confirm: question, prompt: ask, namePrompt, discard, input: given } }) {
    const body = new URLSearchParams()
    if (discard) {
      const answer = await this.removeDialog(question)
      if (!answer) return
      if (answer.discard) body.set("discard", "1")
    } else if (question && !window.confirm(question)) {
      return
    }
    if (ask) {
      const input = window.prompt(ask)
      if (input === null || input.trim() === "") return
      body.set("input", input.trim())
      if (namePrompt) {
        // A PR number's branch is only known once the script asks GitHub.
        const pr = /^\d+$/.test(input.trim())
        const fallback = pr ? "" : slug(input.trim())
        const name = window.prompt(pr ? `${namePrompt}\nLeave empty for the PR branch's name.` : namePrompt, fallback)
        if (name === null) return
        // The prefill kept is no name: the script's default also dodges a taken slug.
        if (name.trim() !== "" && name.trim() !== fallback) body.set("name", name.trim())
      }
    } else if (given) {
      body.set("input", given)
    }

    const response = await this.post(url, body)
    if (!response) return
    if (response.status === 202) {
      const id = (await response.text()).trim()
      started.add(id)
      const job = document.getElementById(`job-${id}`)
      if (job) this.jobTargetConnected(job) // its frames may have come first
    } else if (response.status >= 400) {
      window.alert(await response.text())
    }
  }

  async cancel({ params: { url } }) {
    await this.post(url, new URLSearchParams())
  }

  // A streamed job fragment: a finished job of this page's that created a worktree opens it.
  jobTargetConnected(element) {
    const { jobId, jobState, jobCreated } = element.dataset
    if (jobState === "running" || !started.has(jobId)) return

    started.delete(jobId)
    if (jobCreated) visit(jobCreated)
  }

  async post(url, body) {
    const token = document.querySelector('meta[name="dashboard-token"]')?.content ?? ""
    try {
      const response = await fetch(url, { method: "POST", headers: { "X-Dashboard-Token": token }, body })
      if (response.status === 403 && response.headers.get("X-Dashboard-Reload") === "1") {
        location.reload()
        return null
      }
      return response
    } catch {
      window.alert("The dashboard is not reachable.")
      return null
    }
  }

  // → { discard } when confirmed, null when cancelled.
  removeDialog(question) {
    return new Promise((resolve) => {
      const dialog = document.createElement("dialog")
      dialog.className = "confirm"
      const form = document.createElement("form")
      form.method = "dialog"
      const text = document.createElement("p")
      text.textContent = question
      const label = document.createElement("label")
      const box = document.createElement("input")
      box.type = "checkbox"
      label.append(box, " discard uncommitted changes")
      const buttons = document.createElement("menu")
      buttons.append(this.dialogButton("cancel", "cancel"), this.dialogButton("remove", "ok"))
      form.append(text, label, buttons)
      dialog.append(form)
      dialog.addEventListener("close", () => {
        dialog.remove()
        resolve(dialog.returnValue === "ok" ? { discard: box.checked } : null)
      })
      document.body.append(dialog)
      dialog.showModal()
    })
  }

  dialogButton(text, value) {
    const button = document.createElement("button")
    button.value = value
    button.textContent = text
    return button
  }
}
