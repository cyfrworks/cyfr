// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import IframeBridge from "./hooks/iframe_bridge"
import CommandPalette from "./hooks/command_palette"
import ShellPage from "./hooks/shell_page"
import PageLoadingIndicator from "./hooks/page_loading_indicator"
import OptimisticNav from "./hooks/optimistic_nav"
import Thread from "./hooks/thread"
import AquaChat from "./hooks/aqua_chat"
import {AquaPanel, AquaPanelKeys} from "./aqua_panel"
import MarkdownContent from "./hooks/markdown_content"
import Canvas from "./canvas/index"
import SystemLayer from "./system_layer/index"
import {completeUnlock} from "./device_unlock"

// A protected device's unlock page posts the ticket its fragment carries,
// and nothing else on it starts.
completeUnlock(window)

// Optional-chained: this runs at module top level, so a page rendered without
// the root layout (an error page, a minimal page) would otherwise throw here
// and take the whole bundle with it — including the parts that page does use.
// A missing token means no LiveView socket to authenticate, which the socket
// setup below handles on its own.
let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

let Hooks = {}
Hooks.IframeBridge = IframeBridge
Hooks.CommandPalette = CommandPalette
Hooks.ShellPage = ShellPage
Hooks.PageLoadingIndicator = PageLoadingIndicator
Hooks.OptimisticNav = OptimisticNav
Hooks.Thread = Thread
Hooks.AquaChat = AquaChat
Hooks.AquaPanel = AquaPanel
Hooks.AquaPanelKeys = AquaPanelKeys
Hooks.MarkdownContent = MarkdownContent
Hooks.Canvas = Canvas
Hooks.SystemLayer = SystemLayer

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

// What the person's browser says of how they read the screen, which the
// shell tells a desktop in its handshake (`Prism.Appearance`): the
// language, the time zone and the safe-area insets, read when the socket
// connects and held to their grammar on the server.
function appearance() {
  const {locale, timeZone} = Intl.DateTimeFormat().resolvedOptions()
  return {locale: navigator.language || locale, time_zone: timeZone, safe_areas: safeAreas()}
}

function safeAreas() {
  const probe = document.createElement("div")
  probe.style.cssText =
    "position:fixed;visibility:hidden;pointer-events:none;" +
    "padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)"
  document.body.appendChild(probe)
  const style = getComputedStyle(probe)
  const inset = (side) => Math.round(parseFloat(style.getPropertyValue(`padding-${side}`)) || 0)
  const areas = {top: inset("top"), right: inset("right"), bottom: inset("bottom"), left: inset("left")}
  probe.remove()
  return areas
}

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({_csrf_token: csrfToken, ...appearance()}),
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
// with "phx:").
window.addEventListener("phx:clipboard", (e) => {
  const text = e.detail && e.detail.text
  if (text) {
    navigator.clipboard.writeText(text)
  }
})