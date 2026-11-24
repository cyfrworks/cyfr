"use strict"
// The rail's one read token, from the address main loaded, kept for this
// view alone: the address keeps no copy of it.
const fragment = new URLSearchParams(location.hash.slice(1))
if (fragment.get("read")) sessionStorage.setItem("read", fragment.get("read"))
history.replaceState(null, "", "/rail/")
const token = sessionStorage.getItem("read") || ""
const list = document.getElementById("cyfrs")
const said = document.getElementById("said")
// A press is a navigation to an address main alone answers: the rail
// changes nothing itself.
const go = (path, home) => location.assign(path + "?cyfr=" + encodeURIComponent(home))
// The hue a CYFR's tile takes, from its whole address: two CYFRs whose
// names begin alike are still told apart.
function hue(home) {
  let h = 0
  for (const c of home) h = (h * 31 + c.codePointAt(0)) >>> 0
  return h % 360
}
// What a tile names: the host's first label and its port when it has
// one, or the folder of a CYFR on this computer; its initials are the
// first letters of that name's words, or its first two letters.
function named(c) {
  const u = new URL(c.cyfr)
  const base = c.folder ? c.folder.split(/[\\/]/).filter(Boolean).pop() : u.hostname.split(".")[0]
  const name = base + (!c.folder && u.port ? ":" + u.port : "")
  const words = base.split(/[^\p{L}\p{N}]+/u).filter(Boolean)
  const initials = words.length > 1 ? words[0][0] + words[1][0] : (words[0] ?? "?").slice(0, 2)
  return {initials: initials.toUpperCase(), name}
}
function row(c) {
  const {initials, name} = named(c)
  const li = document.createElement("li")
  const a = document.createElement("a")
  a.className = "cyfr" + (c.forgetting ? " gone" : "") + (c.failed ? " failed" : "")
  a.href = "/rail/select?cyfr=" + encodeURIComponent(c.cyfr)
  a.title = c.cyfr
  const state = c.failed ? ", not forgotten: open its menu to try again" : c.forgetting ? ", being forgotten" : ""
  a.setAttribute("aria-label", c.cyfr + state)
  if (c.open) a.setAttribute("aria-current", "page")
  a.style.setProperty("--hue", String(hue(c.cyfr)))
  const tile = document.createElement("span")
  tile.className = "tile"
  tile.setAttribute("aria-hidden", "true")
  tile.textContent = initials
  const label = document.createElement("span")
  label.className = "name"
  label.textContent = name
  a.append(tile, label)
  // Its menu, which main draws: the context key, Shift+F10 or Delete,
  // a press held on a touch screen, or the pointer's other button.
  const menu = (e) => { e.preventDefault(); go("/rail/menu", c.cyfr) }
  a.addEventListener("contextmenu", menu)
  a.addEventListener("keydown", (e) => {
    if (e.key === "ContextMenu" || e.key === "Delete" || (e.key === "F10" && e.shiftKey)) menu(e)
  })
  let held = 0
  a.addEventListener("touchstart", () => { held = setTimeout(() => { held = -1; go("/rail/menu", c.cyfr) }, 550) }, {passive: true})
  const release = (e) => { if (held === -1) e.preventDefault(); clearTimeout(held); held = 0 }
  a.addEventListener("touchend", release)
  a.addEventListener("touchmove", () => { clearTimeout(held); held = 0 }, {passive: true})
  if (c.forgetting && !c.failed) a.addEventListener("click", (e) => e.preventDefault())
  li.append(a)
  return li
}
function show(answer) {
  list.replaceChildren(...answer.cyfrs.map(row))
  said.textContent = answer.error || ""
}
async function watch() {
  let seen = 0
  for (;;) {
    try {
      const r = await fetch("/rail/list", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({token, seen})})
      if (r.status === 503) return
      if (!r.ok) throw new Error(String(r.status))
      const text = await r.text()
      if (text) {
        const answer = JSON.parse(text)
        seen = answer.seq
        show(answer)
      }
    } catch {
      said.textContent = "The list could not be read."
      await new Promise((r) => setTimeout(r, 2000))
    }
  }
}
watch()
