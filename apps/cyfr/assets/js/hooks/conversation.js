// Conversation page hook — keyboard shortcuts and server-pushed intents.
//
// Mounted on the chat page's root element. Cmd+. (Ctrl+. elsewhere) halts
// the running turn; `aqua:intents` carries the intents parsed out of the
// assistant's reply (navigate, copy) for this browser to act on.

const isMac = /Mac|iPod|iPhone|iPad/.test(navigator.platform)

function isHaltShortcut(event) {
  const modifier = isMac ? event.metaKey : event.ctrlKey
  return modifier && !event.shiftKey && !event.altKey && event.key === "."
}

const Conversation = {
  mounted() {
    this._onKeyDown = (event) => {
      if (isHaltShortcut(event)) {
        event.preventDefault()
        this.pushEventTo(this.el, "stop", {})
      }
    }

    window.addEventListener("keydown", this._onKeyDown)

    // The server collapses navigate-class intents (ui.navigate, ui.*.focus)
    // to a uniform {kind: "navigate", to: <path>} shape so this dispatcher
    // stays tiny. Other kinds keep their fields as-is.
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
      case "overlay_focus_input":
      case "overlay_open": {
        const ta = this.el.querySelector("textarea[name='message']")
        if (ta) ta.focus()
        break
      }
      case "overlay_close":
        break
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

  destroyed() {
    if (this._onKeyDown) {
      window.removeEventListener("keydown", this._onKeyDown)
    }
  }
}

export default Conversation
