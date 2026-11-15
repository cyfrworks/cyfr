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
// What goes to the program is what the person types and the terminal's own
// answers to a program's standard queries (the cursor position, the device
// attributes, a mode's or a setting's state), which full-screen programs
// need and which carry only the terminal's state back to the program that
// asked. Nothing a program prints makes the terminal send text the program
// chose: every window operation is off, the title and icon reports among
// them (`windowOptions`, all off, set here so no default can change it),
// a settings query (DECRQSS) answers a setting's value, never the words it
// was asked, and a colour query answers the colour as numbers.
//
// `TerminalHook(deps)` is the LiveView hook, its terminal, addons and
// window opener given, so a test drives it without a browser.

// The OSC numbers whose effects the terminal never carries out: the window
// and icon titles, and a clipboard write.
export const SWALLOWED_OSC = [0, 1, 2, 52]

// What the person types or pastes goes to the server a piece at a time,
// each answered before the next is sent, so a paste waits here rather
// than on the server. A piece is at most this many UTF-16 units, which
// is under the wire's 64 KiB as UTF-8; what waits is at most
// MAX_PENDING_UNITS, and a paste past it is not sent.
export const PIECE_UNITS = 16384
export const MAX_PENDING_UNITS = 1048576

// `text` cut into pieces of at most `units` UTF-16 units, never between
// the two halves of a surrogate pair.
export function pieces(text, units = PIECE_UNITS) {
  const out = []
  let at = 0
  while (at < text.length) {
    let end = Math.min(at + units, text.length)
    const last = text.charCodeAt(end - 1)
    if (end < text.length && last >= 0xd800 && last <= 0xdbff) end -= 1
    out.push(text.slice(at, end))
    at = end
  }
  return out
}

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
        windowOptions: {},
        linkHandler: {activate: (_event, uri) => openLink(uri, open), allowNonHttpProtocols: false}
      })
      this.term = term
      for (const osc of SWALLOWED_OSC) term.parser.registerOscHandler(osc, () => true)

      this.fit = new FitAddon()
      term.loadAddon(this.fit)
      term.loadAddon(new WebLinksAddon((_event, uri) => openLink(uri, open)))
      term.open(screen)

      this.queue = []
      this.queued = 0
      this.sending = false
      this.replaying = false
      term.onData((data) => this.type(data))

      // Each output is acknowledged by its token once drawn, and the
      // server hands the next only then; a tail replaces what is shown,
      // since what came before it was let go.
      this.handleEvent("terminal_output", ({session, delivery, data}) => {
        if (session === this.session) term.write(decode(data), () => this.written(delivery))
      })
      this.handleEvent("terminal_tail", ({session, delivery, data}) => {
        if (session !== this.session) return
        term.reset()
        this.replay(decode(data), () => this.written(delivery))
      })

      // The program ended: the screen stays as it was to be read, and
      // takes no more typing or resizing.
      this.ended = false
      this.handleEvent("terminal_ended", ({session}) => {
        if (session !== this.session) return
        this.ended = true
        this.queue = []
        this.queued = 0
        term.options.disableStdin = true
        term.options.cursorBlink = false
        window.removeEventListener("resize", this.onResize)
      })

      this.onResize = () => this.resized()
      window.addEventListener("resize", this.onResize)

      // Attached once the frame stands, so what was printed before arrives
      // here first and every later write after it.
      this.fit.fit()
      this.size = {rows: term.rows, cols: term.cols}
      this.pushEvent("terminal_ready", {session: this.session, ...this.size}, (reply) => {
        if (reply && typeof reply.data === "string") this.replay(decode(reply.data))
        term.focus()
      })
    },

    // What the program printed before, drawn again: a query in it was
    // answered when the program asked it, so the terminal's answers to it
    // now are not the program's to read and are not sent.
    replay(bytes, done) {
      this.replaying = true
      this.term.write(bytes, () => {
        this.replaying = false
        if (done) done()
      })
    },

    written(delivery) {
      if (this.ended) return
      this.pushEvent("terminal_written", {session: this.session, delivery})
    },

    // What the person typed, queued and sent a piece at a time.
    type(data) {
      if (this.ended || this.replaying || this.queued + data.length > MAX_PENDING_UNITS) return
      for (const piece of pieces(data)) this.queue.push(piece)
      this.queued += data.length
      this.send()
    },

    send() {
      if (this.ended || this.sending || this.queue.length === 0) return
      const piece = this.queue.shift()
      this.queued -= piece.length
      this.sending = true
      this.pushEvent("terminal_input", {session: this.session, terminal_input: piece}, () => {
        this.sending = false
        this.send()
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
