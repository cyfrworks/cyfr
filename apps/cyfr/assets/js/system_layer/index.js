// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {nextStop, tabOrder} from "./focus.js"
import {initial, transition} from "./state.js"

/**
 * SystemLayer hook — the browser half of the layer Prism alone draws above
 * every frame (`PrismWeb.SystemLayer`). Registered as `Hooks.SystemLayer`
 * on the component's root, which carries `data-open` and `data-prompt-id`;
 * the prompt is the `<dialog>` inside it.
 *
 * A prompt is shown modal in the browser's top layer (`showModal()`) only
 * after the document has been asked to leave pointer lock and its
 * fullscreen exit has settled, so no frame's fullscreen covers it. While
 * it shows, a frame that takes fullscreen or pointer lock again is made to
 * leave them and the prompt is shown above it again. Focus moves into the
 * prompt and returns to where it was when the prompt closes; Tab and
 * Shift+Tab wrap inside it. Escape dismisses every prompt; only the server
 * closes a prompt.
 *
 * While a modal prompt is open, from the step that leaves fullscreen until
 * it closes, every frame on the page is hidden (`visibility: hidden`, by a
 * stylesheet the layer owns) and `inert`, a frame added meanwhile too: it
 * cannot draw over the prompt, take its input or act on it. On a page that
 * is not fullscreen the frames are hidden at once; on one that is, once the
 * exit has settled and the frames have had a moment to see it
 * (`framesSee`), and only then is the prompt shown: a frame hidden before
 * it saw the exit keeps its fullscreen and takes it back, with no gesture,
 * as soon as it is shown again. A page may hold two layers (the page's and
 * the person's own panel's); the frames stay hidden while either has a
 * modal prompt open. When the last one closes the stylesheet goes, and
 * each frame keeps the `inert` its server and its bridge last gave it: the
 * layer removes only the `inert` it added and nobody wrote since.
 *
 * A frame's pointer lock is its own: no document can release a lock
 * another frame holds. Hiding a frame ends the lock in Chromium, but a
 * frame still holding its person's activation can take it again while
 * hidden. Escape always ends it, and focus stays in the prompt.
 *
 * The show and hide decisions are `state.js`'s and the tab order is
 * `focus.js`'s; this hook only performs their effects.
 *
 * A key's ceremony is never this page's: a passkey of the person's account
 * lives at the account pages of its directory. The same hook holds the hop
 * there and the return:
 *
 *   * The hop. A page asks the browser to go to the account pages with this
 *     CYFR's request in the fragment (`account:hop`, `{url}`), which an
 *     element with `data-account` takes: the browser goes there. The
 *     layer's own confirmation opens them in a new tab instead
 *     (`system_layer:hop`, `{layer, url}`), so the page that asked keeps
 *     its waiting change and repeats it once the record is confirmed.
 *   * The return. The account pages send the browser back to the sign-in
 *     page with the answer in the fragment, which no server receives. An
 *     element with `data-account="return"` reads it on mount, removes it
 *     from the address (`history.replaceState`) and hands it to its page
 *     (`account_answer`, `{answer}`), once.
 *   * The setup and invitation pages, an element with `data-account`
 *     `"setup"` or `"invite"`, hand their page the setup token or the
 *     invitation code the address carries in its fragment
 *     (`account_token`, `{token}`), on mount and on every reconnect, since a
 *     new page process holds none.
 *
 * A change that waits on a fresh confirmation repeats once its record is
 * confirmed. A typed value is never held by the server meanwhile: the
 * form keeps it, and the server asks the browser to submit that form
 * again (`system_layer:resubmit`, `{layer, form}`, the form's id). Every
 * form in a prompt is cleared when the prompt closes. A page's own form
 * that typed a credential, outside the prompt, is marked with the prompt
 * it asks under (`system_layer:mark`, `{layer, form, prompt}`), the mark
 * held here by form id, and every form so marked is cleared when that
 * prompt ends (`system_layer:clear`, `{layer, prompt, form}`) or when the
 * page reconnects,
 * since its waiting requests ended with the old page process. Keys typed
 * into a prompt stay in it: none drives the page behind it.
 */

const FOCUSABLE = "a[href], button, input, select, textarea, [tabindex]"

// ---------------------------------------------------------------------------
// The frames, hidden while any layer on the page has a modal prompt open
// ---------------------------------------------------------------------------

// Every layer of the page with a modal prompt open; shared by every layer's
// hook. While one does, a stylesheet the layer owns hides every frame, and
// each frame is `inert`. A frame's own `inert` belongs to the server's
// render and to the frame's bridge (`hooks/iframe_bridge.js`, which makes a
// frozen frame inert), so the layer adds the attribute only where it is
// absent, and gives back only what it added: a write of `inert` by anyone
// else while the page is covered is the frame's latest state, kept as its
// state when the last layer closes.
const covering = new Set()
const added = new Set()
let coverStyle = null
let frameWatch = null

// Whether a layer in `state` covers the page: a prompt opening or shown.
export const covers = (state) => state.phase !== "hidden"

// How long after the page left fullscreen its frames are given to see it,
// beyond two of the page's animation frames: each sees it at its own next
// rendering.
export const FRAMES_SEE_MS = 100

/** Resolves once the page's frames have had their moment to see a fullscreen exit. */
export function framesSee(wait = FRAMES_SEE_MS) {
  const raf = globalThis.requestAnimationFrame
  const twice = typeof raf === "function" ? new Promise((resolve) => raf(() => raf(resolve))) : Promise.resolve()
  return twice.then(() => new Promise((resolve) => setTimeout(resolve, wait)))
}

/**
 * `layer` (a hook) covers the page, or no longer does. The first to cover
 * hides every frame and makes it inert, and watches the page for frames
 * added and for anyone else's writes of a frame's `inert`; the last to stop
 * removes the stylesheet and the `inert` it added and nobody has written
 * since.
 */
export function cover(layer, on, doc = globalThis.document) {
  if (on) {
    const first = covering.size === 0
    covering.add(layer)
    if (first && doc && typeof doc.querySelectorAll === "function") {
      hideFrames(doc)
      for (const frame of doc.querySelectorAll("iframe")) inertFrame(frame)
      watchFrames(doc)
    }
  } else if (covering.delete(layer) && covering.size === 0) {
    if (frameWatch) frameWatch.disconnect()
    frameWatch = null
    if (coverStyle && typeof coverStyle.remove === "function") coverStyle.remove()
    coverStyle = null
    for (const frame of added) frame.removeAttribute("inert")
    added.clear()
  }
}

// The layer's own stylesheet, outside every frame and every dialog: no
// render of the server's touches it, and removing it gives each frame back
// whatever visibility its own attributes say.
function hideFrames(doc) {
  if (typeof doc.createElement !== "function") return
  const parent = doc.head || doc.documentElement
  if (!parent) return
  coverStyle = doc.createElement("style")
  coverStyle.setAttribute("data-system-layer-cover", "")
  coverStyle.textContent = "iframe { visibility: hidden !important; }"
  parent.appendChild(coverStyle)
}

function inertFrame(frame) {
  if (frame.hasAttribute("inert")) return
  frame.setAttribute("inert", "")
  added.add(frame)
}

// A frame added while the page is covered is made inert as it arrives; a
// write of a frame's `inert` by anyone else is its latest state: inert, it
// is the writer's to keep; not, the layer makes it inert again and gives
// that back when the page is uncovered. The layer's own writes are taken
// off the queue as it makes them.
function watchFrames(doc) {
  const Observer = globalThis.MutationObserver
  if (!Observer || !doc.body) return
  frameWatch = new Observer((records) => {
    for (const record of records) {
      if (record.type === "attributes") {
        const frame = record.target
        if (!frame || frame.nodeName !== "IFRAME") continue
        if (frame.hasAttribute("inert")) added.delete(frame)
        else inertFrame(frame)
      } else {
        for (const node of record.addedNodes || []) {
          if (node.nodeName === "IFRAME") inertFrame(node)
          else if (node.querySelectorAll) for (const frame of node.querySelectorAll("iframe")) inertFrame(frame)
        }
      }
    }
    if (frameWatch) frameWatch.takeRecords()
  })
  frameWatch.observe(doc.body, {childList: true, subtree: true, attributes: true, attributeFilter: ["inert"]})
}

// The records a layer of this document holds, by public ref, with that
// layer's id: the desktop's layer tells each one (`system_layer:held`), and
// every other layer of the document, one mounted later included, is handed
// it (`held_elsewhere`) and leaves it to that layer, so no record is drawn
// twice. The document's, so it outlives a move between pages.
export const heldInDocument = new Map()

export function tellHeld(hook, layer, ref) {
  if (typeof ref !== "string" || typeof layer !== "string") return
  heldInDocument.set(ref, layer)
  if (layer !== hook.el.id) hook.pushEventTo(hook.el, "held_elsewhere", {ref})
}

export default {
  mounted() {
    if (this.el.dataset.account) return this.mountAccount(this.el.dataset.account)

    this.handleLayerEvents()
    this.onHeld = (event) => {
      const {layer, ref} = (event && event.detail) || {}
      tellHeld(this, layer, ref)
    }
    if (typeof globalThis.addEventListener === "function")
      globalThis.addEventListener("phx:system_layer:held", this.onHeld)
    for (const [ref, layer] of heldInDocument) {
      if (layer !== this.el.id) this.pushEventTo(this.el, "held_elsewhere", {ref})
    }
    this.gone = false
    this.layer = initial
    this.returnFocus = null
    this.dialog = this.el.querySelector("dialog")

    this.onCancel = (event) => {
      event.preventDefault()
      this.dispatch({type: "cancel"})
    }
    this.onClose = () => this.dispatch({type: "closed"})
    this.onKeydown = (event) => {
      if (event.key === "Tab") this.trap(event)
      // A key typed into a prompt is the prompt's alone.
      if (event.stopPropagation) event.stopPropagation()
    }
    this.onEscalated = () => {
      const doc = globalThis.document
      if (doc.fullscreenElement || doc.pointerLockElement) this.dispatch({type: "escalated"})
    }

    this.dialog.addEventListener("cancel", this.onCancel)
    this.dialog.addEventListener("close", this.onClose)
    this.dialog.addEventListener("keydown", this.onKeydown)
    globalThis.document.addEventListener("fullscreenchange", this.onEscalated)
    globalThis.document.addEventListener("pointerlockchange", this.onEscalated)

    this.sync()
  },

  updated() {
    if (this.el.dataset.account) return
    this.dialog = this.el.querySelector("dialog")
    this.sync()
  },

  destroyed() {
    if (this.el.dataset.account) return

    // A layer that goes covers nothing and does nothing more: its state
    // machine ends, and a fullscreen exit still settling finds it gone.
    this.gone = true
    this.layer = {...initial, attempt: this.layer ? this.layer.attempt + 1 : 0}
    this.cover(false)
    this.dialog.removeEventListener("cancel", this.onCancel)
    this.dialog.removeEventListener("close", this.onClose)
    this.dialog.removeEventListener("keydown", this.onKeydown)
    globalThis.document.removeEventListener("fullscreenchange", this.onEscalated)
    globalThis.document.removeEventListener("pointerlockchange", this.onEscalated)
    if (this.onHeld && typeof globalThis.removeEventListener === "function")
      globalThis.removeEventListener("phx:system_layer:held", this.onHeld)
  },

  // An element of the account pages' hop and return: the browser sent there
  // when its page asks, and the fragment the address carries handed over.
  mountAccount(mode) {
    if (typeof this.handleEvent === "function")
      this.handleEvent("account:hop", ({url}) => hop(globalThis.location, url))
    if (mode === "return") return this.pushAnswer()
    this.pushToken()
  },

  // The answer the account pages returned, taken from the address once and
  // handed to the page.
  pushAnswer() {
    const answer = takeFragment(globalThis.location, globalThis.history, globalThis.document)
    if (answer) this.pushEvent("account_answer", {answer})
  },

  // The setup token or the invitation code the address carries.
  pushToken() {
    const hash = globalThis.location ? globalThis.location.hash : ""
    this.pushEvent("account_token", {token: hash.startsWith("#") ? hash.slice(1) : hash})
  },

  // What the system layer asks of the browser; the layer decides nothing
  // from it, the CYFR does. Every hook on a page hears every push, and a
  // page may hold two layers (the page's and the panel's), so each event
  // names the layer it is for (`layer`, the layer's id) and only that
  // layer's hook acts on it: a form is submitted again once.
  handleLayerEvents() {
    if (typeof this.handleEvent !== "function") return
    this.marks = new Map()

    const on = (event, act) => this.handleEvent(event, (payload) => {
      if (payload && payload.layer === this.el.id) act(payload)
    })

    // A confirmation's key ceremony, at the account pages in a new tab.
    on("system_layer:hop", ({url}) => openTab(globalThis, url))

    // A change confirmed: the form that typed it, which still holds what
    // was typed, is submitted again.
    on("system_layer:resubmit", ({form}) => resubmit(globalThis.document, form))

    // A page's form marked with the prompt it asks under, and emptied when
    // that prompt ends.
    on("system_layer:mark", ({form, prompt}) => markForm(this.marks, form, prompt))
    on("system_layer:clear", ({prompt, form}) => clearMarked(globalThis.document, this.marks, prompt, form))
  },

  // A reconnect is a new page process: every request this page was waiting
  // on ended with the old one, so every form it typed for is emptied.
  reconnected() {
    // A setup or invitation page's new process holds no token: hand it
    // over again. A return's answer was taken once and is not.
    if (this.el && this.el.dataset.account) {
      if (this.el.dataset.account !== "return") this.pushToken()
      return
    }
    clearAllMarked(globalThis.document, this.marks)
  },

  sync() {
    this.dispatch({
      type: "sync",
      open: this.el.dataset.open === "true",
      promptId: this.el.dataset.promptId || null
    })
  },

  // A modal prompt hides the page's frames before it shows, and gives them
  // back only once its dialog has closed. On a page that is not fullscreen
  // they are hidden before anything else it does; on one that is, once the
  // exit has settled and the frames saw it (`exit-fullscreen`). Focus goes
  // back only after the frames do: a browser may refuse to focus a frame
  // that is still hidden and inert, and Firefox does.
  dispatch(event) {
    const {state, effects} = transition(this.layer, event)
    this.layer = state
    const on = covers(state)
    if (on && !globalThis.document.fullscreenElement) this.cover(true)

    for (const effect of effects) {
      if (effect === "restore-focus" && !on) this.cover(false)
      this.perform(effect)
    }

    if (!on) this.cover(false)
  },

  cover(on) {
    cover(this, on, globalThis.document)
  },

  perform(effect) {
    const doc = globalThis.document

    switch (effect) {
      case "remember-focus":
        this.returnFocus = doc.activeElement || null
        break

      case "exit-pointer-lock":
        if (doc.pointerLockElement && doc.exitPointerLock) doc.exitPointerLock()
        break

      case "exit-fullscreen": {
        const attempt = this.layer.attempt
        const wasFullscreen = Boolean(doc.fullscreenElement)
        const see = this.framesSee || framesSee
        // Settled after the layer went, it does nothing: a destroyed hook
        // never covers the page again.
        leaveFullscreen(doc)
          .then(() => (wasFullscreen && covers(this.layer) ? see() : undefined))
          .then(() => {
            if (this.gone) return
            if (covers(this.layer) && this.layer.attempt === attempt) this.cover(true)
            this.dispatch({type: "ready", attempt})
          })
        break
      }

      case "show":
        if (!this.dialog.open) this.dialog.showModal()
        break

      case "focus-first": {
        const [first] = this.stops()
        if (first) first.focus()
        break
      }

      case "close":
        clearForms(this.dialog)
        if (this.dialog.open) this.dialog.close()
        break

      case "restore-focus": {
        const target = this.returnFocus
        this.returnFocus = null
        if (target && target.isConnected !== false && target.focus) target.focus()
        break
      }

      case "push-dismiss":
        this.pushEventTo(this.el, "dismiss", {id: this.layer.promptId})
        break
    }
  },

  // The prompt's controls in the order Tab reaches them.
  stops() {
    const elements = Array.from(this.dialog.querySelectorAll(FOCUSABLE))
    const order = tabOrder(elements.map(describe))
    return order.map((position) => elements[position])
  },

  // A shown prompt holds focus.
  trap(event) {
    if (this.layer.phase !== "shown") return
    const stops = this.stops()
    const current = stops.indexOf(globalThis.document.activeElement)
    const next = nextStop(stops.length, current, event.shiftKey)
    event.preventDefault()
    if (next >= 0) stops[next].focus()
  }
}

// The browser sent to the account pages: only an https address, or an
// http one, as a directory on this machine's loopback is.
export function hop(location, url) {
  if (!location || !accountUrl(url)) return
  location.assign(url)
}

// The account pages opened in a new tab, which the page that asked keeps
// waiting beside: no reference to this page goes with it.
export function openTab(win, url) {
  if (!win || typeof win.open !== "function" || !accountUrl(url)) return
  win.open(url, "_blank", "noopener")
}

function accountUrl(url) {
  return typeof url === "string" && /^https?:\/\/[^/#?]+\/account\/(sign|new)#/.test(url)
}

// The address's fragment, taken once: removed from the address and the
// history entry so a reload or a shared link carries no answer.
export function takeFragment(location, history, doc) {
  const hash = location ? location.hash : ""
  const fragment = hash.startsWith("#") ? hash.slice(1) : hash
  if (!fragment) return ""
  if (history && typeof history.replaceState === "function") {
    const path = (location.pathname || "/") + (location.search || "")
    history.replaceState(history.state, (doc && doc.title) || "", path)
  }
  return fragment
}

// Submit the form `id` names again, as its own submit would.
export function resubmit(doc, id) {
  const form = doc && typeof doc.getElementById === "function" ? doc.getElementById(id) : null
  if (form && typeof form.requestSubmit === "function") form.requestSubmit()
}

// A page's form, marked with the prompt it asks under. The mark is held
// here, by form id, never on the form: LiveView's patch of an ignored
// element drops every data attribute its render lacks, so a mark on the
// form would not outlive the page's next render.
export function markForm(marks, id, prompt) {
  if (!marks || typeof id !== "string" || id === "" || typeof prompt !== "string") return
  const ids = marks.get(prompt) || new Set()
  ids.add(id)
  marks.set(prompt, ids)
}

// The forms `prompt` asked under, and the one its end names, emptied and
// unmarked.
export function clearMarked(doc, marks, prompt, form) {
  const ids = new Set(marks && marks.get(prompt))
  if (typeof form === "string" && form !== "") ids.add(form)
  if (marks) marks.delete(prompt)
  for (const id of ids) resetForm(doc, id)
}

// Every marked form emptied: their prompts ended with the page process.
export function clearAllMarked(doc, marks) {
  if (!marks) return
  for (const ids of marks.values()) for (const id of ids) resetForm(doc, id)
  marks.clear()
}

function resetForm(doc, id) {
  const form = doc && typeof doc.getElementById === "function" ? doc.getElementById(id) : null
  if (form && typeof form.reset === "function") form.reset()
}

// Every form in a prompt, emptied as the prompt closes.
export function clearForms(dialog) {
  const forms = dialog && typeof dialog.querySelectorAll === "function" ? dialog.querySelectorAll("form") : []
  for (const form of forms) if (typeof form.reset === "function") form.reset()
}

// A control as `focus.js` reads it.
function describe(element) {
  return {
    tabIndex: element.tabIndex,
    disabled: Boolean(element.disabled),
    hidden: element.type === "hidden" || Boolean(element.hidden)
  }
}

// Leave fullscreen and answer once the exit settled, or at once when the
// document is not fullscreen. A refused exit still settles: the prompt
// then shows in the top layer above the fullscreen element, which the
// escalation guard leaves again.
function leaveFullscreen(doc) {
  if (!doc.fullscreenElement) return Promise.resolve()

  try {
    const exit = doc.exitFullscreen ? doc.exitFullscreen() : doc.webkitExitFullscreen?.()
    return Promise.resolve(exit).catch(() => undefined)
  } catch (_error) {
    return Promise.resolve()
  }
}
