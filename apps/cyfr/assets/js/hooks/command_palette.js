// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Command palette hook — Cmd+Shift+K (or Ctrl+Shift+K) opens, Escape closes.
//
// The palette itself is a Phoenix LiveComponent that listens for "toggle" /
// "close" events. This hook is a thin keyboard listener that pushes those
// events to the LiveView, and it puts the focus in the search field each
// time the palette opens: the field is added by a patch, and LiveView's
// script honours no `autofocus` on an element a patch adds.
//
// The palette binds Cmd+Shift+K, not plain Cmd+K: nothing in the app claims
// plain Cmd+K, and the shifted chord stays clear of the browsers' own
// Cmd+K bindings (address-bar search and the like).

import {isMac} from "../platform.js"

function isPaletteShortcut(event) {
  const modifier = isMac ? event.metaKey : event.ctrlKey
  return modifier && event.shiftKey && !event.altKey && event.key.toLowerCase() === "k"
}

const CommandPalette = {
  mounted() {
    this._onKeyDown = (event) => {
      if (isPaletteShortcut(event)) {
        event.preventDefault()
        this.pushEventTo(this.el, "toggle", {})
      } else if (event.key === "Escape" && this.el.dataset.open === "true") {
        event.preventDefault()
        this.pushEventTo(this.el, "close", {})
      }
    }

    window.addEventListener("keydown", this._onKeyDown)
    this._wasOpen = this.el.dataset.open === "true"
  },

  updated() {
    const open = this.el.dataset.open === "true"
    if (open && !this._wasOpen) {
      const field = this.el.querySelector("input")
      if (field) field.focus()
    }
    this._wasOpen = open
  },

  destroyed() {
    if (this._onKeyDown) {
      window.removeEventListener("keydown", this._onKeyDown)
    }
  }
}

export default CommandPalette