// On <body>: the action buttons. `run` POSTs to the button's url param with
// the page's token, after its confirm param (confirm), its prompt param
// (ask, sent as `input`) or, with the discard param, the remove dialog and
// its "discard uncommitted changes" checkbox (sent as `discard=1`). A name
// prompt param asks next, its input stopping at NAME_MAX characters,
// prefilled with the answer's slug (sent as `name`; not sent for the default).
// An input param is sent as `input` as is. A job this page started that
// created a worktree opens it when done ("select it when done"). A 403 that
// asks for a reload means the server restarted. Every question is one of
// dialogs.js's, never the browser's own box.
import { Controller } from "@hotwired/stimulus"
import { visit } from "@hotwired/turbo"
import { alert, ask, confirm, confirmWithCheckbox } from "../dialogs.js"

const started = new Set() // job ids this page started

// .scripts/lib.sh's WORKTREE_NAME_MAX_LEN and sanitize_worktree_name, for the
// name question only: the script sanitizes whatever is sent again. Sanitizing
// never lengthens, so a typed name capped at NAME_MAX stays within it.
const NAME_MAX = 40
const slug = (text) =>
  text.replace(/[^a-zA-Z0-9]/g, "-").toLowerCase().replace(/-+/g, "-").replace(/^-|-$/g, "").slice(0, NAME_MAX).replace(/-$/, "")

export default class extends Controller {
  static targets = ["job"]

  async run({ params: { url, confirm: question, prompt: asked, namePrompt, discard, input: given } }) {
    const body = new URLSearchParams()
    if (discard) {
      const answer = await confirmWithCheckbox(question, "discard uncommitted changes", "remove")
      if (!answer) return
      if (answer.checked) body.set("discard", "1")
    } else if (question && !(await confirm(question))) {
      return
    }
    if (asked) {
      const input = await ask(asked)
      if (input === null || input === "") return
      body.set("input", input)
      if (namePrompt) {
        // A PR number's branch is only known once the script asks GitHub.
        const pr = /^\d+$/.test(input)
        const fallback = pr ? "" : slug(input)
        const becomes = (typed) => (typed && slug(typed) !== typed ? `becomes ${slug(typed) || "nothing usable"}` : "")
        const name = await ask(pr ? `${namePrompt} Leave empty for the PR branch's name.` : namePrompt,
          { value: fallback, maxLength: NAME_MAX, preview: becomes, ok: "create" })
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
      await alert(await response.text())
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
      await alert("The dashboard is not reachable.")
      return null
    }
  }
}
