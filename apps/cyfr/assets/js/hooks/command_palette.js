// Command palette hook — Cmd+Shift+K (or Ctrl+Shift+K) opens, Escape closes.
//
// The palette itself is a Phoenix LiveComponent that listens for "open" /
// "close" events. This hook is a thin keyboard listener that pushes those
// events to the LiveView. No DOM mutation here.
//
// Cmd+K alone is reserved for the AQUA overlay (see agent_overlay.js).
// Cmd+Shift+K is the palette so both can coexist without conflict.

const isMac = /Mac|iPod|iPhone|iPad/.test(navigator.platform)

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
  },

  destroyed() {
    if (this._onKeyDown) {
      window.removeEventListener("keydown", this._onKeyDown)
    }
  }
}

export default CommandPalette
