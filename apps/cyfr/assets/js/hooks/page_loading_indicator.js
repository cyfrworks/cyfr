// Centered "Loading…" overlay for live navigations.
//
// Listens for Phoenix's built-in phx:page-loading-start / phx:page-loading-stop
// window events and toggles `hidden` on its own element. A 120ms grace timer
// suppresses the overlay on fast loads — short enough to feel responsive on
// slow routes, long enough that a 30ms transition doesn't flash.
//
// The same events fire for human-driven <.link navigate> clicks AND for the
// data-phx-link anchors that the AQUA intent dispatcher synthesizes, so this
// one hook covers both.

const GRACE_MS = 120

const PageLoadingIndicator = {
  mounted() {
    this._timer = null

    this._onStart = () => {
      if (this._timer) return
      this._timer = setTimeout(() => {
        this._timer = null
        this.el.classList.remove("hidden")
      }, GRACE_MS)
    }

    this._onStop = () => {
      if (this._timer) {
        clearTimeout(this._timer)
        this._timer = null
      }
      this.el.classList.add("hidden")
    }

    window.addEventListener("phx:page-loading-start", this._onStart)
    window.addEventListener("phx:page-loading-stop", this._onStop)
  },

  destroyed() {
    if (this._timer) {
      clearTimeout(this._timer)
      this._timer = null
    }
    window.removeEventListener("phx:page-loading-start", this._onStart)
    window.removeEventListener("phx:page-loading-stop", this._onStop)
  }
}

export default PageLoadingIndicator
