import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let Hooks = {}

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

Hooks.AgentChat = {
  mounted() {
    this.handleEvent("scroll_bottom", () => {
      const messages = document.getElementById("messages")
      if (messages) {
        messages.scrollTop = messages.scrollHeight
      }
    })

    // Persist preferences to localStorage
    this.handleEvent("save_preferences", (prefs) => {
      localStorage.setItem("agent_prefs", JSON.stringify(prefs))
    })

    // Restore preferences from localStorage
    const saved = localStorage.getItem("agent_prefs")
    if (saved) {
      try {
        const prefs = JSON.parse(saved)
        this.pushEvent("restore_preferences", prefs)
      } catch (_e) {
        // ignore corrupt data
      }
    }

    // Auto-resize textarea
    const textarea = this.el.querySelector("textarea[name='message']")
    if (textarea) {
      const lineHeight = parseInt(getComputedStyle(textarea).lineHeight) || 20
      const maxRows = 15
      const resize = () => {
        textarea.style.height = "auto"
        const maxHeight = lineHeight * maxRows
        textarea.style.height = Math.min(textarea.scrollHeight, maxHeight) + "px"
        textarea.style.overflowY = textarea.scrollHeight > maxHeight ? "auto" : "hidden"
      }
      textarea.addEventListener("input", resize)
      this._resizeTextarea = resize

      // Shift+Enter to send, Enter for newline
      textarea.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && e.shiftKey) {
          e.preventDefault()
          const value = textarea.value.trim()
          if (value) {
            this.pushEvent("submit", {message: value})
            textarea.value = ""
            resize()
          }
        }
      })
    }

    // Auto-scroll on new content
    this.observer = new MutationObserver(() => {
      const messages = document.getElementById("messages")
      if (messages) {
        messages.scrollTop = messages.scrollHeight
      }
    })

    const messages = document.getElementById("messages")
    if (messages) {
      this.observer.observe(messages, { childList: true, subtree: true })
    }
  },
  updated() {
    if (this._resizeTextarea) {
      this._resizeTextarea()
    }
  },
  destroyed() {
    if (this.observer) {
      this.observer.disconnect()
    }
  }
}

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

liveSocket.connect()

window.liveSocket = liveSocket

window.addEventListener("phx:clipboard", (e) => {
  if (e.detail && e.detail.text) {
    navigator.clipboard.writeText(e.detail.text)
  }
})
