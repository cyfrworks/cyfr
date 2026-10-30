// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The top bar's mode switch, Dashboard | Canvas: Ctrl+Alt+` (Control and
// Option on a Mac) follows the switch's other link, as a click on it
// would. The key is heard on the shell's own document only, so no app's
// frame ever sees it, and nothing else in the shell binds it.

export function isModeKey(event) {
  return (
    event.ctrlKey === true &&
    event.altKey === true &&
    event.metaKey !== true &&
    event.shiftKey !== true &&
    event.code === "Backquote"
  )
}

// The switch's link to the mode the page is not in.
export function otherMode(root) {
  return root.querySelector('[data-mode]:not([aria-current="page"])')
}

const ModeSwitch = {
  mounted() {
    this._onKeyDown = (event) => {
      if (!isModeKey(event)) return
      const other = otherMode(this.el)
      if (!other) return
      event.preventDefault()
      other.click()
    }

    window.addEventListener("keydown", this._onKeyDown)
  },

  destroyed() {
    if (this._onKeyDown) window.removeEventListener("keydown", this._onKeyDown)
  }
}

export default ModeSwitch
