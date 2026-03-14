/**
 * IframeBridge hook — bridges postMessage between sandboxed iframe apps
 * and the LiveView shell via pushEvent / handleEvent.
 */
const IframeBridge = {
  mounted() {
    this._windowId = this.el.dataset.windowId

    // Listen for messages from the iframe
    this._messageHandler = (event) => {
      // Validate source is our iframe
      if (event.source !== this.el.contentWindow) return

      const msg = event.data
      if (!msg || typeof msg !== "object") return
      if (!msg.type || !msg.type.startsWith("cyfr:")) return

      // Forward to LiveView
      this.pushEvent("iframe_message", {
        window_id: this._windowId,
        message: msg
      })
    }
    window.addEventListener("message", this._messageHandler)

    // Listen for responses from LiveView to forward to iframe
    this.handleEvent(`iframe_response:${this._windowId}`, (response) => {
      if (this.el.contentWindow) {
        this.el.contentWindow.postMessage(response, "*")
      }
    })

    // Listen for push events from LiveView to forward to iframe
    this.handleEvent(`iframe_event:${this._windowId}`, (event) => {
      if (this.el.contentWindow) {
        this.el.contentWindow.postMessage(event, "*")
      }
    })
  },

  destroyed() {
    if (this._messageHandler) {
      window.removeEventListener("message", this._messageHandler)
    }
  }
}

export default IframeBridge
