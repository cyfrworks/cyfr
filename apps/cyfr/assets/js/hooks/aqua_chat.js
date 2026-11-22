// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Chat composer textarea hook (ThreadPaneLive).
//
// - Takes focus when it mounts — a pane opening, a thread switching, the
//   person's own Aqua panel opening — unless focus already sits inside a
//   dialog: the open panel owns focus, and the page's own pane mounting
//   beside it must not pull it back out.
// - Auto-grows from one row up to a max height (then scrolls).
// - `aqua:composer` sets the composer's text from the server, as
//   `{pane, value}`: LiveView leaves a focused textarea's value alone, so a
//   sentence a desktop asks would otherwise never show in a composer that
//   took focus as the panel opened. LiveView dispatches a pushed event to
//   every hook on the page, so a composer acts only on its own pane's id.
// - Enter (no modifiers) submits the composer form.
// - Shift+Enter / Ctrl+Enter / Cmd+Enter insert a newline at the cursor.
// - Pasted files (typically screenshots from a clipboard manager) are injected
//   into the LiveView upload pipeline via a "track-uploads" CustomEvent on the
//   live_file_input; image files with auto-generated names get a timestamped
//   filename so multiple pastes don't collide.
// - `cyfr:capture`, a DOM event on this composer's textarea with
//   `{kind: "still" | "clip" | "cancel"}`, takes one still or one clip
//   (../capture.js) into the same upload; the person still sends the
//   draft. Prism draws no control for it, and the shipped app refuses the
//   devices. One runs at a time, and a cancel, this hook's end, the page
//   left and a live navigation each end it with nothing attached.

import {capture} from "../capture.js"

const MAX_HEIGHT = 160 // px — keep in sync with the textarea's max-h-40 class

function focusHeldByDialog() {
  const active = document.activeElement
  return !!(active && active.closest && active.closest("[role='dialog']"))
}

const AquaChat = {
  _focus() {
    if (this.el.disabled) return
    if (focusHeldByDialog() && !this.el.closest("[role='dialog']")) return
    this.el.focus()
  },

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

  // This composer's own upload input: a page may hold more than one pane.
  _uploadInput() {
    const scope = this.el.form || this.el.closest("form") || document
    return scope.querySelector("input[data-phx-upload-ref]")
  },

  _attach(files) {
    this._uploadInput()?.dispatchEvent(
      new CustomEvent("track-uploads", {
        bubbles: true,
        detail: { files }
      })
    )
  },

  async _capture(kind) {
    if (this._capturing || this.el.disabled || !this._uploadInput()) return
    const capturing = new AbortController()
    this._capturing = capturing
    const file = await capture(kind, capturing.signal)
    if (this._capturing !== capturing) return
    this._capturing = null
    if (file) this._attach([file])
  },

  _endCapture() {
    this._capturing?.abort()
    this._capturing = null
  },

  mounted() {
    this._onInput = () => this._resize()
    this.el.addEventListener("input", this._onInput)
    this._resize()
    this._focus()

    this.handleEvent("aqua:composer", ({pane, value}) => {
      const section = this.el.closest("section[id]")
      if (!section || pane !== section.id || typeof value !== "string") return
      this.el.value = value
      this._resize()
      this.el.selectionStart = this.el.selectionEnd = value.length
      this.el.scrollTop = this.el.scrollHeight
    })

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
      form.requestSubmit()
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
      this._attach(files)
    }

    this.el.addEventListener("paste", this._onPaste)

    this._onCapture = (e) => {
      if (e.detail?.kind === "cancel") this._endCapture()
      else this._capture(e.detail?.kind)
    }
    this._onLeave = () => this._endCapture()
    this._onLoading = (e) => {
      if (["redirect", "patch"].includes(e.detail?.kind)) this._endCapture()
    }
    this.el.addEventListener("cyfr:capture", this._onCapture)
    window.addEventListener("pagehide", this._onLeave)
    window.addEventListener("phx:page-loading-start", this._onLoading)
  },

  updated() {
    // Re-fit after LiveView re-renders the textarea (e.g. cleared after send).
    this._resize()
  },

  destroyed() {
    this._endCapture()
    if (this._onCapture) this.el.removeEventListener("cyfr:capture", this._onCapture)
    if (this._onLeave) window.removeEventListener("pagehide", this._onLeave)
    if (this._onLoading) window.removeEventListener("phx:page-loading-start", this._onLoading)
    if (this._onInput) this.el.removeEventListener("input", this._onInput)
    if (this._onKeyDown) this.el.removeEventListener("keydown", this._onKeyDown)
    if (this._onPaste) this.el.removeEventListener("paste", this._onPaste)
  }
}

export default AquaChat