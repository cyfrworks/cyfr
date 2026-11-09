// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The desktop's own hook (PrismWeb.ShellLive, on #shell-page). The desktop
// is a LiveView of its own beside the page's, so it moves the page rather
// than itself, and reads the page's address rather than its own: it has
// none.
//
// The shell's `navigate` (a desktop's `settings` verb) moves the page's
// LiveView to the Dashboard page named, which opens as the overlay over
// the desktop, the desktop and its frames untouched. And the desktop's own
// address with `?publisher=&tincture_name=` (the palette's and AQUA's focus
// on a tincture, PrismWeb.DesktopLive) is handed to the shell as
// `focus_named`, read when the hook mounts and after each move of the page.
//
// The picker's keys are the desktop's: an arrow, Enter or Escape typed on
// the desktop is handed to the shell as `keynav`, and one typed into a
// field, with a modifier held, or anywhere inside what stands over the
// desktop (the page's layer: a Dashboard page, the top bar, the palette;
// the chat's and AQUA's panels; an open dialog) stays there, so no key
// typed in a form launches or closes an app.

const KEYS = new Set(["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Enter", "Escape"])
const OVER = "#page-layer, #chat-sheet, #aqua-panel-sheet, dialog[open]"

// Whether a key event is the desktop's to hear.
export function desktopKey(event) {
  if (!KEYS.has(event.key)) return false
  if (event.ctrlKey || event.altKey || event.metaKey) return false
  const target = event.target
  if (!target || typeof target.closest !== "function") return true
  if (target.isContentEditable) return false
  if (target.closest("input, textarea, select, [contenteditable]")) return false
  return target.closest(OVER) === null
}

// The desktop's own addresses: `/`, `/a` and `/a/<athanor>`.
const DESKTOP = /^\/(?:a(?:\/[^/]+)?)?\/?$/

// The tincture a desktop address asks the picker to show, or null.
export function focusOf(href, origin) {
  let url
  try {
    url = new URL(href, origin)
  } catch {
    return null
  }
  if (url.origin !== origin || !DESKTOP.test(url.pathname)) return null
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
    }

    this._onMoved = (event) => focus((event.detail && event.detail.to) || window.location.href)
    window.addEventListener("phx:page-loading-stop", this._onMoved)
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
