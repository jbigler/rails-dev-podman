// Stand-ins for window.alert/confirm/prompt, whose boxes are the browser's own
// and cannot take the page's colours: each opens a modal <dialog class="confirm">
// and resolves when it closes. Only the ok button submits, so Enter in a field
// means ok; Escape and cancel resolve as cancelled.

function paragraph(content, className) {
  const p = document.createElement("p")
  p.textContent = content
  if (className) p.className = className
  return p
}

function okButton(label) {
  const button = document.createElement("button")
  button.value = "ok"
  button.textContent = label
  return button
}

function cancelButton() {
  const button = document.createElement("button")
  button.type = "button"
  button.textContent = "cancel"
  button.addEventListener("click", () => button.closest("dialog").close("cancel"))
  return button
}

// nodes and buttons into a form in a modal; → the promise of result(ok?).
function modal(nodes, buttons, result, opened = () => {}) {
  return new Promise((resolve) => {
    const dialog = document.createElement("dialog")
    dialog.className = "confirm"
    const form = document.createElement("form")
    form.method = "dialog"
    const menu = document.createElement("menu")
    menu.append(...buttons)
    form.append(...nodes, menu)
    dialog.append(form)
    dialog.addEventListener("close", () => {
      dialog.remove()
      resolve(result(dialog.returnValue === "ok"))
    })
    document.body.append(dialog)
    dialog.showModal()
    opened()
  })
}

export const alert = (message) => modal([paragraph(message, "dialog-message")], [okButton("ok")], () => undefined)

// → true for ok.
export const confirm = (question, ok = "ok") => modal([paragraph(question)], [cancelButton(), okButton(ok)], (yes) => yes)

// → { checked } for ok, null when cancelled.
export function confirmWithCheckbox(question, checkboxLabel, ok = "ok") {
  const label = document.createElement("label")
  const box = document.createElement("input")
  box.type = "checkbox"
  label.append(box, ` ${checkboxLabel}`)
  return modal([paragraph(question), label], [cancelButton(), okButton(ok)], (yes) => (yes ? { checked: box.checked } : null))
}

// A one-line answer, prefilled with `value`. maxLength caps what can be typed
// (shown as n/max); preview(text) → a note shown under the box, or "".
// → the trimmed answer, null when cancelled.
export function ask(question, { value = "", maxLength, preview, ok = "ok" } = {}) {
  const box = document.createElement("input")
  box.type = "text"
  box.value = value
  box.spellcheck = false
  box.autocomplete = "off"
  if (maxLength) {
    box.maxLength = maxLength
    box.size = maxLength
  }
  const nodes = [paragraph(question), box]
  if (maxLength || preview) {
    const note = paragraph("", "muted dialog-note")
    const show = () => {
      const parts = [maxLength ? `${box.value.length}/${maxLength}` : "", preview ? preview(box.value.trim()) : ""]
      note.textContent = parts.filter(Boolean).join(" · ")
    }
    box.addEventListener("input", show)
    show()
    nodes.push(note)
  }
  return modal(nodes, [cancelButton(), okButton(ok)], (yes) => (yes ? box.value.trim() : null), () => box.select())
}
