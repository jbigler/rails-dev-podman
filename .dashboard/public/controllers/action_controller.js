// On <body>: the action buttons. `run` POSTs to the button's url param with
// the page's token, after its confirm param (confirm()), its prompt param
// (prompt(), sent as `input`) or, with the discard param, the remove dialog and
// its "discard uncommitted changes" checkbox (sent as `discard=1`). A name
// prompt param asks next in a dialog whose input stops at NAME_MAX characters,
// prefilled with the answer's slug (sent as `name`; not sent for the default).
// An input param is sent as `input` as is. A job this
// page started that created a worktree opens it when done ("select it when
// done"). A 403 that asks for a reload means the server restarted.
import { Controller } from "@hotwired/stimulus"
import { visit } from "@hotwired/turbo"

const started = new Set() // job ids this page started

// .scripts/lib.sh's WORKTREE_NAME_MAX_LEN and sanitize_worktree_name, for the
// name dialog only: the script sanitizes whatever is sent again. Sanitizing
// never lengthens, so a typed name capped at NAME_MAX stays within it.
const NAME_MAX = 40
const slug = (text) =>
  text.replace(/[^a-zA-Z0-9]/g, "-").toLowerCase().replace(/-+/g, "-").replace(/^-|-$/g, "").slice(0, NAME_MAX).replace(/-$/, "")

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
        const name = await this.nameDialog(pr ? `${namePrompt} Leave empty for the PR branch's name.` : namePrompt, fallback)
        if (name === null) return
        // The prefill kept is no name: the script's default also dodges a taken slug.
        if (name !== "" && name !== fallback) body.set("name", name)
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

  // A one-line input capped at NAME_MAX characters, prefilled with `value`,
  // showing the name it becomes. → the trimmed answer, null when cancelled.
  nameDialog(question, value) {
    return new Promise((resolve) => {
      const dialog = document.createElement("dialog")
      dialog.className = "confirm"
      const form = document.createElement("form")
      form.method = "dialog"
      const text = document.createElement("p")
      text.textContent = question
      const box = document.createElement("input")
      box.type = "text"
      box.maxLength = NAME_MAX
      box.value = value
      box.size = NAME_MAX
      box.spellcheck = false
      box.autocomplete = "off"
      const becomes = document.createElement("p")
      becomes.className = "muted"
      const show = () => {
        const typed = box.value.trim()
        becomes.textContent = `${box.value.length}/${NAME_MAX}` + (typed && slug(typed) !== typed ? ` · becomes ${slug(typed) || "nothing usable"}` : "")
      }
      box.addEventListener("input", show)
      show()
      // Only "create" submits, so Enter in the box creates; Escape cancels.
      const cancel = this.dialogButton("cancel", "cancel")
      cancel.type = "button"
      cancel.addEventListener("click", () => dialog.close("cancel"))
      const buttons = document.createElement("menu")
      buttons.append(cancel, this.dialogButton("create", "ok"))
      form.append(text, box, becomes, buttons)
      dialog.append(form)
      dialog.addEventListener("close", () => {
        dialog.remove()
        resolve(dialog.returnValue === "ok" ? box.value.trim() : null)
      })
      document.body.append(dialog)
      dialog.showModal()
      box.select()
    })
  }

  dialogButton(text, value) {
    const button = document.createElement("button")
    button.value = value
    button.textContent = text
    return button
  }
}
