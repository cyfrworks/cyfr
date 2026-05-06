// Optimistic active-class swap + main-panel spinner for sidebar nav links.
//
// On click, immediately move the active CSS classes to the clicked link
// before the server round-trip completes, and replace #page-content with a
// centered spinner so the main panel shows visible progress (the previous
// page would otherwise sit there until the new LiveView mounts).
//
// LiveView's diff reconciles the class swap invisibly because the server's
// eventual class string matches what we applied (both read from
// data-active-class / data-inactive-class on the element). Morphdom matches
// #page-content by id and patches its children, so the new server-rendered
// LiveView content replaces the spinner as soon as it arrives.
//
// We listen on the capture phase so the handler runs before LiveView's own
// click handler kicks off the navigation. We do NOT preventDefault —
// <.link navigate> proceeds normally.

const SPINNER_HTML = `
  <div data-optimistic-spinner class="flex h-full items-center justify-center gap-2 py-8 text-sm text-gray-500">
    <span class="inline-block h-4 w-4 animate-spin rounded-full border-2 border-gray-600 border-t-blue-400" aria-hidden="true"></span>
    <span>Loading…</span>
  </div>
`

const OptimisticNav = {
  mounted() {
    this._onClick = (event) => {
      const group = this.el.dataset.navGroup
      if (!group) return

      const siblings = document.querySelectorAll(`[data-nav-group="${group}"]`)
      siblings.forEach((el) => {
        if (el === this.el) return
        applyClasses(el, false)
      })
      applyClasses(this.el, true)

      // Skip the spinner if the user clicked the link they're already on —
      // Phoenix re-mounts the LiveView even on same-URL navigates, but a
      // 50–100ms flash of empty state is worse UX than no transition.
      let targetPath = null
      try {
        targetPath = new URL(this.el.href).pathname
      } catch (_e) {
        return
      }
      if (targetPath === window.location.pathname) return

      // Modifier-clicks open in a new tab/window, so the current page stays
      // put — don't blank it.
      if (event && (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button === 1)) return

      const pageContent = document.getElementById("page-content")
      if (!pageContent) return

      pageContent.innerHTML = SPINNER_HTML

      // Failsafe: if navigation fails (network error, server error) the
      // morphdom patch never lands, so the spinner would stay forever.
      // page-loading-stop fires in both success and failure paths; on
      // success the spinner is already gone, so the cleanup is a no-op.
      window.addEventListener(
        "phx:page-loading-stop",
        () => {
          const stuck = pageContent.querySelector("[data-optimistic-spinner]")
          if (stuck) stuck.remove()
        },
        { once: true }
      )
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
