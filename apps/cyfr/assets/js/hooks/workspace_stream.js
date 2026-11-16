// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A workspace thread's window in Aqua's browser, live
// (PrismWeb.WorkspaceLive.BrowserLive). Nothing streams until the person
// presses a [data-browser-watch] button, which asks with the size the
// window is drawn at. Each image comes as "browser_image", JPEG in base64,
// and is drawn on the canvas, never through an address, before the hook
// says it drew it ("browser_drawn", naming the image's watch), so the next
// comes only then. The person's pointer, wheel and keys on the canvas go
// back as "browser_input": the events tests/fixtures/browser_frames.json's
// `input` defines, a place being a fraction of the image from its top
// left, at most MAX_EVENTS a push, the moves since the last push folded
// into one, and IN_FLIGHT pushes on their way: the next goes only once the
// server says it took the last ("browser_input_taken"); what comes
// meanwhile waits here, within MAX_EVENTS. The view names the watch the
// page holds (data-watch), and each input push and its answer name it
// too: what the hook holds for a watch, the push on its way and the
// events waiting, ends with that watch, and an answer for another watch
// is passed over.

export const MAX_EVENTS = 64
export const IN_FLIGHT = 1
// The window is scaled to fit the width the canvas is drawn at, sharper on
// a dense screen but no denser than this many device pixels to a CSS one.
export const MAX_DENSITY = 2
export const MAX_SIDE = 1280

// CDP's modifier bits: Alt 1, Control 2, Meta 4, Shift 8.
export function mods(e) {
  return (e.altKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.metaKey ? 4 : 0) | (e.shiftKey ? 8 : 0)
}

const unit = (v) => Math.min(1, Math.max(0, Number.isFinite(v) ? v : 0))

// Where a pointer event is, as a fraction of the drawn image.
export function place(e, rect) {
  return {x: unit((e.clientX - rect.left) / rect.width), y: unit((e.clientY - rect.top) / rect.height)}
}

const BUTTONS = ["left", "middle", "right"]

export function mouse(type, e, rect, pressed) {
  const {x, y} = place(e, rect)
  const button = type === "move" ? pressed || "none" : BUTTONS[e.button] || "none"
  const clicks = type === "move" ? 0 : Math.min(3, Math.max(1, e.detail || 1))
  return {k: "mouse", type, x, y, button, clicks, mods: mods(e)}
}

const DELTA = 10000
const delta = (v) => Math.max(-DELTA, Math.min(DELTA, Math.round(v)))

export function wheel(e, rect) {
  // Lines and pages are as many pixels as a line of text and a screen.
  const scale = e.deltaMode === 1 ? 40 : e.deltaMode === 2 ? 800 : 1
  const {x, y} = place(e, rect)
  return {k: "wheel", x, y, dx: delta(e.deltaX * scale), dy: delta(e.deltaY * scale), mods: mods(e)}
}

const encoder = new TextEncoder()
const bytes = (s) => encoder.encode(s).length

// A key as the window takes it, or null for one the events cannot carry.
// A printable key types its text unless Control or Meta is held; Enter
// types a return.
export function key(type, e) {
  const name = e.key
  if (typeof name !== "string" || bytes(name) < 1 || bytes(name) > 32 || name === "Unidentified") return null
  const code = typeof e.code === "string" && /^[A-Za-z0-9]{0,32}$/.test(e.code) ? e.code : ""
  let text = ""
  if (type === "down" && !e.ctrlKey && !e.metaKey) {
    if (name === "Enter") text = "\r"
    else if ([...name].length === 1 && bytes(name) <= 16) text = name
  }
  const vk = Number.isInteger(e.keyCode) && e.keyCode >= 0 && e.keyCode <= 255 ? e.keyCode : 0
  return {k: "key", type, key: name, code, text, vk, mods: mods(e)}
}

// The events waiting for the next push: a move replaces the move before
// it when nothing came between, and past MAX_EVENTS an event is dropped.
export class Queue {
  constructor() {
    this.events = []
  }

  add(event) {
    const last = this.events[this.events.length - 1]
    if (event.k === "mouse" && event.type === "move" && last?.k === "mouse" && last.type === "move") {
      this.events[this.events.length - 1] = event
    } else if (this.events.length < MAX_EVENTS) {
      this.events.push(event)
    }
  }

  take() {
    const events = this.events
    this.events = []
    return events
  }
}

// The size the window's images are asked at: the canvas's width in device
// pixels, within MAX_DENSITY and MAX_SIDE, in a square box, so the
// window, wider than tall, is scaled to that width.
export function size(width, density) {
  const side = Math.round(Math.min(MAX_SIDE, Math.max(16, width * Math.min(MAX_DENSITY, density || 1))))
  return {width: side, height: side}
}

export function decode(base64) {
  const raw = atob(base64)
  const out = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i)
  return out
}

export const WorkspaceStream = ({createImageBitmap, requestAnimationFrame, devicePixelRatio}) => ({
  mounted() {
    this.begin(this.el.dataset.watch)
    this.flushing = false
    this.onClick = (e) => {
      if (!e.target.closest?.("[data-browser-watch]")) return
      const canvas = this.canvas()
      const width = canvas?.parentElement?.clientWidth || this.el.clientWidth || 640
      this.pushEvent("browser_watch", size(width, devicePixelRatio()))
    }
    this.el.addEventListener("click", this.onClick)
    this.handleEvent("browser_image", ({watch, n, jpeg}) => this.draw(watch, n, jpeg))
    this.handleEvent("browser_input_taken", ({watch}) => {
      if (watch !== this.watch) return
      this.inFlight = Math.max(0, this.inFlight - 1)
      this.schedule()
    })
    this.listen(this.canvas())
  },

  updated() {
    if ((this.el.dataset.watch || null) !== this.watch) this.begin(this.el.dataset.watch)
  },

  // A watch starts with nothing of the one before it: no push on its way
  // and no event waiting. With no watch, nothing is kept or sent.
  begin(watch) {
    this.watch = watch || null
    this.queue = new Queue()
    this.inFlight = 0
    this.pressed = null
    this.touch = null
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },

  canvas() {
    return this.el.querySelector("canvas")
  },

  // The image's watch is named back with it, as it came: an image a closed
  // watch sent may finish drawing after the next watch began.
  async draw(watch, n, jpeg) {
    const canvas = this.canvas()
    try {
      const image = await createImageBitmap(new Blob([decode(jpeg)], {type: "image/jpeg"}))
      canvas.width = image.width
      canvas.height = image.height
      canvas.getContext("2d").drawImage(image, 0, 0)
      image.close?.()
    } catch {
      // An image that does not decode is passed over; the next replaces it.
    }
    this.pushEvent("browser_drawn", {watch, n})
  },

  send(event) {
    if (!event || !this.watch) return
    this.queue.add(event)
    this.schedule()
  },

  // One push a frame, and none while IN_FLIGHT are on their way.
  schedule() {
    if (this.flushing || this.inFlight >= IN_FLIGHT || this.queue.events.length === 0) return
    this.flushing = true
    requestAnimationFrame(() => {
      this.flushing = false
      if (this.inFlight >= IN_FLIGHT) return
      const events = this.queue.take()
      if (events.length === 0) return
      this.inFlight++
      this.pushEvent("browser_input", {watch: this.watch, browser_input: events})
    })
  },

  listen(canvas) {
    if (!canvas) return
    const rect = () => canvas.getBoundingClientRect()
    canvas.addEventListener("pointerdown", (e) => {
      canvas.focus()
      if (e.pointerType === "touch") {
        this.touch = {x: e.clientX, y: e.clientY, moved: false}
        return
      }
      e.preventDefault()
      this.pressed = BUTTONS[e.button] || null
      canvas.setPointerCapture?.(e.pointerId)
      this.send(mouse("down", e, rect()))
    })
    canvas.addEventListener("pointermove", (e) => {
      if (e.pointerType === "touch" && this.touch) {
        // A finger drawn across scrolls the page under it, as on the phone.
        const r = rect()
        const scale = canvas.width / r.width || 1
        const dx = (this.touch.x - e.clientX) * scale
        const dy = (this.touch.y - e.clientY) * scale
        if (Math.abs(dx) + Math.abs(dy) < 4) return
        this.touch = {x: e.clientX, y: e.clientY, moved: true}
        this.send({k: "wheel", ...place(e, r), dx: delta(dx), dy: delta(dy), mods: 0})
        return
      }
      this.send(mouse("move", e, rect(), this.pressed))
    })
    canvas.addEventListener("pointerup", (e) => {
      if (e.pointerType === "touch") {
        // A tap is a click where the finger lifted.
        if (this.touch && !this.touch.moved) {
          this.send(mouse("down", e, rect()))
          this.send(mouse("up", e, rect()))
        }
        this.touch = null
        return
      }
      this.pressed = null
      this.send(mouse("up", e, rect()))
    })
    canvas.addEventListener(
      "wheel",
      (e) => {
        e.preventDefault()
        this.send(wheel(e, rect()))
      },
      {passive: false}
    )
    canvas.addEventListener("contextmenu", (e) => e.preventDefault())
    canvas.addEventListener("keydown", (e) => {
      e.preventDefault()
      e.stopPropagation()
      this.send(key("down", e))
    })
    canvas.addEventListener("keyup", (e) => {
      e.preventDefault()
      e.stopPropagation()
      this.send(key("up", e))
    })
  }
})

export default WorkspaceStream({
  createImageBitmap: (...args) => window.createImageBitmap(...args),
  requestAnimationFrame: (fn) => window.requestAnimationFrame(fn),
  devicePixelRatio: () => window.devicePixelRatio
})
