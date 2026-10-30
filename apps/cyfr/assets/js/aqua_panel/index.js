// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The AQUA panel's hooks (PrismWeb.AquaPanelLive). The placement math is
// geometry.js's; these only wire the pointer, the keyboard and the window
// to it and draw the result.
//
// `AquaPanel`, on the panel (`#aqua-panel-sheet`), mounts each time the
// panel opens. It reads the kept placement the server renders (`data-x`,
// `data-y`, `data-w`, `data-h`) and the docked state (`data-docked`),
// brings the placement inside the viewport and draws it through four CSS
// properties on the panel's own style (`--aqua-x`, `--aqua-y`, `--aqua-w`,
// `--aqua-h`), which aqua_panel.css places it by; the server leaves that
// attribute to the hook. On the desk the header drags it and the edges
// (`data-aqua-edge`) resize it, under pointer capture and behind a shield
// over the whole viewport (`data-aqua-moving` shows it), so no frame under
// the pointer takes the gesture; each settled gesture is sent as `place`.
// In the hand it is a sheet whose handle (`data-aqua-handle`) pulls it to
// full height or down to close. Escape from inside closes it and gives
// focus back to its button.
//
// `AquaPanelKeys`, on the panel's root, which is drawn open or closed,
// sends `toggle` on Ctrl+J while no modal prompt is open.

import {area, dockResized, moved, opened, parseKept, postureFor, pulled, resized, settled, shown, sheet} from "./geometry.js"

const TOP_BAR = "topbar"
const BUTTON = "aqua-panel-button"

// What a header press leaves alone: its own controls.
const CONTROL = "button, select, input, textarea, a, [data-aqua-edge]"

// A pointer that travels less than this is a click, not a pull.
const PULL_MIN_PX = 4

export const AquaPanel = {
  mounted() {
    this.level = "rest"
    this.gesture = null
    this.rect = opened(parseKept(this.el.dataset), buttonBox(), this.space())
    this.draw()

    this.onResize = () => this.draw()
    this.onDown = (event) => this.down(event)
    this.onMove = (event) => this.move(event)
    this.onUp = (event) => this.up(event)
    this.onHandleClick = (event) => {
      if (!event.target.closest || !event.target.closest("[data-aqua-handle]")) return
      if (this.pulledLast) return (this.pulledLast = false)
      this.level = this.level === "full" ? "rest" : "full"
      this.draw()
    }

    // Escape from anywhere inside, the thread's own view included, whose
    // keys no binding of the panel's view hears.
    this.onKey = (event) => {
      if (event.key !== "Escape" || event.defaultPrevented || event.isComposing) return
      // An open menu of the panel's takes its own Escape.
      if (this.menuOpen()) return
      event.preventDefault()
      focusButton()
      this.pushEvent("close", {})
    }

    // A press inside a frame is outside the page's sight, so the browser's
    // own dismissal of the thread's menu never hears it; the page losing
    // focus to the frame closes the menu instead.
    this.onBlur = () => {
      const menu = this.openMenu()
      if (menu && typeof menu.hidePopover === "function") menu.hidePopover()
    }

    window.addEventListener("resize", this.onResize)
    window.addEventListener("blur", this.onBlur)
    this.el.addEventListener("keydown", this.onKey)
    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerup", this.onUp)
    this.el.addEventListener("pointercancel", this.onUp)
    this.el.addEventListener("click", this.onHandleClick)
  },

  // The server patched the panel: its docked state may have changed.
  updated() {
    this.draw()
  },

  destroyed() {
    window.removeEventListener("resize", this.onResize)
    window.removeEventListener("blur", this.onBlur)
  },

  space() {
    const bar = typeof document !== "undefined" && document.getElementById(TOP_BAR)
    const top = bar ? bar.getBoundingClientRect().bottom : 0
    return area(window.innerWidth, window.innerHeight, top)
  },

  posture() {
    return postureFor(window.innerWidth)
  },

  openMenu() {
    return typeof this.el.querySelector === "function" ? this.el.querySelector(":popover-open") : null
  },

  menuOpen() {
    return this.openMenu() !== null
  },

  isDocked() {
    return this.el.dataset.docked === "true"
  },

  draw(rect = null) {
    const box = rect ?? shown({rect: this.rect, docked: this.isDocked(), level: this.level}, this.posture(), this.space())
    this.el.style.setProperty("--aqua-x", `${box.x}px`)
    this.el.style.setProperty("--aqua-y", `${box.y}px`)
    this.el.style.setProperty("--aqua-w", `${box.w}px`)
    this.el.style.setProperty("--aqua-h", `${box.h}px`)
  },

  down(event) {
    if (event.button !== 0 || this.gesture) return
    this.pulledLast = false
    const target = event.target
    if (!target.closest) return
    const hand = this.posture() === "hand"
    const edge = target.closest("[data-aqua-edge]")
    const handle = target.closest("[data-aqua-handle]")
    const grip = target.closest("[data-aqua-grip]")
    const space = this.space()
    let kind = null

    if (hand) {
      if (handle) kind = "pull"
    } else if (edge) {
      const which = edge.dataset.aquaEdge
      // Docked, the panel sizes from its left edge alone.
      if (!this.isDocked() || which === "w") kind = "resize"
    } else if (grip && !this.isDocked() && !target.closest(CONTROL)) {
      kind = "drag"
    }
    if (!kind) return

    event.preventDefault()
    const from = this.isDocked() ? this.rect : shown({rect: this.rect, docked: false, level: this.level}, "desk", space)
    this.gesture = {kind, edge: edge && edge.dataset.aquaEdge, x: event.clientX, y: event.clientY, from, space, id: event.pointerId}
    this.el.setPointerCapture(event.pointerId)
    // The shield the stylesheet shows for this value covers every frame,
    // so the pointer's travel stays with the panel.
    this.el.dataset.aquaMoving = kind === "resize" ? `resize-${this.gesture.edge}` : kind
  },

  move(event) {
    const g = this.gesture
    if (!g || event.pointerId !== g.id) return
    const dx = event.clientX - g.x
    const dy = event.clientY - g.y

    if (g.kind === "pull") return this.draw(pulled(this.level, dy, g.space))
    this.rect = this.reshaped(g, dx, dy)
    this.draw()
  },

  up(event) {
    const g = this.gesture
    if (!g || event.pointerId !== g.id) return
    this.gesture = null
    delete this.el.dataset.aquaMoving
    if (this.el.hasPointerCapture && this.el.hasPointerCapture(g.id)) this.el.releasePointerCapture(g.id)
    const dx = event.clientX - g.x
    const dy = event.clientY - g.y

    if (g.kind === "pull") {
      if (Math.abs(dy) < PULL_MIN_PX) return this.draw()
      this.pulledLast = true
      const level = settled(this.level, dy, g.space)
      if (level === "closed") {
        this.draw(sheet("rest", g.space))
        return this.pushEvent("close", {})
      }
      this.level = level
      return this.draw()
    }

    if (event.type === "pointerup") this.rect = this.reshaped(g, dx, dy)
    else this.rect = g.from
    this.draw()
    if (!same(this.rect, g.from)) this.pushEvent("place", this.rect)
  },

  reshaped(g, dx, dy) {
    if (g.kind === "drag") return moved(g.from, dx, dy, g.space)
    if (this.isDocked()) return dockResized(g.from, dx, g.space)
    return resized(g.from, g.edge, dx, dy, g.space)
  }
}

export const AquaPanelKeys = {
  mounted() {
    this.onKey = (event) => {
      if (!isToggle(event) || modalOpen()) return
      event.preventDefault()
      const sheet = this.el.querySelector("#aqua-panel-sheet")
      // Closing from inside the panel gives focus back to its button, as
      // Escape does; a close from the page leaves focus where it was.
      if (sheet && sheet.contains(document.activeElement)) focusButton()
      this.pushEvent("toggle", {})
    }
    window.addEventListener("keydown", this.onKey)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKey)
  }
}

// Ctrl+J and nothing else held, on every platform.
export function isToggle(event) {
  return (
    event.ctrlKey && !event.altKey && !event.shiftKey && !event.metaKey && typeof event.key === "string" && event.key.toLowerCase() === "j"
  )
}

function modalOpen() {
  return typeof document !== "undefined" && document.querySelector("dialog:modal") !== null
}

function focusButton() {
  const button = typeof document !== "undefined" && document.getElementById(BUTTON)
  if (button) button.focus()
}

function buttonBox() {
  const button = typeof document !== "undefined" && document.getElementById(BUTTON)
  return button ? button.getBoundingClientRect() : null
}

function same(a, b) {
  return a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h
}
