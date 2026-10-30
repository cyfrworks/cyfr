// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The window gestures and keys of the `Canvas` hook (`./index.js`), mixed
// into it: the placement math is `./geometry.js`'s; these wire the pointer,
// the keys and the window to it and send the shell one arrangement event
// per settled gesture (`PrismWeb.ShellLive`: `frame_move`, `frame_resize`,
// `frame_tile`, `frame_full`, `frame_minimise`, `frame_close`,
// `frame_raise`, `switch_canvas`).
//
// A press on an app's title bar (`data-canvas-grip`) released without
// travelling raises it unless it is the active one; travelling DRAG_MIN_PX
// makes a window's press a drag, which sends its move alone; a double
// click makes the window full. Nothing is sent before the pointer settles,
// so a cancelled press changes nothing. A press on an edge (`data-canvas-edge`)
// resizes a window, or moves a tile's divider. While a gesture runs, a
// shield covers every frame, so no frame under the pointer takes it, and
// a stylesheet of the hook's own holds the wrapper where the gesture puts
// it, over the style the server rendered, until the shell answers the
// settled event. Each held element belongs to the gesture that last held
// it, and an answer releases only what its own gesture still holds, so a
// late answer to one gesture never moves what a newer one holds. A drop with the pointer at the left or right edge of the
// apps' area tiles the window there, at the top makes it full; the shield
// shows where it would go. A release anywhere settles the gesture; a
// cancel, a lost capture, the window losing focus, the page hidden and the
// socket dropping end it with nothing sent, the window back where it was.
//
// The shield and the stylesheet live in the layer's `-geometry` element,
// which the server renders empty with `phx-update="ignore"`, so no patch
// touches them. Every event goes from the hook's own element.

import {
  DRAG_MIN_PX,
  dividerWidth,
  geometryOf,
  moved,
  overrides,
  parseGeometry,
  resized,
  shareOf,
  snapAt,
  snapBox
} from "./geometry.js"
import {windowChord} from "./signals.js"

const ACTIVE = '[data-canvas-frame][data-canvas-active="true"]'
const CONTROL = "button, a, input, select, textarea"
const SWITCHER = "#canvas-switcher button[data-canvas]"

// A tile's share when the app gives none.
const DEFAULT_SHARE = 5000

export const WindowGestures = {
  _windowsMount() {
    this._gesture = null
    this._gestures = 0
    // Element id → {gesture, box}: what holds it, and where.
    this._held = new Map()
    this._onWindowDown = (event) => this._windowDown(event)
    this._onWindowMove = (event) => this._windowMove(event)
    this._onWindowUp = (event) => this._windowUp(event)
    this._onWindowLost = (event) => this._windowCancel(event)
    this._onDoubleClick = (event) => this._windowDouble(event)
    this._onBlur = () => this._windowBlur()
    this._onVisibility = () => {
      if (globalThis.document?.visibilityState === "hidden") this._windowCancel()
    }

    this._layer.addEventListener?.("pointerdown", this._onWindowDown)
    this._layer.addEventListener?.("pointermove", this._onWindowMove)
    this._layer.addEventListener?.("pointerup", this._onWindowUp)
    this._layer.addEventListener?.("pointercancel", this._onWindowLost)
    this._layer.addEventListener?.("lostpointercapture", this._onWindowLost)
    this._layer.addEventListener?.("dblclick", this._onDoubleClick)
    globalThis.window?.addEventListener("blur", this._onBlur)
    globalThis.document?.addEventListener?.("visibilitychange", this._onVisibility)
  },

  // The socket dropped: a gesture under way cannot be sent, and an answer
  // still awaited will not come, so every held wrapper goes back.
  _windowsDisconnected() {
    this._windowCancel()
    this._held.clear()
    this._writeHeld()
  },

  _windowsDestroy() {
    this._windowCancel()
    this._layer.removeEventListener?.("pointerdown", this._onWindowDown)
    this._layer.removeEventListener?.("pointermove", this._onWindowMove)
    this._layer.removeEventListener?.("pointerup", this._onWindowUp)
    this._layer.removeEventListener?.("pointercancel", this._onWindowLost)
    this._layer.removeEventListener?.("lostpointercapture", this._onWindowLost)
    this._layer.removeEventListener?.("dblclick", this._onDoubleClick)
    globalThis.window?.removeEventListener("blur", this._onBlur)
    globalThis.document?.removeEventListener?.("visibilitychange", this._onVisibility)
  },

  // The keys: what windowChord reads, acting on the active app; with none,
  // the arrows switch canvases. True when the key was the canvas's.
  _windowKey(event) {
    const chord = windowChord(event)
    if (chord === null) return false
    event.preventDefault?.()
    if (!this._connected) return true

    if (chord.act === "canvas") {
      const dot = Array.from(this._layer.querySelectorAll(SWITCHER))[chord.index]
      if (dot) this.pushEvent("switch_canvas", {canvas: dot.dataset.canvas})
      return true
    }

    const active = this._layer.querySelector(ACTIVE)
    if (!active) {
      if (chord.act === "tile") {
        this.pushEvent("switch_canvas", {direction: chord.side === "left" ? "previous" : "next"})
      }
      return true
    }

    const frame = active.dataset.canvasFrame
    const place = active.dataset.canvasPlace
    switch (chord.act) {
      case "tile":
        this.pushEvent("frame_tile", {frame, side: chord.side, share: tileShare(active)})
        break
      case "full":
        if (place !== "full") this.pushEvent("frame_full", {frame})
        break
      case "window": {
        const geometry = parseGeometry(active.dataset.canvasWindow)
        if (place !== "window" && geometry) this.pushEvent("frame_move", {frame, geometry})
        break
      }
      case "minimise":
        this.pushEvent("frame_minimise", {frame})
        break
      case "close":
        this.pushEvent("frame_close", {frame})
        break
    }
    return true
  },

  _windowDown(event) {
    if (event.button !== 0 || this._gesture || this._posture === "hand") return
    const target = event.target
    if (!target || typeof target.closest !== "function") return
    const wrapper = target.closest("[data-canvas-frame]")
    if (!wrapper || target.closest(CONTROL)) return
    const edge = target.closest("[data-canvas-edge]")
    const grip = target.closest("[data-canvas-grip]")
    if (!edge && !grip) return

    const place = wrapper.dataset.canvasPlace
    const frame = wrapper.dataset.canvasFrame

    let kind = null
    if (edge && place === "window") kind = "resize"
    else if (edge && place === "tile") kind = "divider"
    else if (grip && place === "window") kind = "drag"
    // A tile's title bar does not drag: a press on it can only raise.
    else if (grip && place === "tile") kind = "press"
    if (!kind) return

    event.preventDefault?.()
    const area = this._area()
    if (!area) return
    this._gesture = {
      token: ++this._gestures,
      kind,
      frame,
      // A press on an inactive app's title bar raises it once it settles
      // as a click.
      raise: Boolean(grip) && wrapper.dataset.canvasActive !== "true",
      wrapper,
      edge: edge ? edge.dataset.canvasEdge : null,
      side: wrapper.dataset.canvasSide,
      start: relative(wrapper, area),
      canvas: kind === "divider" ? this._canvasBox(area) : null,
      area,
      x: event.clientX,
      y: event.clientY,
      id: event.pointerId,
      capture: target,
      // Nothing moves, and nothing is sent, until the pointer travels.
      moved: false
    }
    target.setPointerCapture?.(event.pointerId)
    // A release outside the layer, or outside the window, still settles it.
    globalThis.window?.addEventListener("pointerup", this._onWindowUp)
  },

  _windowMove(event) {
    const g = this._gesture
    if (!g || event.pointerId !== g.id) return
    const dx = event.clientX - g.x
    const dy = event.clientY - g.y
    if (g.kind === "press") return
    if (!g.moved) {
      if (Math.abs(dx) < DRAG_MIN_PX && Math.abs(dy) < DRAG_MIN_PX) return
      g.moved = true
      this._shield(g.kind)
    }
    this._hold(g, this._shaped(g, event))
  },

  _windowUp(event) {
    const g = this._end(event.pointerId)
    if (!g) return
    // A press that settled where it began is a click: it raises the app.
    if (!g.moved) {
      if (g.raise && this._connected) this.pushEvent("frame_raise", {frame: g.frame})
      return
    }
    const shaped = this._shaped(g, event)
    this._hold(g, shaped)

    const settle = (name, payload) => {
      if (!this._connected) return this._release(g)
      this.pushEvent(name, payload, () => this._release(g))
    }

    if (g.kind === "drag" && shaped.snap === "full") return settle("frame_full", {frame: g.frame})
    if (g.kind === "drag" && shaped.snap) {
      return settle("frame_tile", {frame: g.frame, side: shaped.snap, share: tileShare(g.wrapper)})
    }
    if (g.kind === "drag") return settle("frame_move", {frame: g.frame, geometry: geometryOf(shaped.box, g.area)})
    if (g.kind === "resize") return settle("frame_resize", {frame: g.frame, geometry: geometryOf(shaped.box, g.area)})
    return settle("frame_resize", {frame: g.frame, share: shareOf(shaped.box.width, g.area)})
  },

  // A gesture that does not settle: the wrapper goes back to the style the
  // server rendered, and nothing is sent. With an event, only its own
  // pointer's.
  _windowCancel(event = null) {
    const g = this._end(event ? event.pointerId : null)
    if (g) this._release(g)
  },

  _windowDouble(event) {
    const target = event.target
    if (!target || typeof target.closest !== "function" || target.closest(CONTROL)) return
    const grip = target.closest("[data-canvas-grip]")
    const wrapper = grip && target.closest("[data-canvas-frame]")
    if (!wrapper || !this._connected || this._posture === "hand") return
    this.pushEvent("frame_full", {frame: wrapper.dataset.canvasFrame})
  },

  // The window losing focus ends a gesture; to an app's frame that is not
  // the active one, it raises that app, since a press inside a frame is
  // never heard on the page.
  _windowBlur() {
    this._windowCancel()
    setTimeout(() => {
      const focused = globalThis.document?.activeElement
      if (!focused || focused.tagName !== "IFRAME" || typeof focused.closest !== "function") return
      const wrapper = focused.closest("[data-canvas-frame]")
      if (!wrapper || !["window", "tile"].includes(wrapper.dataset.canvasPlace)) return
      if (wrapper.dataset.canvasActive === "true" || !this._connected) return
      this.pushEvent("frame_raise", {frame: wrapper.dataset.canvasFrame})
    }, 0)
  },

  // The gesture of `pointerId` (any, when null) taken off: its shield, its
  // capture and its window listener go with it.
  _end(pointerId) {
    const g = this._gesture
    if (!g || (pointerId !== null && pointerId !== g.id)) return null
    this._gesture = null
    this._shield(null)
    globalThis.window?.removeEventListener("pointerup", this._onWindowUp)
    if (g.capture?.hasPointerCapture?.(g.id)) g.capture.releasePointerCapture(g.id)
    return g
  },

  // Where the gesture puts what it moves at `event` (none: where it began),
  // and the snap a drag offers.
  _shaped(g, event) {
    const dx = event ? event.clientX - g.x : 0
    const dy = event ? event.clientY - g.y : 0
    const wrapperId = g.wrapper.id

    if (g.kind === "divider") {
      const width = dividerWidth(g.start.width, g.side, dx, g.area)
      const x = g.side === "left" ? g.start.x : g.start.x + g.start.width - width
      const box = {x, y: g.start.y, width, height: g.start.height}
      const held = [{id: wrapperId, box: {left: box.x, width: box.width}}]
      if (g.canvas) {
        const grow = width - g.start.width
        const canvas =
          g.side === "left"
            ? {left: g.canvas.box.x + grow, width: g.canvas.box.width - grow}
            : {left: g.canvas.box.x, width: g.canvas.box.width - grow}
        held.push({id: g.canvas.id, box: canvas})
      }
      return {box, held, snap: null}
    }

    const box = g.kind === "drag" ? moved(g.start, dx, dy, g.area) : resized(g.start, g.edge, dx, dy, g.area)
    const point = event ? {x: event.clientX - g.area.left, y: event.clientY - g.area.top} : null
    const snap = g.kind === "drag" && event ? snapAt(point, g.area) : null
    this._preview(snap ? snapBox(snap, tileShare(g.wrapper), g.area) : null)
    return {box, snap, held: [{id: wrapperId, box: {left: box.x, top: box.y, width: box.width, height: box.height}}]}
  },

  // Hold what gesture `g` shaped over the server's style, as `g`'s, until
  // released.
  _hold(g, {held}) {
    for (const {id, box} of held) this._held.set(id, {gesture: g.token, box})
    this._writeHeld()
  },

  // Release what gesture `g` still holds; what a newer gesture took over
  // stays held.
  _release(g) {
    for (const [id, {gesture}] of this._held) if (gesture === g.token) this._held.delete(id)
    this._writeHeld()
  },

  _writeHeld() {
    const style = this._stylesheet()
    if (style) style.textContent = overrides(Array.from(this._held, ([id, {box}]) => ({id, box})))
  },

  // The apps' area: the frames container's box in the page.
  _area() {
    const container = this._layer.querySelector(`#${this._layer.id}-frames`)
    if (!container || typeof container.getBoundingClientRect !== "function") return null
    const {left, top, width, height} = container.getBoundingClientRect()
    return [left, top, width, height].every(Number.isFinite) ? {left, top, width, height} : null
  },

  _canvasBox(area) {
    const canvas = this._layer.querySelector('[data-canvas-place="canvas"][data-canvas-shown="true"]')
    return canvas ? {id: canvas.id, box: relative(canvas, area)} : null
  },

  // The shield over every frame while a gesture runs, carrying the
  // gesture's kind for its cursor; null takes it down.
  _shield(kind) {
    const shield = this._shieldElement()
    if (!shield) return
    shield.hidden = kind === null
    if (kind === null) {
      delete shield.dataset.gesture
      this._preview(null)
    } else {
      shield.dataset.gesture = kind === "resize" ? `resize-${this._gesture?.edge}` : kind
    }
  },

  _preview(box) {
    this._shieldElement()
    const preview = this._previewEl
    if (!preview) return
    preview.hidden = box === null
    if (box && preview.style) {
      const area = this._gesture?.area
      preview.style.left = `${(area?.left ?? 0) + box.x}px`
      preview.style.top = `${(area?.top ?? 0) + box.y}px`
      preview.style.width = `${box.width}px`
      preview.style.height = `${box.height}px`
    }
  },

  _shieldElement() {
    if (this._shieldEl && this._shieldEl.isConnected !== false) return this._shieldEl
    const host = this._layer.querySelector(`#${this._layer.id}-geometry`)
    const doc = this._layer.ownerDocument
    if (!host || !doc || typeof doc.createElement !== "function") return null
    const shield = doc.createElement("div")
    shield.className = "canvas-shield"
    shield.hidden = true
    const preview = doc.createElement("div")
    preview.className = "canvas-snap-preview"
    preview.hidden = true
    shield.appendChild(preview)
    host.appendChild(shield)
    this._shieldEl = shield
    this._previewEl = preview
    return shield
  }
}

// A box's place in `area`, from its element's box in the page.
function relative(element, area) {
  const {left, top, width, height} = element.getBoundingClientRect()
  return {x: left - area.left, y: top - area.top, width, height}
}

// The share an app takes as a tile: the one the server rendered for a
// window, a tile's own, or the default.
function tileShare(wrapper) {
  const share = Number.parseInt(wrapper.dataset.canvasTileShare ?? wrapper.dataset.canvasShare ?? "", 10)
  return Number.isInteger(share) && share >= 1 && share <= 10000 ? share : DEFAULT_SHARE
}
