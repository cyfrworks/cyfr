// AQUA overlay hook — Cmd+K (or Ctrl+K) toggles, Escape closes.
//
// Mounted on the overlay's root element. Listens globally for the
// keyboard shortcut and pushes "toggle" / "set_state" events to the
// LiveView. Persists the last non-closed sheet state to localStorage so
// the user's preference (peek/half/full) survives reloads.

const isMac = /Mac|iPod|iPhone|iPad/.test(navigator.platform)
const STORAGE_KEY = "aqua-overlay-last-state"

function isToggleShortcut(event) {
  const modifier = isMac ? event.metaKey : event.ctrlKey
  return modifier && !event.shiftKey && !event.altKey && event.key.toLowerCase() === "k"
}

const AgentOverlay = {
  mounted() {
    this._lastState = readLastState() || "half"

    this._onKeyDown = (event) => {
      if (isToggleShortcut(event)) {
        event.preventDefault()
        const current = this.el.dataset.state
        if (current === "closed") {
          this.pushEventTo(this.el, "set_state", { state: this._lastState })
        } else {
          this.pushEventTo(this.el, "set_state", { state: "closed" })
        }
      } else if (event.key === "Escape" && this.el.dataset.state !== "closed") {
        // Don't steal Escape from text inputs that have their own handlers.
        const t = event.target
        if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA")) {
          // Only close if the input is empty — otherwise let it clear text first
          if (!t.value || t.value === "") {
            event.preventDefault()
            this.pushEventTo(this.el, "set_state", { state: "closed" })
          }
          return
        }
        event.preventDefault()
        this.pushEventTo(this.el, "set_state", { state: "closed" })
      }
    }

    window.addEventListener("keydown", this._onKeyDown)
  },

  updated() {
    const state = this.el.dataset.state
    if (state && state !== "closed") {
      writeLastState(state)
      this._lastState = state
    }
  },

  destroyed() {
    if (this._onKeyDown) {
      window.removeEventListener("keydown", this._onKeyDown)
    }
  }
}

function readLastState() {
  try {
    const v = localStorage.getItem(STORAGE_KEY)
    if (v === "peek" || v === "half" || v === "full") return v
  } catch (_) {}
  return null
}

function writeLastState(state) {
  try {
    localStorage.setItem(STORAGE_KEY, state)
  } catch (_) {}
}

export default AgentOverlay
