import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import ShellViewport from "./hooks/window_manager"
import IframeBridge from "./hooks/iframe_bridge"
import {marked} from "../vendor/marked.esm.js"
import DOMPurify from "../vendor/purify.es.mjs"
import hljs from "../vendor/highlight.min.js"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let Hooks = {}
Hooks.ShellViewport = ShellViewport
Hooks.IframeBridge = IframeBridge

// ---------------------------------------------------------------------------
// Markdown rendering utilities
// ---------------------------------------------------------------------------

// Configure marked renderer once (v15 API: marked.use, not new Renderer)
let markedConfigured = false
function ensureMarkedConfig() {
  if (markedConfigured) return
  markedConfigured = true
  marked.use({
    breaks: true,
    renderer: {
      code({ text, lang }) {
        let highlighted
        if (lang && hljs.getLanguage(lang)) {
          highlighted = hljs.highlight(text, { language: lang }).value
        } else {
          highlighted = hljs.highlightAuto(text).value
        }
        return `<pre><code class="hljs${lang ? ` language-${lang}` : ""}">${highlighted}</code></pre>`
      },
      link({ href, title, tokens }) {
        const text = this.parser.parseInline(tokens)
        const titleAttr = title ? ` title="${title}"` : ""
        return `<a href="${href}"${titleAttr} target="_blank" rel="noopener noreferrer">${text}</a>`
      }
    }
  })
}

function renderMarkdownToHTML(raw) {
  ensureMarkedConfig()
  const html = marked.parse(raw)
  return DOMPurify.sanitize(html, {
    ALLOWED_TAGS: [
      "h1","h2","h3","h4","h5","h6","p","br","hr","blockquote",
      "ul","ol","li","a","strong","em","del","code","pre",
      "table","thead","tbody","tr","th","td",
      "div","span","img","sup","sub","details","summary"
    ],
    ALLOWED_ATTR: ["href","src","alt","title","class","target","rel","open"],
    FORBID_TAGS: ["script","style","iframe","form","input","button","textarea"],
    FORBID_ATTR: ["onclick","onerror","onload","onmouseover"]
  })
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

Hooks.MarkdownContent = {
  mounted() { this._render() },
  updated() { this._render() },
  _render() {
    const raw = this.el.getAttribute("data-raw-content")
    if (!raw) return
    try {
      this.el.innerHTML = renderMarkdownToHTML(raw)
    } catch (e) {
      console.error('[MarkdownContent] render failed:', e)
    }
  }
}

Hooks.StreamingMarkdown = {
  mounted() {
    this._timer = null
    this._text = this.el.getAttribute("data-raw-content") || ""
    if (this._text) this.el.innerHTML = renderMarkdownToHTML(this._text)
    this.handleEvent("streaming_delta", ({ text }) => {
      this._text = text
      if (!this._timer) {
        this._timer = setTimeout(() => {
          this._timer = null
          try {
            this.el.innerHTML = renderMarkdownToHTML(this._text)
          } catch (e) {
            console.error('[StreamingMarkdown] render failed:', e)
          }
        }, 150)
      }
    })
  },
  destroyed() {
    if (this._timer) clearTimeout(this._timer)
  }
}

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

Hooks.ScrollBottom = {
  mounted() {
    this.observer = new MutationObserver(() => {
      this.el.scrollTop = this.el.scrollHeight
    })
    this.observer.observe(this.el, { childList: true, subtree: true })
  },
  updated() {
    this.el.scrollTop = this.el.scrollHeight
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  }
}

Hooks.ElapsedTimer = {
  mounted() {
    this._tick = () => {
      const started = new Date(this.el.getAttribute("data-started-at"))
      const elapsed = Math.floor((Date.now() - started.getTime()) / 1000)
      if (elapsed < 60) {
        this.el.textContent = `${elapsed}s`
      } else {
        const m = Math.floor(elapsed / 60)
        const s = elapsed % 60
        this.el.textContent = `${m}m ${s}s`
      }
    }
    this._tick()
    this._interval = setInterval(this._tick, 1000)
  },
  destroyed() {
    if (this._interval) clearInterval(this._interval)
  }
}

Hooks.ScrollAnchor = {
  mounted() {
    const messages = document.getElementById("messages")
    const btn = document.getElementById("scroll-to-bottom")
    if (!messages || !btn) return

    // Show/hide button based on scroll position
    this._checkScroll = () => {
      const distFromBottom = messages.scrollHeight - messages.scrollTop - messages.clientHeight
      if (distFromBottom > 150) {
        btn.classList.remove("hidden")
      } else {
        btn.classList.add("hidden")
      }
    }
    messages.addEventListener("scroll", this._checkScroll)

    btn.addEventListener("click", () => {
      messages.scrollTo({ top: messages.scrollHeight, behavior: "smooth" })
    })
  },
  destroyed() {
    const messages = document.getElementById("messages")
    if (messages && this._checkScroll) {
      messages.removeEventListener("scroll", this._checkScroll)
    }
  }
}

Hooks.AgentChat = {
  mounted() {
    // Only auto-scroll if user is already near the bottom
    this.handleEvent("scroll_nudge", () => {
      const messages = document.getElementById("messages")
      if (messages) {
        const distFromBottom = messages.scrollHeight - messages.scrollTop - messages.clientHeight
        if (distFromBottom < 200) {
          messages.scrollTop = messages.scrollHeight
        }
      }
    })

    // Persist preferences to localStorage
    this.handleEvent("save_preferences", (prefs) => {
      localStorage.setItem("agent_prefs", JSON.stringify(prefs))
    })

    // No-op handlers for legacy events (messages now persisted server-side via Arca)
    this.handleEvent("save_partial", () => {})
    this.handleEvent("clear_partial", () => {})

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

    // Clean up any legacy localStorage data
    localStorage.removeItem("agent_messages")
    localStorage.removeItem("agent_partial")

    // Auto-resize textarea + Shift+Enter to send
    this._setupTextarea = () => {
      const textarea = this.el.querySelector("textarea[name='message']")
      if (!textarea || textarea === this._textarea) return
      this._textarea = textarea

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

      textarea.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && e.shiftKey) {
          e.preventDefault()
          const value = textarea.value.trim()
          if (value && !textarea.disabled) {
            this.pushEvent("submit", {message: value})
            textarea.value = ""
            resize()
          }
        }
      })
    }
    this._setupTextarea()

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
    this._setupTextarea()
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

// ---------------------------------------------------------------------------
// Custom confirm dialog (replaces window.confirm for Tauri WKWebView compat)
// ---------------------------------------------------------------------------
// phoenix_html.js intercepts clicks on [data-confirm] elements and calls
// window.confirm(). In Tauri's WKWebView (external URLs), window.confirm()
// silently returns false, preventing phx-click events from ever firing.
// We intercept the phoenix.link.click custom event on document.body (closer
// than the window-level handler) and show an HTML modal instead.

function showConfirmDialog(message) {
  return new Promise(function(resolve) {
    var overlay = document.createElement("div")
    overlay.className = "fixed inset-0 z-[9999] flex items-center justify-center bg-black/60"

    var panel = document.createElement("div")
    panel.className = "bg-gray-900 border border-gray-800 rounded-lg shadow-xl p-6 max-w-sm w-full mx-4"

    var msg = document.createElement("p")
    msg.className = "text-gray-200 text-sm mb-6"
    msg.textContent = message

    var buttons = document.createElement("div")
    buttons.className = "flex justify-end gap-3"

    var cancel = document.createElement("button")
    cancel.className = "inline-flex items-center justify-center rounded-lg font-medium px-4 py-2 text-sm bg-gray-700 text-gray-200 hover:bg-gray-600 focus:outline-none focus:ring-2 focus:ring-gray-500 focus:ring-offset-2 focus:ring-offset-gray-900"
    cancel.textContent = "Cancel"

    var confirm = document.createElement("button")
    confirm.className = "inline-flex items-center justify-center rounded-lg font-medium px-4 py-2 text-sm bg-red-600 text-white hover:bg-red-500 focus:outline-none focus:ring-2 focus:ring-red-500 focus:ring-offset-2 focus:ring-offset-gray-900"
    confirm.textContent = "Confirm"

    buttons.appendChild(cancel)
    buttons.appendChild(confirm)
    panel.appendChild(msg)
    panel.appendChild(buttons)
    overlay.appendChild(panel)
    document.body.appendChild(overlay)

    function cleanup(result) {
      overlay.remove()
      resolve(result)
    }

    cancel.addEventListener("click", function() { cleanup(false) })
    confirm.addEventListener("click", function() { cleanup(true) })
    overlay.addEventListener("click", function(e) {
      if (e.target === overlay) cleanup(false)
    })
    document.addEventListener("keydown", function handler(e) {
      if (e.key === "Escape") {
        document.removeEventListener("keydown", handler)
        cleanup(false)
      }
    })

    confirm.focus()
  })
}

document.body.addEventListener("phoenix.link.click", function(e) {
  var message = e.target.getAttribute("data-confirm")
  if (!message) return
  e.stopPropagation()
  if (e.target.hasAttribute("data-confirm-resolved")) {
    e.target.removeAttribute("data-confirm-resolved")
    return
  }
  e.preventDefault()
  showConfirmDialog(message).then(function(ok) {
    if (ok) {
      e.target.setAttribute("data-confirm-resolved", "")
      e.target.click()
    }
  })
}, false)

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
