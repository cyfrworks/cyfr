/**
 * ShellViewport hook — reports viewport dimensions to the server.
 */
const ShellViewport = {
  mounted() {
    this._reportViewport()

    this._resizeHandler = this._debounce(() => this._reportViewport(), 150)
    window.addEventListener("resize", this._resizeHandler)
  },

  destroyed() {
    window.removeEventListener("resize", this._resizeHandler)
  },

  _reportViewport() {
    this.pushEvent("viewport_changed", {
      width: window.innerWidth,
      height: window.innerHeight
    })
  },

  _debounce(fn, ms) {
    let timer
    return (...args) => {
      clearTimeout(timer)
      timer = setTimeout(() => fn(...args), ms)
    }
  }
}

export default ShellViewport
