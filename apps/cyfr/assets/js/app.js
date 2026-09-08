// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import IframeBridge from "./hooks/iframe_bridge"
import CommandPalette from "./hooks/command_palette"
import PageLoadingIndicator from "./hooks/page_loading_indicator"
import OptimisticNav from "./hooks/optimistic_nav"
import Conversation from "./hooks/conversation"
import AquaChat from "./hooks/aqua_chat"
import MarkdownContent from "./hooks/markdown_content"

// Optional-chained: this runs at module top level, so a page rendered without
// the root layout (an error page, a minimal page) would otherwise throw here
// and take the whole bundle with it — including the parts that page does use.
// A missing token means no LiveView socket to authenticate, which the socket
// setup below handles on its own.
let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

let Hooks = {}
Hooks.IframeBridge = IframeBridge
Hooks.CommandPalette = CommandPalette
Hooks.PageLoadingIndicator = PageLoadingIndicator
Hooks.OptimisticNav = OptimisticNav
Hooks.Conversation = Conversation
Hooks.AquaChat = AquaChat
Hooks.MarkdownContent = MarkdownContent

Hooks.FlashAutoHide = {
  mounted() {
    this.timer = setTimeout(() => {
      this.el.style.opacity = "0"
      setTimeout(() => this.el.remove(), 500)
    }, 5000)
  },
  destroyed() {
    clearTimeout(this.timer)
  }
}

// A tape that follows its newest line — but only while the person is
// reading the end of it. Someone scrolled up into the history stays where
// they are as lines stream in; scrolling back to within the band below
// re-engages the follow. The band is remembered on each scroll, since new
// content moves the bottom without firing one.
const SCROLL_FOLLOW_BAND_PX = 50

Hooks.ScrollBottom = {
  _nearBottom() {
    const el = this.el
    return el.scrollHeight - el.scrollTop - el.clientHeight <= SCROLL_FOLLOW_BAND_PX
  },
  _follow() {
    if (this._following) this.el.scrollTop = this.el.scrollHeight
  },
  mounted() {
    this._following = true
    this._onScroll = () => {
      this._following = this._nearBottom()
    }
    this.el.addEventListener("scroll", this._onScroll, { passive: true })
    this.observer = new MutationObserver(() => this._follow())
    this.observer.observe(this.el, { childList: true, subtree: true })
    this._follow()
  },
  updated() {
    this._follow()
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
    if (this._onScroll) this.el.removeEventListener("scroll", this._onScroll)
  }
}

// ---------------------------------------------------------------------------
// Custom confirm dialog (replaces window.confirm for Tauri WKWebView compat)
// ---------------------------------------------------------------------------
// phoenix_html.js intercepts clicks on [data-confirm] elements and calls
// window.confirm(). In Tauri's WKWebView (external URLs), window.confirm()
// silently returns false, preventing phx-click events from ever firing.
// We intercept the phoenix.link.click custom event on document.body (closer
// than the window-level handler) and show an HTML modal instead.

function showConfirmDialog(message) {
  return new Promise(function(resolve) {
    var overlay = document.createElement("div")
    overlay.className = "fixed inset-0 z-[9999] flex items-center justify-center bg-black/60"

    var panel = document.createElement("div")
    panel.className = "bg-gray-900 border border-gray-800 rounded-lg shadow-xl p-6 max-w-sm w-full mx-4"

    var msg = document.createElement("p")
    msg.className = "text-gray-200 text-sm mb-6"
    msg.textContent = message

    var buttons = document.createElement("div")
    buttons.className = "flex justify-end gap-3"

    var cancel = document.createElement("button")
    cancel.className = "inline-flex items-center justify-center rounded-lg font-medium px-4 py-2 text-sm bg-gray-700 text-gray-200 hover:bg-gray-600 focus:outline-none focus:ring-2 focus:ring-gray-500 focus:ring-offset-2 focus:ring-offset-gray-900"
    cancel.textContent = "Cancel"

    var confirm = document.createElement("button")
    confirm.className = "inline-flex items-center justify-center rounded-lg font-medium px-4 py-2 text-sm bg-red-600 text-white hover:bg-red-500 focus:outline-none focus:ring-2 focus:ring-red-500 focus:ring-offset-2 focus:ring-offset-gray-900"
    confirm.textContent = "Confirm"

    buttons.appendChild(cancel)
    buttons.appendChild(confirm)
    panel.appendChild(msg)
    panel.appendChild(buttons)
    overlay.appendChild(panel)
    document.body.appendChild(overlay)

    // The document-level listener is removed by cleanup itself, not only by
    // the Escape branch that installed the removal: clicking Cancel, Confirm
    // or the overlay used to leave it attached, so every dialog the page ever
    // opened kept a live handler closed over its removed DOM.
    function onKeydown(e) {
      if (e.key === "Escape") cleanup(false)
    }

    function cleanup(result) {
      document.removeEventListener("keydown", onKeydown)
      overlay.remove()
      resolve(result)
    }

    cancel.addEventListener("click", function() { cleanup(false) })
    confirm.addEventListener("click", function() { cleanup(true) })
    overlay.addEventListener("click", function(e) {
      if (e.target === overlay) cleanup(false)
    })
    document.addEventListener("keydown", onKeydown)

    confirm.focus()
  })
}

document.body.addEventListener("phoenix.link.click", function(e) {
  var message = e.target.getAttribute("data-confirm")
  if (!message) return
  e.stopPropagation()
  if (e.target.hasAttribute("data-confirm-resolved")) {
    e.target.removeAttribute("data-confirm-resolved")
    return
  }
  e.preventDefault()
  showConfirmDialog(message).then(function(ok) {
    if (ok) {
      e.target.setAttribute("data-confirm-resolved", "")
      e.target.click()
    }
  })
}, false)

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

liveSocket.connect()

// The PWA's service worker, by its literal path: `/sw.js` is served
// undigested so the registration is stable across releases.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch(() => {})
  })
}

window.liveSocket = liveSocket

// The one clipboard-copy listener. Both producer paths land here:
// JS.dispatch("phx:clipboard", ...) fires the window event directly, and
// push_event("clipboard", ...) from a LiveView arrives as the same
// "phx:clipboard" window event (the client prefixes server-pushed events
// with "phx:"). The navigator.clipboard check guards non-secure contexts
// and older WebViews, where the async clipboard API is undefined and the
// bare call would throw.
window.addEventListener("phx:clipboard", (e) => {
  const text = e.detail && e.detail.text
  if (text && navigator.clipboard) {
    navigator.clipboard.writeText(text)
  }
})