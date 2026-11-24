"use strict"
// The page's one read token, from the address main loaded, kept for this
// window alone: the address keeps no copy of it.
const fragment = new URLSearchParams(location.hash.slice(1))
if (fragment.get("read")) sessionStorage.setItem("read", fragment.get("read"))
history.replaceState(null, "", "/update/")
const token = sessionStorage.getItem("read") || ""
const $ = (id) => document.getElementById(id)
// The yes is a navigation to an address main alone answers, naming the
// offer shown by its number: the page starts nothing itself.
function show(r) {
  const o = r.offer
  $("status").textContent = r.running ? "CYFR is being updated." : r.outcome || (o ? "" : "Reading the newest release…")
  $("status").hidden = $("status").textContent === ""
  $("releases").textContent = o ? (o.target && o.step === "app"
    ? `This CYFR app is release ${o.app}; release ${o.target} is the newest.` : `This CYFR app is release ${o.app}.`) : ""
  $("says").replaceChildren(...(o?.says ?? []).map((line) => {
    const p = document.createElement("p")
    p.textContent = line
    return p
  }))
  $("terminal").hidden = !o?.terminal
  $("line").textContent = o?.terminal ?? ""
  $("refused").hidden = !r.refused
  $("refused").textContent = r.refused ?? ""
  const yes = $("yes")
  const offered = !!o?.step && !r.running
  yes.hidden = !offered
  if (offered) {
    yes.href = "/update/start?offer=" + o.offer
    yes.textContent = o.step === "app" ? `Update the CYFR app to ${o.target}` : `Update your CYFR to ${o.target}`
  }
  $("said").hidden = !r.record
  $("record").textContent = r.record ?? ""
  // What the window's title says, which the system shows: the state, in
  // its fewest words.
  document.title = r.running ? "Update CYFR — updating" : offered ? `Update CYFR — release ${o.target}`
    : o?.terminal ? "Update CYFR — needs a terminal" : "Update CYFR"
  const focus = offered ? yes : $("close")
  if (document.activeElement !== focus) focus.focus()
}
async function watch() {
  let seen = 0
  for (;;) {
    try {
      const r = await fetch("/update/read", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({token, seen})})
      if (r.status === 503) return
      if (!r.ok) throw new Error(String(r.status))
      const text = await r.text()
      if (text) {
        const answer = JSON.parse(text)
        seen = answer.seq
        show(answer)
      }
    } catch {
      $("status").hidden = false
      $("status").textContent = "What the update offers could not be read."
      await new Promise((r) => setTimeout(r, 2000))
    }
  }
}
watch()
