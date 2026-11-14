// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A flash fades after a few seconds, and is then cleared the way a click
// on it clears it: by running its own phx-click, which asks the server to
// clear the flash. Removing the element alone would leave the server's
// flash set, so the same message put again changes nothing the server
// renders, and never shows a second time.
export const SHOWN_MS = 5000
export const FADE_MS = 500

const FlashAutoHide = {
  mounted() {
    this.timer = setTimeout(() => {
      this.el.style.opacity = "0"
      this.timer = setTimeout(() => this.js().exec(this.el.getAttribute("phx-click")), FADE_MS)
    }, SHOWN_MS)
  },
  destroyed() {
    clearTimeout(this.timer)
  }
}

export default FlashAutoHide
