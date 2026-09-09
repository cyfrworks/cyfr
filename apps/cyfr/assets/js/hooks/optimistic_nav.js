// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Update sidebar active classes immediately on click. LiveView reconciles
// them from the same data-active-class and data-inactive-class attributes.
// PageLoadingIndicator handles loading feedback.
//
// Capture clicks before LiveView starts navigation, without preventing it.

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
