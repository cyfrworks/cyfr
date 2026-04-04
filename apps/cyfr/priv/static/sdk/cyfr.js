/**
 * Cyfr Tincture SDK — bridge for tincture iframes to communicate with the Prism shell.
 *
 * Auto-injected into every tincture's <head> at serve time (nonce-secured).
 * No <script> tag needed — window.cyfr is always available.
 *
 *   cyfr.ready()
 *   const data = await cyfr.query("latest", { symbol: "AAPL" })
 */
(function() {
  "use strict"

  let _requestId = 0
  const _pending = new Map()
  const _listeners = new Map()
  const REQUEST_TIMEOUT = 30000

  function _nextId() {
    return "req_" + (++_requestId) + "_" + Math.random().toString(36).slice(2, 8)
  }

  function _send(action, payload) {
    return new Promise((resolve, reject) => {
      const id = _nextId()

      const timer = setTimeout(() => {
        _pending.delete(id)
        reject(new Error("Request timed out: " + action))
      }, REQUEST_TIMEOUT)

      _pending.set(id, { resolve, reject, timer })

      // Use "*" because sandboxed iframes (no allow-same-origin) have an
      // opaque origin ("null"), so a specific targetOrigin would never match
      // the parent. Security is maintained by the parent's source check.
      window.parent.postMessage({
        type: "cyfr:request",
        id: id,
        action: action,
        payload: payload
      }, "*")
    })
  }

  // Listen for responses from the shell
  window.addEventListener("message", function(event) {
    const msg = event.data
    if (!msg || typeof msg !== "object") return

    if (msg.type === "cyfr:response" && msg.id) {
      const pending = _pending.get(msg.id)
      if (pending) {
        _pending.delete(msg.id)
        clearTimeout(pending.timer)
        if (msg.error) {
          pending.reject(new Error(msg.error))
        } else {
          pending.resolve(msg.result)
        }
      }
    }

    if (msg.type === "cyfr:event" && msg.event) {
      const handlers = _listeners.get(msg.event) || []
      handlers.forEach(function(fn) {
        try { fn(msg.data) } catch(_e) { /* ignore */ }
      })
    }
  })

  // Mode detection: shell (iframe inside Prism) or public (standalone page)
  var _mode = (window.parent !== window) ? "shell" : "public"

  function _encodeParams(params) {
    if (!params) return ""
    return Object.keys(params).map(function(k) {
      return encodeURIComponent(k) + "=" + encodeURIComponent(params[k])
    }).join("&")
  }

  // Public API
  window.cyfr = {
    /** Current mode: "shell" or "public" */
    mode: _mode,

    /**
     * Execute a named query against the tincture's data.db.
     * In public mode: fetches via HTTP. In shell mode: bridges via postMessage.
     * @param {string} name - Query name (declared in manifest schema.queries)
     * @param {object} params - Query parameters
     * @returns {Promise<{data: Array, columns: Array, cached: boolean}>}
     */
    query: function(name, params) {
      if (_mode === "public") {
        var segments = window.location.pathname.split("/")
        var publisher = segments[2]
        var tinctureName = segments[3]
        var qs = _encodeParams(params)
        var url = "/t/" + publisher + "/" + tinctureName + "/q/" + name
        if (qs) url += "?" + qs
        return fetch(url).then(function(r) {
          if (!r.ok) return r.json().then(function(e) { throw new Error(e.error || "Query failed") })
          return r.json()
        })
      } else {
        return _send("query", { name: name, params: params || {} })
      }
    },

    /**
     * Subscribe to shell events.
     * @param {string} event - Event name
     * @param {function} callback - Handler function
     */
    on: function(event, callback) {
      if (!_listeners.has(event)) {
        _listeners.set(event, [])
      }
      _listeners.get(event).push(callback)
    },

    /**
     * Unsubscribe from shell events.
     * @param {string} event - Event name
     * @param {function} callback - Handler to remove
     */
    off: function(event, callback) {
      const handlers = _listeners.get(event)
      if (handlers) {
        _listeners.set(event, handlers.filter(function(fn) { return fn !== callback }))
      }
    },

    /**
     * Update the window title.
     * @param {string} title - New window title
     */
    setTitle: function(title) {
      return _send("set_title", { title: title })
    },

    /**
     * Close this tincture's window.
     */
    close: function() {
      return _send("close", {})
    },

    /**
     * Get context information about this tincture window.
     * @returns {Promise<{tincture_id: string, window_id: string}>}
     */
    getContext: function() {
      return _send("get_context", {})
    },

    /**
     * Signal that the tincture is ready. Call this after initialization.
     * @returns {Promise<{ok: true}>}
     */
    ready: function() {
      return _send("ready", {})
    }
  }
})()
