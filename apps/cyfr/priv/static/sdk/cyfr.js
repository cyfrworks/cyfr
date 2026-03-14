/**
 * Cyfr App SDK — thin bridge for iframe apps to communicate with the Prism shell.
 *
 * Usage:
 *   <script src="/sdk/cyfr.js"></script>
 *   cyfr.ready()
 *   const result = await cyfr.callTool("execution/list", { limit: 10 })
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

  // Public API
  window.cyfr = {
    /**
     * Call an MCP tool through the shell.
     * @param {string} tool - Tool name (e.g., "execution/list")
     * @param {object} args - Tool arguments
     * @returns {Promise<any>} Tool result
     */
    callTool: function(tool, args) {
      return _send("tool_call", { tool: tool, args: args || {} })
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
     * Close this app's window.
     */
    close: function() {
      return _send("close", {})
    },

    /**
     * Get context information about this app window.
     * @returns {Promise<{app_id: string, window_id: string}>}
     */
    getContext: function() {
      return _send("get_context", {})
    },

    /**
     * Signal that the app is ready. Call this after initialization.
     * @returns {Promise<{ok: true}>}
     */
    ready: function() {
      return _send("ready", {})
    }
  }
})()
