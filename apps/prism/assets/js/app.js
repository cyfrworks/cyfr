import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let Hooks = {}

// ---------------------------------------------------------------------------
// Markdown rendering utilities
// ---------------------------------------------------------------------------

let mermaidReady = null

function ensureMermaid() {
  if (mermaidReady) return mermaidReady
  mermaidReady = new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = "https://cdnjs.cloudflare.com/ajax/libs/mermaid/11.4.1/mermaid.min.js"
    script.onload = () => {
      window.mermaid.initialize({
        startOnLoad: false,
        theme: "dark",
        themeVariables: { darkMode: true }
      })
      resolve(window.mermaid)
    }
    script.onerror = reject
    document.head.appendChild(script)
  })
  return mermaidReady
}

function renderMarkdownToHTML(raw, opts = {}) {
  const renderer = new marked.Renderer()

  // Intercept fenced code blocks for mermaid
  renderer.code = function({ text, lang }) {
    if (lang === "mermaid") {
      return `<div class="mermaid-block"><pre class="mermaid">${text}</pre></div>`
    }
    let highlighted
    if (window.hljs && lang && window.hljs.getLanguage(lang)) {
      highlighted = window.hljs.highlight(text, { language: lang }).value
    } else if (window.hljs) {
      highlighted = window.hljs.highlightAuto(text).value
    } else {
      highlighted = text
    }
    return `<pre><code class="hljs${lang ? ` language-${lang}` : ""}">${highlighted}</code></pre>`
  }

  // Links open in new tab
  renderer.link = function({ href, title, text }) {
    const titleAttr = title ? ` title="${title}"` : ""
    return `<a href="${href}"${titleAttr} target="_blank" rel="noopener noreferrer">${text}</a>`
  }

  const html = marked.parse(raw, { renderer, breaks: true })

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

async function renderMermaidBlocks(container) {
  const blocks = container.querySelectorAll(".mermaid-block pre.mermaid")
  if (blocks.length === 0) return

  const mermaid = await ensureMermaid()
  for (const block of blocks) {
    const source = block.textContent
    const id = "mermaid-" + Math.random().toString(36).slice(2, 10)
    try {
      const { svg } = await mermaid.render(id, source)
      const wrapper = block.closest(".mermaid-block")
      wrapper.innerHTML = svg
    } catch (_e) {
      // Leave raw source on failure
    }
  }
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
    this.el.innerHTML = renderMarkdownToHTML(raw)
    renderMermaidBlocks(this.el)
  }
}

Hooks.StreamingMarkdown = {
  mounted() {
    this._timer = null
    this._text = ""
    this.handleEvent("streaming_delta", ({ text }) => {
      this._text = text
      if (!this._timer) {
        this._timer = setTimeout(() => {
          this._timer = null
          this.el.innerHTML = renderMarkdownToHTML(this._text, { skipMermaid: true })
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
