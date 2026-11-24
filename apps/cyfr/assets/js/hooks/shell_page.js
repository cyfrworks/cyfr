// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The desktop's own hook (PrismWeb.ShellLive, on #shell-page). The desktop
// is a LiveView of its own beside the page's, so it moves the page rather
// than itself, and reads the page's address rather than its own: it has
// none.
//
// The shell's `navigate` (a desktop's `settings` verb) moves the page's
// LiveView to the Dashboard page named, which opens as the overlay over
// the desktop, the desktop and its frames untouched. A hook hears the
// event from any view of the document, so Aqua's panel, nested in the
// desktop, moves the page the same way to a workspace thread's layer. And the desktop's own
// address with `?publisher=&tincture_name=` (the palette's and Aqua's focus
// on a tincture, PrismWeb.DesktopLive) is handed to the shell as
// `focus_named`, and with `?shell=desktops` (the palette's desktops) or
// `?shell=threads&ref=<id>` (the palette's threads, the ref optional) as
// the shell's key `shell_key`, each read when the hook mounts and after
// each move of the page.
//
// After each move of the page it tells the shell whether a Dashboard page is
// now drawn over the desktop (`page_shown`, `desktop` true on the desktop's
// own address), so the prompts the desktop raises on its own wait behind
// the page rather than stand modal over its asks.
//
// The picker's keys are the desktop's: an arrow, Enter or Escape typed on
// the desktop is handed to the shell as `keynav`, and one typed into a
// field or on a control (a button, a link: Enter on the shelf's Chat is
// the button's, never also the picker's launch), with a modifier held, or
// anywhere inside what stands over the
// desktop (the page's layer: a Dashboard page, the top bar, the palette;
// the chat's and Aqua's panels; the chooser of desktops; an open dialog)
// stays there, so no key typed in a form launches or closes an app.

const KEYS = new Set(["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Enter", "Escape"])
const OVER = "#page-layer, #chat-sheet, #aqua-panel-sheet, #desktop-chooser, dialog[open]"

// Whether a key event is the desktop's to hear.
export function desktopKey(event) {
  if (!KEYS.has(event.key)) return false
  if (event.ctrlKey || event.altKey || event.metaKey) return false
  const target = event.target
  if (!target || typeof target.closest !== "function") return true
  if (target.isContentEditable) return false
  if (target.closest("input, textarea, select, [contenteditable], button, a[href]")) return false
  return target.closest(OVER) === null
}

// The desktop's own addresses: `/`, `/a` and `/a/<athanor>`.
const DESKTOP = /^\/(?:a(?:\/[^/]+)?)?\/?$/

// A desktop address of this origin as a URL, or null.
function desktopUrl(href, origin) {
  let url
  try {
    url = new URL(href, origin)
  } catch {
    return null
  }
  return url.origin === origin && DESKTOP.test(url.pathname) ? url : null
}

// The keys an address may name: the chooser of desktops and the person's
// threads.
const SHELL_KEYS = new Set(["desktops", "threads"])

// The shell's key a desktop address names, or null.
export function shellKeyOf(href, origin) {
  const url = desktopUrl(href, origin)
  const key = url && url.searchParams.get("shell")
  return SHELL_KEYS.has(key) ? key : null
}

// What the shell is handed for a desktop address, or null: its key, and
// for the person's threads the thread `ref` names, when it names one.
function shellAsk(href, origin) {
  const key = shellKeyOf(href, origin)
  if (!key) return null
  const ref = key === "threads" ? desktopUrl(href, origin).searchParams.get("ref") : null
  return ref ? {key, ref} : {key}
}

// The tincture a desktop address asks the picker to show, or null.
export function focusOf(href, origin) {
  const url = desktopUrl(href, origin)
  if (!url) return null
  const publisher = url.searchParams.get("publisher")
  const name = url.searchParams.get("tincture_name")
  return publisher && name ? {publisher, name} : null
}

const ShellPage = {
  mounted() {
    this.handleEvent("navigate", ({to}) => {
      if (typeof to === "string" && to.startsWith("/") && !to.startsWith("//")) this.js().navigate(to)
    })

    const focus = (href) => {
      const asked = focusOf(href, window.location.origin)
      if (asked) this.pushEvent("focus_named", asked)
      const ask = shellAsk(href, window.location.origin)
      if (ask) this.pushEvent("shell_key", ask)
    }

    const shown = (href) => {
      let url
      try {
        url = new URL(href, window.location.origin)
      } catch {
        return
      }
      const desktop = DESKTOP.test(url.pathname)
      if (desktop !== this._desktop) {
        this._desktop = desktop
        this.pushEvent("page_shown", {desktop})
      }
    }

    this._onMoved = (event) => {
      const href = (event.detail && event.detail.to) || window.location.href
      shown(href)
      focus(href)
    }
    window.addEventListener("phx:page-loading-stop", this._onMoved)
    shown(window.location.href)
    focus(window.location.href)

    this._onKey = (event) => {
      if (desktopKey(event)) this.pushEvent("keynav", {key: event.key})
    }
    window.addEventListener("keydown", this._onKey)
  },

  destroyed() {
    if (this._onMoved) window.removeEventListener("phx:page-loading-stop", this._onMoved)
    if (this._onKey) window.removeEventListener("keydown", this._onKey)
  }
}

export default ShellPage
