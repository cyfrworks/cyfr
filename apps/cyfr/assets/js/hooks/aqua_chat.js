// AquaLive textarea hook — paste-file handling.
//
// When the user pastes one or more files (typically screenshots from a
// clipboard manager), inject them into the LiveView upload pipeline by
// dispatching a "track-uploads" CustomEvent on the live_file_input. Image
// files with auto-generated names get a timestamped filename so multiple
// pastes don't collide.
//
// This is a paste-only port of the AgentChat hook. AquaLive uses a <select>
// for orchestrator switching and form-level phx-submit, so we don't need
// AgentChat's mention popup, auto-resize, or Enter-to-send code.

const AquaChat = {
  mounted() {
    this._onPaste = (e) => {
      const items = e.clipboardData && e.clipboardData.items
      if (!items) return

      const files = []
      for (let i = 0; i < items.length; i++) {
        if (items[i].kind !== "file") continue
        const file = items[i].getAsFile()
        if (!file) continue

        if (file.type.startsWith("image/") && (!file.name || file.name === "image.png")) {
          const ext = file.type.split("/")[1] || "png"
          const ts = new Date().toISOString().replace(/[:.]/g, "-")
          files.push(new File([file], `screenshot-${ts}.${ext}`, { type: file.type }))
        } else {
          files.push(file)
        }
      }

      if (files.length === 0) return
      e.preventDefault()

      const fileInput = document.querySelector("input[data-phx-upload-ref]")
      if (!fileInput) return

      fileInput.dispatchEvent(
        new CustomEvent("track-uploads", {
          bubbles: true,
          detail: { files }
        })
      )
    }

    this.el.addEventListener("paste", this._onPaste)
  },

  destroyed() {
    if (this._onPaste) {
      this.el.removeEventListener("paste", this._onPaste)
    }
  }
}

export default AquaChat
