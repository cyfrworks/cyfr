// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Optimistic active-class swap for sidebar nav links.
//
// On click, immediately move the active CSS classes to the clicked link
// before the server round-trip completes. LiveView's diff reconciles the
// swap invisibly because the server's eventual class string matches what
// we applied (both read from data-active-class / data-inactive-class on
// the element).
//
// Loading feedback is deliberately NOT this hook's job. PageLoadingIndicator
// (mounted on #page-loading in the app layout) already listens for LiveView's
// phx:page-loading-start/stop and overlays the content area on every live
// navigation, sidebar clicks included. This hook used to also inject its own
// spinner into #page-content, so a slow sidebar navigation stacked two
// "Loading…" affordances; the spinner and its phx:page-loading-stop failsafe
// were removed so each transition has exactly one — the overlay, whose grace
// timer and guaranteed stop-event cleanup this hook couldn't match.
//
// We listen on the capture phase so the handler runs before LiveView's own
// click handler kicks off the navigation. We do NOT preventDefault —
// <.link navigate> proceeds normally.

const OptimisticNav = {
  mounted() {
    this._onClick = () => {
      const group = this.el.dataset.navGroup
      if (!group) return

      const siblings = document.querySelectorAll(`[data-nav-group="${group}"]`)
      siblings.forEach((el) => {
        if (el === this.el) return
        applyClasses(el, false)
      })
      applyClasses(this.el, true)
    }

    this.el.addEventListener("click", this._onClick, true)
  },

  destroyed() {
    if (this._onClick) {
      this.el.removeEventListener("click", this._onClick, true)
    }
  }
}

function applyClasses(el, active) {
  const activeTokens = (el.dataset.activeClass || "").split(/\s+/).filter(Boolean)
  const inactiveTokens = (el.dataset.inactiveClass || "").split(/\s+/).filter(Boolean)

  if (active) {
    inactiveTokens.forEach((t) => el.classList.remove(t))
    activeTokens.forEach((t) => el.classList.add(t))
  } else {
    activeTokens.forEach((t) => el.classList.remove(t))
    inactiveTokens.forEach((t) => el.classList.add(t))
  }
}

export default OptimisticNav
