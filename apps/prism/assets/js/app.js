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
