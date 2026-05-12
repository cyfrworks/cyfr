// AquaLive textarea hook.
//
// - Auto-grows from one row up to a max height (then scrolls).
// - Enter (no modifiers) submits the composer form.
// - Shift+Enter / Ctrl+Enter / Cmd+Enter insert a newline at the cursor.
// - Pasted files (typically screenshots from a clipboard manager) are injected
//   into the LiveView upload pipeline via a "track-uploads" CustomEvent on the
//   live_file_input; image files with auto-generated names get a timestamped
//   filename so multiple pastes don't collide.

const MAX_HEIGHT = 160 // px — keep in sync with the textarea's max-h-40 class

const AquaChat = {
  _resize() {
    const el = this.el
    el.style.height = "auto"
    el.style.height = Math.min(el.scrollHeight, MAX_HEIGHT) + "px"
    // Resetting height to "auto" loses scrollTop, so once we're past the max
    // height the view snaps back to the top line. Keep the caret in view: when
    // it's at the end of the text (the common case while typing/pasting), pin
    // to the bottom.
    if (el.scrollHeight > el.clientHeight && el.selectionEnd === el.value.length) {
      el.scrollTop = el.scrollHeight
    }
  },

  mounted() {
    this._onInput = () => this._resize()
    this.el.addEventListener("input", this._onInput)
    this._resize()

    this._onKeyDown = (e) => {
      if (e.key !== "Enter" || e.isComposing) return

      // Newline at the cursor for Shift/Ctrl/Cmd+Enter.
      if (e.shiftKey || e.ctrlKey || e.metaKey) {
        e.preventDefault()
        const el = this.el
        const start = el.selectionStart
        const end = el.selectionEnd
        el.value = el.value.slice(0, start) + "\n" + el.value.slice(end)
        el.selectionStart = el.selectionEnd = start + 1
        el.dispatchEvent(new Event("input", { bubbles: true }))
        return
      }

      // Plain Enter — submit (unless the box is empty).
      e.preventDefault()
      if (this.el.value.trim() === "") return
      const form = this.el.form || this.el.closest("form")
      if (!form) return
      if (typeof form.requestSubmit === "function") form.requestSubmit()
      else form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
    }
    this.el.addEventListener("keydown", this._onKeyDown)

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

  updated() {
    // Re-fit after LiveView re-renders the textarea (e.g. cleared after send).
    this._resize()
  },

  destroyed() {
    if (this._onInput) this.el.removeEventListener("input", this._onInput)
    if (this._onKeyDown) this.el.removeEventListener("keydown", this._onKeyDown)
    if (this._onPaste) this.el.removeEventListener("paste", this._onPaste)
  }
}

export default AquaChat
