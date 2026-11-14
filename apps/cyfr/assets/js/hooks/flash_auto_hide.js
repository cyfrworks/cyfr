// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A flash fades after a few seconds, and is then dismissed the way a click
// on it dismisses it: by running its own phx-click, which names the
// message it shows and asks the server to clear it while that message is
// still the one shown. Removing the element alone would leave the
// server's flash set, so the same message put again would change nothing
// the server renders and never show a second time. A new message in the
// same place changes the click, and starts the fade again for it.
export const SHOWN_MS = 5000
export const FADE_MS = 500

const FlashAutoHide = {
  mounted() {
    this.start()
  },
  updated() {
    if (this.el.getAttribute("phx-click") !== this.click) this.start()
  },
  destroyed() {
    clearTimeout(this.timer)
  },
  start() {
    clearTimeout(this.timer)
    this.click = this.el.getAttribute("phx-click")
    this.el.style.opacity = ""
    this.timer = setTimeout(() => {
      this.el.style.opacity = "0"
      this.timer = setTimeout(() => this.js().exec(this.click), FADE_MS)
    }, SHOWN_MS)
  }
}

export default FlashAutoHide
