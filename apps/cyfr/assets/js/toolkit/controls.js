// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A canvas's controls. When a tree is answered, each control binds to its one
// effect as things stand at that moment: an installed tincture, named by
// the shell's `installed`, or a feed's action, read from the binding record
// the streams worker made from that feed's latest event. The control keeps
// that binding until a new tree is answered, and its label is the
// declaration's (the tincture's name, the action's label in the binding),
// never anything the canvas wrote. An effect that does not resolve draws
// the control disabled, labelled with the toolkit's own word.
//
// A press is one genuine activation: a `click`, or a `keydown` of Enter or
// Space, whose event the browser marks trusted. Each event is consumed once
// and dispatched at once, inside its handler; nothing is held, queued,
// timed or retried.

export const UNAVAILABLE = "Unavailable"

const PRESS_KEYS = ["Enter", " ", "Spacebar"]

// The effect a control binds to: `{kind: "open", ref, label}`, `{kind:
// "press", binding, action, label}`, or null when it does not resolve.
// `installed` is the shell's `[{ref, name}]` and `records` the binding
// records by feed name, both as they stood when the tree was answered.
export function resolveEffect(effect, {installed, records}) {
  if (Object.prototype.hasOwnProperty.call(effect, "open")) {
    const entry = installed.find((tincture) => tincture.ref === effect.open)
    return entry ? {kind: "open", ref: entry.ref, label: entry.name} : null
  }

  const record = records.get(effect.press.feed)
  if (!record) return null
  const action = record.actions.find((one) => one.name === effect.press.action)
  return action ? {kind: "press", binding: record.binding, action: action.name, label: action.label} : null
}

// The controls of one host. `dispatch(resolved)` posts the effect to the
// shell, synchronously, and decides itself whether the canvas may act.
export function createControls({doc, dispatch}) {
  const consumed = new WeakSet()
  let drawn = []

  // A disabled control stays focusable, so it is found and read as
  // unavailable rather than skipped.
  function disable(control) {
    control.setAttribute("aria-disabled", "true")
  }

  return {
    // The element of a validated control node bound to `resolved`: a
    // focusable button whose accessible name is its label, the
    // declaration's or the toolkit's own word.
    element(node, resolved) {
      const label = resolved === null ? UNAVAILABLE : resolved.label
      const control = doc.createElement("div")
      control.setAttribute("class", `cyfr-control cyfr-tone-${node.tone} cyfr-size-${node.size}`)
      control.setAttribute("role", "button")
      control.setAttribute("tabindex", "0")
      control.setAttribute("aria-label", label)
      control.textContent = label

      if (resolved === null) {
        disable(control)
        return control
      }

      const press = (event) => {
        if (event.isTrusted !== true) return
        if (event.type === "keydown") {
          if (!PRESS_KEYS.includes(event.key) || event.repeat) return
          event.preventDefault()
        }
        if (consumed.has(event)) return
        consumed.add(event)
        if (control.getAttribute("aria-disabled") === "true") return
        dispatch(resolved)
      }

      control.addEventListener("click", press)
      control.addEventListener("keydown", press)
      drawn.push(control)
      return control
    },

    // A new tree replaces every control.
    reset() {
      drawn = []
    },

    // The canvas failed: its controls stay drawn, and none acts again.
    disableAll() {
      for (const control of drawn) disable(control)
    }
  }
}
