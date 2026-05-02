import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import ShellViewport from "./hooks/window_manager"
import IframeBridge from "./hooks/iframe_bridge"
import CommandPalette from "./hooks/command_palette"
import AgentOverlay from "./hooks/agent_overlay"
import {marked} from "../vendor/marked.esm.js"
import DOMPurify from "../vendor/purify.es.mjs"
import hljs from "../vendor/highlight.min.js"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Clipboard copy for tincture public URLs (triggered via push_event from LiveView)
window.addEventListener("phx:cyfr:copy-to-clipboard", (e) => {
  const text = e.detail && e.detail.text
  if (text && navigator.clipboard) {
    navigator.clipboard.writeText(text)
  }
})

let Hooks = {}
Hooks.ShellViewport = ShellViewport
Hooks.IframeBridge = IframeBridge
Hooks.CommandPalette = CommandPalette
Hooks.AgentOverlay = AgentOverlay

Hooks.Tooltip = {
  mounted() {
    this._position()
  },
  updated() {
    this._position()
  },
  _position() {
    const anchorId = this.el.dataset.anchor
    const anchor = anchorId && document.getElementById(anchorId)
    if (!anchor) return
    const rect = anchor.getBoundingClientRect()
    this.el.style.top = rect.top + "px"
    this.el.style.left = (rect.right + 8) + "px"
  }
}

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

    // @mention autocomplete state
    this._mentionPopup = null
    this._mentionQuery = null
    this._mentionIndex = 0
    this._mentionOptions = []

    this._getOrchestratorNames = () => {
      try {
        const raw = this.el.getAttribute("data-orchestrators")
        return raw ? JSON.parse(raw) : []
      } catch { return [] }
    }

    this._showMentionPopup = (options, textarea) => {
      if (options.length === 0) { this._hideMentionPopup(); return }

      // Reuse existing popup if already shown
      let popup = document.getElementById("mention-popup")
      if (!popup) {
        popup = document.createElement("div")
        popup.id = "mention-popup"
        popup.className = "fixed z-[9999] rounded-lg bg-gray-800 border border-gray-700 py-1 shadow-xl min-w-[200px]"
        document.body.appendChild(popup)
      }

      // Position above the textarea
      const rect = textarea.getBoundingClientRect()
      popup.style.left = rect.left + "px"
      popup.style.bottom = (window.innerHeight - rect.top + 4) + "px"

      this._renderMentionItems(popup, options)
      this._mentionPopup = popup
    }

    this._renderMentionItems = (popup, options) => {
      popup.innerHTML = ""
      options.forEach((opt, i) => {
        const btn = document.createElement("button")
        btn.type = "button"
        btn.className = `flex w-full items-center gap-2 px-3 py-1.5 text-left text-xs transition-colors ${
          i === this._mentionIndex ? "bg-blue-600/20 text-blue-400" : "text-gray-400 hover:bg-gray-700"
        }`
        btn.innerHTML = `<span class="text-gray-600">@</span><span class="flex-1">${opt}</span>${
          ""
        }`
        btn.onmousedown = (e) => {
          e.preventDefault()
          this._insertMention(opt)
        }
        popup.appendChild(btn)
      })
    }

    this._hideMentionPopup = () => {
      const existing = document.getElementById("mention-popup")
      if (existing) existing.remove()
      this._mentionPopup = null
      this._mentionQuery = null
      this._mentionIndex = 0
    }

    this._insertMention = (value) => {
      const textarea = this._textarea
      if (!textarea) return
      const pos = textarea.selectionStart
      const text = textarea.value
      const before = text.slice(0, pos)
      const atIdx = before.lastIndexOf("@")
      if (atIdx === -1) return
      const after = text.slice(pos)
      textarea.value = text.slice(0, atIdx) + "@" + value + " " + after
      const cursorPos = atIdx + value.length + 2
      textarea.focus()
      textarea.setSelectionRange(cursorPos, cursorPos)
      this._hideMentionPopup()
      if (this._resizeTextarea) this._resizeTextarea()
    }

    this._checkMention = (textarea) => {
      const pos = textarea.selectionStart
      const textBefore = textarea.value.slice(0, pos)
      const atMatch = textBefore.match(/@([^\s@]*)$/)
      if (atMatch) {
        const query = atMatch[1].toLowerCase()
        const names = this._getOrchestratorNames()
        if (names.length === 0) { this._hideMentionPopup(); return }
        const allOptions = [...names]
        const filtered = query ? allOptions.filter(n => n.toLowerCase().includes(query)) : allOptions
        this._mentionQuery = query
        this._mentionOptions = filtered
        this._mentionIndex = 0
        this._showMentionPopup(filtered, textarea)
      } else {
        this._hideMentionPopup()
      }
    }

    // Auto-resize textarea + Shift+Enter to send + @mention autocomplete
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
      textarea.addEventListener("input", (e) => {
        resize()
        this._checkMention(textarea)
      })
      this._resizeTextarea = resize

      textarea.addEventListener("keydown", (e) => {
        // Handle mention autocomplete navigation
        if (this._mentionPopup && this._mentionOptions.length > 0) {
          if (e.key === "ArrowDown") {
            e.preventDefault()
            this._mentionIndex = (this._mentionIndex + 1) % this._mentionOptions.length
            this._renderMentionItems(this._mentionPopup, this._mentionOptions)
            return
          }
          if (e.key === "ArrowUp") {
            e.preventDefault()
            this._mentionIndex = (this._mentionIndex - 1 + this._mentionOptions.length) % this._mentionOptions.length
            this._renderMentionItems(this._mentionPopup, this._mentionOptions)
            return
          }
          if (e.key === "Tab" || (e.key === "Enter" && !e.shiftKey)) {
            e.preventDefault()
            const selected = this._mentionOptions[this._mentionIndex]
            if (selected) this._insertMention(selected)
            return
          }
          if (e.key === "Escape") {
            e.preventDefault()
            this._hideMentionPopup()
            return
          }
        }

        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault()
          const value = textarea.value.trim()
          if (value && !textarea.disabled) {
            this.pushEvent("submit", {message: value})
            textarea.value = ""
            this._hideMentionPopup()
            resize()
          }
        }
      })

      // Paste files/screenshots from clipboard into upload pipeline
      textarea.addEventListener("paste", (e) => {
        const items = e.clipboardData && e.clipboardData.items
        if (!items) return

        const files = []
        for (let i = 0; i < items.length; i++) {
          if (items[i].kind === "file") {
            const file = items[i].getAsFile()
            if (file) {
              if (file.type.startsWith("image/") && (!file.name || file.name === "image.png")) {
                const ext = file.type.split("/")[1] || "png"
                const ts = new Date().toISOString().replace(/[:.]/g, "-")
                files.push(new File([file], `screenshot-${ts}.${ext}`, { type: file.type }))
              } else {
                files.push(file)
              }
            }
          }
        }

        if (files.length === 0) return
        e.preventDefault()

        const fileInput = this.el.querySelector("input[data-phx-upload-ref]")
        if (!fileInput) return

        fileInput.dispatchEvent(new CustomEvent("track-uploads", {
          bubbles: true,
          detail: { files: files }
        }))
      })

    }
    this._setupTextarea()

    // Click outside to dismiss mention popup
    this._mentionClickOutside = (e) => {
      const popup = document.getElementById("mention-popup")
      if (popup && !popup.contains(e.target) && e.target !== this._textarea) {
        this._hideMentionPopup()
      }
    }
    document.addEventListener("mousedown", this._mentionClickOutside)

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
    if (this._mentionClickOutside) {
      document.removeEventListener("mousedown", this._mentionClickOutside)
    }
    this._hideMentionPopup()
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
