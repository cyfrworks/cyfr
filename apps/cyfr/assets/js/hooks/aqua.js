// AQUA overlay hook — Cmd+K (or Ctrl+K) toggles, Escape closes.
//
// Mounted on the overlay's root element. The primary entrance is the FAB
// (a regular phx-click button); this hook adds the keyboard shortcut and
// persists the last non-closed sheet state to localStorage so the user's
// preferred size (half/full) survives reloads.

const isMac = /Mac|iPod|iPhone|iPad/.test(navigator.platform)
const STORAGE_KEY = "aqua-overlay-last-state"

function isToggleShortcut(event) {
  const modifier = isMac ? event.metaKey : event.ctrlKey
  return modifier && !event.shiftKey && !event.altKey && event.key.toLowerCase() === "k"
}

function isHaltShortcut(event) {
  const modifier = isMac ? event.metaKey : event.ctrlKey
  return modifier && !event.shiftKey && !event.altKey && event.key === "."
}

const Aqua = {
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
      } else if (isHaltShortcut(event) && this.el.dataset.state !== "closed") {
        event.preventDefault()
        this.pushEventTo(this.el, "stop", {})
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

    // Server-pushed `aqua-actions` intents extracted from the assistant's reply.
    // The server collapses navigate-class intents (ui.navigate, ui.*.focus) to
    // a uniform {kind: "navigate", to: <path>} shape so this dispatcher stays
    // tiny. Other kinds keep their fields as-is.
    this.handleEvent("aqua:intents", ({intents}) => {
      if (!Array.isArray(intents)) return
      for (const intent of intents) {
        try {
          this._dispatchIntent(intent)
        } catch (err) {
          console.warn("[AQUA] intent dispatch failed", intent, err)
        }
      }
    })
  },

  _dispatchIntent(intent) {
    if (!intent || typeof intent.kind !== "string") return
    switch (intent.kind) {
      case "navigate":
        this._navigateTo(intent.to)
        break
      case "overlay_open": {
        const next = intent.state || this._lastState || "half"
        this.pushEventTo(this.el, "set_state", { state: next })
        break
      }
      case "overlay_close":
        this.pushEventTo(this.el, "set_state", { state: "closed" })
        break
      case "overlay_focus_input": {
        const ta = this.el.querySelector("textarea[name='message']")
        if (ta) ta.focus()
        break
      }
      case "copy_clipboard":
        if (navigator.clipboard && typeof intent.text === "string") {
          navigator.clipboard.writeText(intent.text).catch(() => {
            // Permission denied or no clipboard API — silent no-op.
          })
        }
        break
      default:
        console.warn("[AQUA] unknown intent kind", intent)
    }
  },

  // Phoenix LiveView's client-side router seam. The data-phx-link contract
  // is the same one <.link navigate> emits — stable through phoenix_live_view
  // 1.1.x. If a future major version changes the markup, fall back to
  // liveSocket.historyRedirect(to, "push").
  _navigateTo(to) {
    if (typeof to !== "string" || to === "") return
    const a = document.createElement("a")
    a.setAttribute("href", to)
    a.setAttribute("data-phx-link", "redirect")
    a.setAttribute("data-phx-link-state", "push")
    document.body.appendChild(a)
    a.click()
    a.remove()
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
    if (v === "half" || v === "full") return v
  } catch (_) {}
  return null
}

function writeLastState(state) {
  try {
    localStorage.setItem(STORAGE_KEY, state)
  } catch (_) {}
}

export default Aqua
