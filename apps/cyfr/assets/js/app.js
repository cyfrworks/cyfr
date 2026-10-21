// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import IframeBridge from "./hooks/iframe_bridge"
import CommandPalette from "./hooks/command_palette"
import PageLoadingIndicator from "./hooks/page_loading_indicator"
import OptimisticNav from "./hooks/optimistic_nav"
import Thread from "./hooks/thread"
import AquaChat from "./hooks/aqua_chat"
import MarkdownContent from "./hooks/markdown_content"
import Canvas from "./canvas/index"
import SystemLayer from "./system_layer/index"
import Carry, {resume as resumeCarry} from "./hooks/carry"
import CommandLine from "./hooks/command_line"

// A sign-in carry meant for this home's `/carry` that arrived while its
// person was signed out here was kept through their sign-in: back to
// `/carry` to finish it, before anything else on this page starts.
resumeCarry(window)

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
Hooks.Thread = Thread
Hooks.AquaChat = AquaChat
Hooks.MarkdownContent = MarkdownContent
Hooks.Canvas = Canvas
Hooks.SystemLayer = SystemLayer
Hooks.Carry = Carry
Hooks.CommandLine = CommandLine

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
// with "phx:").
window.addEventListener("phx:clipboard", (e) => {
  const text = e.detail && e.detail.text
  if (text) {
    navigator.clipboard.writeText(text)
  }
})