import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import ShellViewport from "./hooks/window_manager"
import IframeBridge from "./hooks/iframe_bridge"
import CommandPalette from "./hooks/command_palette"
import PageLoadingIndicator from "./hooks/page_loading_indicator"
import OptimisticNav from "./hooks/optimistic_nav"
import Aqua from "./hooks/aqua"
import AquaChat from "./hooks/aqua_chat"
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
Hooks.PageLoadingIndicator = PageLoadingIndicator
Hooks.OptimisticNav = OptimisticNav
Hooks.Aqua = Aqua
Hooks.AquaChat = AquaChat

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

// The PWA's service worker, by its literal path: `/sw.js` is served
// undigested so the registration is stable across releases.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch(() => {})
  })
}

window.liveSocket = liveSocket

window.addEventListener("phx:clipboard", (e) => {
  if (e.detail && e.detail.text) {
    navigator.clipboard.writeText(e.detail.text)
  }
})
