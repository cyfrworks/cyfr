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
// A gesture that does not settle (cancelled, its capture lost, the window
// losing focus or hidden, the socket gone) ends there: the shield goes and
// the panel stands where the last settled gesture left it. A release
// anywhere, outside the window included, settles it. In the hand it is a
// sheet whose handle (`data-aqua-handle`) pulls it to full height or down
// to close. Escape from inside closes it and gives focus back to its
// button.
//
// The thread's menu (`#aqua-panel-pane-menu`, the thread pane's, opened by
// the header's `data-aqua-menu-toggle`) is an element of the panel, under
// the command palette like the rest of it. The hook shows and hides it:
// the toggle, a press outside it, Escape inside it, the window losing
// focus and the palette opening close it; the panel closing removes it.
//
// `AquaPanelKeys`, on the panel's root, which is drawn open or closed,
// sends `toggle` on Ctrl+J while no modal prompt is open.

import {area, dockResized, moved, opened, parseKept, postureFor, pulled, resized, settled, shown, sheet} from "./geometry.js"

const TOP_BAR = "topbar"
const BUTTON = "aqua-panel-button"
const PALETTE = "command-palette"

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
    this.onLost = (event) => this.cancel(event)
    this.onClick = (event) => this.click(event)
    this.onOutside = (event) => {
      if (!this.menuOpen() || !event.target || !event.target.closest) return
      if (!event.target.closest("#aqua-panel-pane-menu, [data-aqua-menu-toggle]")) this.closeMenu()
    }

    // Escape from anywhere inside, the thread's own view included, whose
    // keys no binding of the panel's view hears.
    this.onKey = (event) => {
      if (event.key !== "Escape" || event.defaultPrevented || event.isComposing) return
      event.preventDefault()
      // An open menu takes the Escape alone.
      if (this.menuOpen()) {
        this.closeMenu()
        return focusIn(this.el, "[data-aqua-menu-toggle]")
      }
      focusButton()
      this.pushEvent("close", {})
    }

    // The window losing focus, to a frame (whose presses the page never
    // hears) or to another window, ends a gesture and closes the menu; so
    // does the page being hidden.
    this.onBlur = () => this.interrupt()
    this.onVisibility = () => {
      if (document.visibilityState === "hidden") this.interrupt()
    }

    window.addEventListener("resize", this.onResize)
    window.addEventListener("blur", this.onBlur)
    window.addEventListener("pointerdown", this.onOutside, true)
    if (typeof document !== "undefined") document.addEventListener("visibilitychange", this.onVisibility)
    this.el.addEventListener("keydown", this.onKey)
    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerup", this.onUp)
    this.el.addEventListener("pointercancel", this.onLost)
    this.el.addEventListener("lostpointercapture", this.onLost)
    this.el.addEventListener("click", this.onClick)
    this.watchPalette()
  },

  // The server patched the panel: its docked state may have changed.
  updated() {
    this.draw()
  },

  // The socket dropped: a gesture under way cannot be sent, so it ends.
  disconnected() {
    this.cancel()
  },

  destroyed() {
    this.cancel()
    window.removeEventListener("resize", this.onResize)
    window.removeEventListener("blur", this.onBlur)
    window.removeEventListener("pointerdown", this.onOutside, true)
    if (typeof document !== "undefined") document.removeEventListener("visibilitychange", this.onVisibility)
    if (this.palette) this.palette.disconnect()
  },

  interrupt() {
    this.cancel()
    this.closeMenu()
  },

  click(event) {
    const target = event.target
    if (!target || !target.closest) return
    if (target.closest("[data-aqua-menu-toggle]")) return this.menuOpen() ? this.closeMenu() : this.openMenu()
    if (!target.closest("[data-aqua-handle]")) return
    if (this.pulledLast) return (this.pulledLast = false)
    this.level = this.level === "full" ? "rest" : "full"
    this.draw()
  },

  menu() {
    return typeof this.el.querySelector === "function" ? this.el.querySelector("#aqua-panel-pane-menu") : null
  },

  menuOpen() {
    const menu = this.menu()
    return menu !== null && !menu.hidden
  },

  openMenu() {
    const menu = this.menu()
    if (!menu) return
    menu.hidden = false
    this.markToggle(true)
  },

  closeMenu() {
    const menu = this.menu()
    if (!menu || menu.hidden) return
    menu.hidden = true
    this.markToggle(false)
  },

  markToggle(open) {
    const toggle = this.el.querySelector("[data-aqua-menu-toggle]")
    if (toggle) toggle.setAttribute("aria-expanded", String(open))
  },

  // The command palette opening closes the menu, which it covers.
  watchPalette() {
    if (typeof document === "undefined" || typeof MutationObserver === "undefined") return
    const palette = document.getElementById(PALETTE)
    if (!palette) return
    this.palette = new MutationObserver(() => {
      if (palette.dataset.open === "true") this.closeMenu()
    })
    this.palette.observe(palette, {attributes: true, attributeFilter: ["data-open"]})
  },

  space() {
    const bar = typeof document !== "undefined" && document.getElementById(TOP_BAR)
    const top = bar ? bar.getBoundingClientRect().bottom : 0
    return area(window.innerWidth, window.innerHeight, top)
  },

  posture() {
    return postureFor(window.innerWidth)
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
    this.gesture = {kind, edge: edge && edge.dataset.aquaEdge, x: event.clientX, y: event.clientY, from, before: this.rect, space, id: event.pointerId}
    this.el.setPointerCapture(event.pointerId)
    // A release outside the panel, or outside the window, still settles it.
    window.addEventListener("pointerup", this.onUp)
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
    const g = this.end(event.pointerId)
    if (!g) return
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

    this.rect = this.reshaped(g, dx, dy)
    this.draw()
    if (!same(this.rect, g.from)) this.pushEvent("place", this.rect)
  },

  // A gesture that does not settle: the panel goes back to where the last
  // settled one left it, and nothing is sent. With an event, only its own
  // pointer's.
  cancel(event = null) {
    const g = this.end(event ? event.pointerId : null)
    if (!g) return
    if (g.kind !== "pull") this.rect = g.before
    this.draw()
  },

  // The gesture of `pointerId` (any, when null) taken off: its shield, its
  // capture and its window listener go with it.
  end(pointerId) {
    const g = this.gesture
    if (!g || (pointerId !== null && pointerId !== g.id)) return null
    this.gesture = null
    delete this.el.dataset.aquaMoving
    window.removeEventListener("pointerup", this.onUp)
    if (typeof this.el.hasPointerCapture === "function" && this.el.hasPointerCapture(g.id)) {
      this.el.releasePointerCapture(g.id)
    }
    return g
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

function focusIn(root, selector) {
  const el = typeof root.querySelector === "function" && root.querySelector(selector)
  if (el && typeof el.focus === "function") el.focus()
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
