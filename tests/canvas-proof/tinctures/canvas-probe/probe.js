// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The canvas proof's probe canvas, an ordinary HTML page on the vanilla
// template, served as its version's own files and framed by the shell
// under the canvas page policy. `window.cyfr` is the SDK the page carried
// (`apps/cyfr/assets/js/sdk/`), loaded by the element the controller put
// first in the page's head.
//
// It reads the feed `candles` and draws the result's candles as its own
// SVG (one `.candle` rect each), keeps a counter running on a timer so a
// hidden canvas is seen to keep running without any claim that it reads or
// acts, opens an app from a button the person clicks, and exposes, on
// `window.__probe`, its state and a few page-own requests the `policy`
// step drives and reads (never framed as an escape): a script element with
// a foreign `src`, a fetch to a route the policy's `connect-src` does not
// name, and a peer connection to the proof's UDP listener.

const root = document.getElementById("root")
const generation = Math.random().toString(36).slice(2, 10)

root.innerHTML = `
  <h1 id="gen"></h1>
  <p id="count"></p>
  <p id="stream"></p>
  <svg id="chart" width="320" height="140"></svg>
  <p><button id="open" type="button">Open app</button></p>
`
document.getElementById("gen").textContent = `probe ${generation}`
const countEl = document.getElementById("count")
const streamEl = document.getElementById("stream")
const chart = document.getElementById("chart")
document.getElementById("open").addEventListener("click", () => cyfr.open("tincture:local.canvas-full"))

let count = 0
let binding = null
let result = null
const stream = { opened: false, events: 0, refresh: false, revision: null }

// The shell's handshake carries the frame's port, which the SDK keeps; this
// page captures a reference to the same port so the `policy` step can post a
// malformed `open` over it (one the bridge drops), the one message the page
// sends that the SDK's own API never would.
let rawPort = null
let rawFrame = null
window.addEventListener("message", (event) => {
  const data = event.data
  if (data && data.type === "cyfr:handshake" && event.ports && event.ports.length === 1) {
    rawPort = event.ports[0]
    rawFrame = data.frame
  }
})

function drawChart(candles) {
  while (chart.firstChild) chart.removeChild(chart.firstChild)
  candles.forEach((_candle, i) => {
    const rect = document.createElementNS("http://www.w3.org/2000/svg", "rect")
    rect.setAttribute("class", "candle")
    rect.setAttribute("x", String(8 + i * 28))
    rect.setAttribute("y", "10")
    rect.setAttribute("width", "16")
    rect.setAttribute("height", "110")
    chart.appendChild(rect)
  })
}

function render() {
  countEl.textContent = `count ${count}`
  streamEl.textContent = stream.opened
    ? `stream open, ${stream.events} events, revision ${stream.revision}${stream.refresh ? " (refresh)" : ""}`
    : "stream not open"
}

// Each open of the stream is numbered; `refreshedOpen` is the last open whose
// refresh has been delivered, so the page can say when its current open has
// caught up (`settled`), whatever order the open's answer and its first
// event arrive in.
let opens = 0
let refreshedOpen = 0

function onEvent(event, open) {
  const data = event && event.data
  if (!data || data.feed !== "candles") return
  stream.events += 1
  stream.revision = data.revision
  stream.refresh = data.refresh === true
  if (stream.refresh) refreshedOpen = open
  binding = data.binding
  result = data.result || null
  drawChart(result && Array.isArray(result.candles) ? result.candles : [])
  render()
}

// Keep the feed stream open: when the shell suspends the canvas the stream
// closes, and when the canvas is shown again it opens again from its
// refresh. A refused open (the canvas is hidden) is retried on a timer, so
// no stream event reaches it while it is hidden and its stream is back once
// it is shown.
function follow() {
  const open = ++opens
  cyfr.stream("feed.results", "candles", (event) => onEvent(event, open)).then(
    (handle) => {
      stream.opened = true
      render()
      const again = () => {
        stream.opened = false
        render()
        setTimeout(follow, 600)
      }
      handle.closed.then(again, again)
    },
    () => {
      stream.opened = false
      render()
      setTimeout(follow, 600)
    }
  )
}
follow()

// The counter runs whatever the shell does with the frame; the proof never
// reads it as proof the page stopped, only that nothing it reads arrives.
setInterval(() => {
  count += 1
  render()
}, 100)

// A script element the page creates with a foreign `src`: the policy's
// `script-src` names only the version's files and the SDK, so it never
// loads, and no request for it reaches the server.
function foreignScript(src) {
  return new Promise((resolve) => {
    const script = document.createElement("script")
    let settled = false
    const done = (outcome) => {
      if (settled) return
      settled = true
      script.remove()
      resolve({ outcome })
    }
    script.src = src
    script.addEventListener("load", () => done("loaded"))
    script.addEventListener("error", () => done("error"))
    document.head.appendChild(script)
    setTimeout(() => done("no event"), 4000)
  })
}

// A fetch the policy's `connect-src` does not name: it is refused before a
// request is sent, which the page reads as a thrown fetch and the proof as
// no request at the proxy.
async function blockedFetch(url) {
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
      cache: "no-store",
    })
    return { outcome: "answered", status: response.status }
  } catch (_error) {
    return { outcome: "refused" }
  }
}

// A peer connection to the proof's UDP listener: constructed and offered,
// its ICE gathering sends to the STUN host. Chromium sends none under the
// page's connection allowlist; Firefox and WebKit send, recorded as the
// disclosure P1 (a) accepts.
async function peerConnection(host, port) {
  let pc
  try {
    pc = new RTCPeerConnection({ iceServers: [{ urls: `stun:${host}:${port}` }] })
  } catch (_error) {
    return { outcome: "refused" }
  }
  try {
    pc.createDataChannel("probe")
    const offer = await pc.createOffer()
    await pc.setLocalDescription(offer)
    await new Promise((resolve) => setTimeout(resolve, 2500))
    return { outcome: "constructed" }
  } catch (_error) {
    return { outcome: "constructed" }
  } finally {
    try {
      pc.close()
    } catch (_closed) {
      /* already closed */
    }
  }
}

window.__probe = Object.freeze({
  generation,
  state: () => ({
    count,
    binding,
    stream: { ...stream, settled: stream.opened && refreshedOpen === opens },
    candles: result && Array.isArray(result.candles) ? result.candles.length : 0,
    revision: stream.revision,
  }),
  // A press the page sends on its own, with no person input: the shell
  // drops it while the canvas is hidden, whatever the frame's activation.
  press: () => {
    if (binding) cyfr.press(binding, "refresh")
    return binding !== null
  },
  foreignScript,
  blockedFetch,
  peerConnection,
  // An `open` carrying arguments beyond `ref`, posted over the port: the
  // bridge's decode refuses it, so it is dropped and nothing opens.
  openRaw: () => {
    if (!rawPort || !rawFrame) return false
    rawPort.postMessage({
      v: 1,
      verb: "open",
      frame: rawFrame,
      args: { ref: "tincture:local.canvas-full", extra: "data" },
    })
    return true
  },
})

render()
cyfr.ready()
