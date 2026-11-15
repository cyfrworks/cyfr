// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A program's terminal on the Programs page: the vendored xterm.js drawing
// what the program writes, inside CYFR's own frame. The terminal acts on
// nothing the program writes: it writes no clipboard (OSC 52 is swallowed,
// and no clipboard addon is loaded), sets no title (OSC 0, 1 and 2 are
// swallowed and no title listener is attached), sounds no bell (no bell
// listener is attached), and opens an address only when the person clicks
// it, an http or https one alone, in a new tab that cannot reach this page.
// It stores nothing and logs nothing: what passes is handed to the server
// as the person types it and drawn as the server hands it on.
//
// `TerminalHook(deps)` is the LiveView hook, its terminal, addons and
// window opener given, so a test drives it without a browser.

// The OSC numbers whose effects the terminal never carries out: the window
// and icon titles, and a clipboard write.
export const SWALLOWED_OSC = [0, 1, 2, 52]

// Open `uri` for the person, who clicked it: an http or https address
// alone, with no opener and no referrer. Answers whether it opened.
export function openLink(uri, open) {
  let url
  try {
    url = new URL(uri)
  } catch {
    return false
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return false
  open(url.href, "_blank", "noopener,noreferrer")
  return true
}

// Standard base64 to bytes, as the server encodes a chunk.
export function decode(data) {
  const text = atob(data)
  const bytes = new Uint8Array(text.length)
  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i)
  return bytes
}

export function TerminalHook({Terminal, FitAddon, WebLinksAddon, open}) {
  return {
    mounted() {
      this.session = this.el.dataset.session
      const screen = this.el.querySelector("[data-terminal-screen]")
      const term = new Terminal({
        cursorBlink: true,
        scrollback: 5000,
        fontSize: 13,
        allowProposedApi: false,
        linkHandler: {activate: (_event, uri) => openLink(uri, open), allowNonHttpProtocols: false}
      })
      this.term = term
      for (const osc of SWALLOWED_OSC) term.parser.registerOscHandler(osc, () => true)

      this.fit = new FitAddon()
      term.loadAddon(this.fit)
      term.loadAddon(new WebLinksAddon((_event, uri) => openLink(uri, open)))
      term.open(screen)

      term.onData((data) => this.pushEvent("terminal_input", {session: this.session, terminal_input: data}))

      this.handleEvent("terminal_output", ({session, data}) => {
        if (session === this.session) term.write(decode(data))
      })

      this.onResize = () => this.resized()
      window.addEventListener("resize", this.onResize)

      // Attached once the frame stands, so what was printed before arrives
      // here first and every later write after it.
      this.fit.fit()
      this.size = {rows: term.rows, cols: term.cols}
      this.pushEvent("terminal_ready", {session: this.session, ...this.size}, (reply) => {
        if (reply && typeof reply.data === "string") term.write(decode(reply.data))
        term.focus()
      })
    },

    // The frame's size changed: the terminal fits it again and tells the
    // program its new size.
    resized() {
      this.fit.fit()
      const size = {rows: this.term.rows, cols: this.term.cols}
      if (size.rows === this.size.rows && size.cols === this.size.cols) return
      this.size = size
      this.pushEvent("terminal_resize", {session: this.session, ...size})
    },

    destroyed() {
      window.removeEventListener("resize", this.onResize)
      this.term.dispose()
    }
  }
}
