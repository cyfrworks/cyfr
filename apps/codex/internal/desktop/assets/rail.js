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
const go = (path, address) => location.assign(path + "?cyfr=" + encodeURIComponent(address))
// The hue a CYFR's tile takes, from its whole address: two CYFRs whose
// names begin alike are still told apart.
function hue(address) {
  let h = 0
  for (const c of address) h = (h * 31 + c.codePointAt(0)) >>> 0
  return h % 360
}
// What each row is called, shortest first: a CYFR elsewhere by its host's
// first label, then more of its host, then its port and its scheme, the
// whole address last; a CYFR on this computer by its folder's name, then
// more of the folder's path. labels picks for each row the shortest that
// no other row reads too, so two rows never differ by colour alone.
function names(c) {
  const u = new URL(c.cyfr)
  if (c.folder) {
    const parts = c.folder.split(/[\\/]/).filter(Boolean)
    const out = []
    for (let n = 1; n <= parts.length; n++) out.push(parts.slice(-n).join("/"))
    return [...out, c.cyfr]
  }
  const labels = u.hostname.split(".")
  const out = []
  for (let n = 1; n <= labels.length; n++) out.push(labels.slice(0, n).join("."))
  if (u.port) out.push(u.host)
  return [...out, c.cyfr]
}
function labels(cyfrs) {
  const choices = cyfrs.map(names)
  const at = cyfrs.map(() => 0)
  for (;;) {
    const shown = choices.map((c, i) => c[at[i]])
    let moved = false
    for (const name of new Set(shown)) {
      const same = shown.flatMap((other, i) => other === name ? [i] : [])
      if (same.length < 2) continue
      // Those with a shorter name still to give go on first, so a row
      // keeps a short name while another can still be told apart from it.
      const shorter = same.filter((i) => at[i] + 2 < choices[i].length)
      const go = (shorter.length ? shorter : same).filter((i) => at[i] + 1 < choices[i].length)
      for (const i of go) at[i]++
      moved ||= go.length > 0
    }
    if (!moved) return shown
  }
}
// A label may break after a dot, a slash or a colon, never inside a word.
const breakable = (name) => name.replace(/([./:])/g, "$1\u200b")
// A tile's initials: the first letters of its first name's words, or its
// first two letters.
function initials(c) {
  const words = names(c)[0].split(/[^\p{L}\p{N}]+/u).filter(Boolean)
  return (words.length > 1 ? words[0][0] + words[1][0] : (words[0] ?? "?").slice(0, 2)).toUpperCase()
}
// This box, the box's own CYFR, first on a box's screen: pressed, it opens
// whatever its folder names now (the chooser asks cyfr), or shows it where
// it is the one open. It has no menu: it is never forgotten.
function boxRow(c) {
  const li = document.createElement("li")
  const a = document.createElement("a")
  a.className = "way box"
  a.href = c.open && c.cyfr ? "/rail/select?cyfr=" + encodeURIComponent(c.cyfr) : "/rail/box"
  a.title = c.cyfr ? "This box, " + c.cyfr : "This box"
  a.setAttribute("aria-label", a.title)
  if (c.open) a.setAttribute("aria-current", "page")
  const tile = document.createElement("span")
  tile.className = "tile"
  tile.setAttribute("aria-hidden", "true")
  tile.innerHTML = '<svg viewBox="0 0 24 24" width="22" height="22"><rect x="4" y="6" width="16" height="12" rx="2" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M8 21h8" fill="none" stroke="currentColor" stroke-width="1.6"/></svg>'
  const label = document.createElement("span")
  label.className = "name"
  label.textContent = "This box"
  a.append(tile, label)
  a.addEventListener("contextmenu", (e) => e.preventDefault())
  li.append(a)
  return li
}
function row(c, name, quiet) {
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
  tile.textContent = initials(c)
  const label = document.createElement("span")
  label.className = "name"
  label.textContent = breakable(name)
  a.append(tile, label)
  // Its menu, which main draws: the context key, Shift+F10 or Delete,
  // a press held on a touch screen, or the pointer's other button.
  // On a box it offers none while the box is locked, nor for the CYFR open
  // (quiet): cyfr forgets neither then. The CYFR open is forgotten from
  // This box.
  const menu = (e) => { e.preventDefault(); if (!quiet) go("/rail/menu", c.cyfr) }
  a.addEventListener("contextmenu", menu)
  a.addEventListener("keydown", (e) => {
    if (e.key === "ContextMenu" || e.key === "Delete" || (e.key === "F10" && e.shiftKey)) menu(e)
  })
  let held = 0
  a.addEventListener("touchstart", () => { held = setTimeout(() => { held = -1; if (!quiet) go("/rail/menu", c.cyfr) }, 550) }, {passive: true})
  const release = (e) => { if (held === -1) e.preventDefault(); clearTimeout(held); held = 0 }
  a.addEventListener("touchend", release)
  a.addEventListener("touchmove", () => { clearTimeout(held); held = 0 }, {passive: true})
  if (c.forgetting && !c.failed) a.addEventListener("click", (e) => e.preventDefault())
  li.append(a)
  return li
}
function show(answer) {
  const box = answer.cyfrs.filter((c) => c.box)
  // An entry This box's folder made at an address it no longer names is
  // called by that address: the folder's name is This box's.
  const cyfrs = answer.cyfrs.filter((c) => !c.box).map((c) => box.some((b) => b.folder && b.folder === c.folder) ? {...c, folder: ""} : c)
  const shown = labels(cyfrs)
  list.replaceChildren(...box.map(boxRow), ...cyfrs.map((c, i) => row(c, shown[i], box.length > 0 && (!!answer.locked || !!c.open))))
  // A box sets nothing up, its screen showing its own CYFR, and offers
  // Update only while it is unlocked: nothing of it shows on a locked box.
  document.getElementById("setup").parentElement.hidden = box.length > 0
  document.getElementById("update").parentElement.hidden = box.length > 0 && !!answer.locked
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
