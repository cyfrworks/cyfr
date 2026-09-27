// The shipped vault page: every living entry by name, kind and status,
// whether a consent binds it and when it last changed, from `vault.status`,
// which never answers a value. An entry is added by asking the shell for
// it (`cyfr.credential(name)`): the person types the value into the
// shell's own prompt, it goes to the vault, and this page learns only
// whether an entry was saved. An entry is deleted through `vault.delete`,
// which the gate decides. Every text the page shows is set as text.

const cyfr = window.cyfr
const nameInput = document.getElementById("add-name")
const addButton = document.getElementById("add-button")
const refreshButton = document.getElementById("refresh-button")
const body = document.getElementById("entries-body")
const empty = document.getElementById("entries-empty")
const status = document.getElementById("status")

const state = {entries: [], confirming: null, busy: false}

function say(text) {
  status.textContent = text || ""
}

function el(tag, className, text) {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text !== undefined && text !== null) node.textContent = String(text)
  return node
}

function changed(at) {
  if (typeof at !== "string") return "—"
  const date = new Date(at)
  return Number.isNaN(date.getTime()) ? "—" : date.toLocaleString()
}

// ---- reading -------------------------------------------------------------

async function load() {
  try {
    const answer = await cyfr.action("vault.status", {})
    state.entries = Array.isArray(answer && answer.entries) ? answer.entries : []
    render()
    return true
  } catch (error) {
    say(`The vault could not be read: ${error.message}`)
    return false
  }
}

// ---- adding --------------------------------------------------------------

async function add() {
  const name = nameInput.value.trim()
  if (name === "") {
    say("Name the entry first.")
    nameInput.focus()
    return
  }
  if (state.busy) return
  state.busy = true
  addButton.disabled = true

  try {
    const {saved} = await cyfr.credential(name)
    if (saved) {
      nameInput.value = ""
      await load()
      say(`Saved ${name}.`)
    } else {
      say(`Nothing was saved for ${name}.`)
    }
  } catch (error) {
    say(`The shell could not ask for ${name}: ${error.message}`)
  } finally {
    state.busy = false
    addButton.disabled = false
    nameInput.focus()
  }
}

// ---- deleting ------------------------------------------------------------

async function remove(entry) {
  if (state.confirming !== entry.id) {
    state.confirming = entry.id
    render()
    const confirm = body.querySelector(`[data-confirm="${CSS.escape(entry.id)}"]`)
    if (confirm) confirm.focus()
    say(`Delete ${entry.name}? Press Confirm delete to go on.`)
    return
  }

  state.confirming = null
  try {
    await cyfr.action("vault.delete", {id: entry.id})
    await load()
    say(`Deleted ${entry.name}.`)
  } catch (error) {
    render()
    say(`${entry.name} was not deleted: ${error.message}`)
  }
}

// ---- drawing -------------------------------------------------------------

function row(entry) {
  const tr = el("tr")
  tr.dataset.entry = entry.name

  const name = el("th", "name", entry.name)
  name.scope = "row"
  tr.append(name)
  tr.append(el("td", null, entry.kind))
  tr.append(el("td", null, entry.status))
  tr.append(el("td", null, entry.bound ? "Yes" : "No"))
  tr.append(el("td", null, changed(entry.updated_at)))

  const actions = el("td", "actions")
  const confirming = state.confirming === entry.id
  const button = el("button", confirming ? "danger" : null, confirming ? "Confirm delete" : "Delete")
  button.type = "button"
  button.setAttribute("aria-label", `${confirming ? "Confirm delete of" : "Delete"} ${entry.name}`)
  if (confirming) button.dataset.confirm = entry.id
  button.addEventListener("click", () => remove(entry))
  actions.append(button)

  if (confirming) {
    const cancel = el("button", null, "Keep")
    cancel.type = "button"
    cancel.setAttribute("aria-label", `Keep ${entry.name}`)
    cancel.addEventListener("click", () => {
      state.confirming = null
      render()
      say("")
    })
    actions.append(cancel)
  }

  tr.append(actions)
  return tr
}

function render() {
  body.replaceChildren(...state.entries.map(row))
  empty.textContent = state.entries.length === 0 ? "No entries yet." : ""
}

// ---- wiring --------------------------------------------------------------

addButton.addEventListener("click", add)
// The frame is sandboxed without forms, so Enter is heard on the field.
nameInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault()
    add()
  }
})
refreshButton.addEventListener("click", async () => {
  if (await load()) say("Read again.")
})

if (cyfr) {
  cyfr.ready()
  load()
} else {
  say("This page runs inside the shell.")
}
