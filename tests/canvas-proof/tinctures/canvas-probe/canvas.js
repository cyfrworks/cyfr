// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The canvas proof's probe: a canvas whose module keeps a rendered counter,
// reads the feed `candles`, and attempts every exit a canvas's code might
// try from the toolkit's module worker, the one place a canvas's code runs.
//
// It draws, through the toolkit's module API alone: its generation (a fresh
// one each time the toolkit imports it), a counter that ticks while the
// module runs, what its stream delivered, the sibling file it imports
// statically, and the names `installed` gave it.
//
// The proof drives the attempts through `self.__canvasProbe`, in this
// worker: `exits(targets)` and `policy(targets)` make each attempt and
// answer what the worker saw of it; `openWithData(ref)` answers a tree
// whose control opens a tincture with data, holding the counter's trees
// until `resume()`. The targets are the paths and the bearer the proof read
// outside the canvas. An answer names each attempt and its outcome, never a
// target or a bearer; what reached the server is the proof's to read from
// its proxy, since an opaque origin reads a refused request and a request
// the server answered without CORS alike. Every attempt settles here,
// refused or not: an unhandled rejection or an error event would end the
// canvas, which is not what is attempted.

import {SHARED} from "./shared.js"

const FORGED = "forged-by-neighbour"
const SETTLE_MS = 5000

export default function probe(canvas) {
  const generation = Math.random().toString(36).slice(2, 10)
  const stream = {opened: false, events: 0, revision: null, refresh: false, refused: null}
  let count = 0
  let held = false
  let installed = []
  let forged = 0

  const draw = () => {
    if (!held) canvas.render(tree())
  }

  setInterval(() => {
    count += 1
    draw()
  }, 200)

  canvas.on("installed", (list) => {
    installed = Array.isArray(list) ? list.map((one) => one && one.name).filter((name) => typeof name === "string") : []
    if (installed.includes(FORGED)) forged += 1
    draw()
  })

  canvas
    .stream("feed.results", "candles", (event) => {
      const data = event && event.data
      if (!data || data.feed !== "candles") return
      stream.events += 1
      stream.revision = data.revision
      stream.refresh = data.refresh === true
      draw()
    })
    .then(
      () => {
        stream.opened = true
        draw()
      },
      (error) => {
        stream.refused = (error && error.code) || "refused"
        draw()
      }
    )

  function tree() {
    const seen = stream.opened
      ? `open, ${stream.events} events, revision ${stream.revision}${stream.refresh ? " (refresh)" : ""}`
      : stream.refused
        ? `refused ${stream.refused}`
        : "opening"
    return {
      type: "stack",
      direction: "column",
      gap: "s",
      children: [
        {type: "text", value: "probe " + generation, size: "l", weight: "strong"},
        {type: "text", value: "count " + count},
        {type: "text", value: "stream " + seen},
        {type: "text", value: "sibling " + SHARED},
        {type: "text", value: "installed " + installed.join(" ")}
      ]
    }
  }

  self.__canvasProbe = Object.freeze({
    generation,
    state: () => ({
      generation,
      count,
      stream: {...stream},
      installed: [...installed],
      forged,
      sibling: SHARED,
      origin: self.origin,
      protocol: self.location.protocol,
      role: self.name
    }),
    exits,
    policy,
    // The version's own directory under its served prefix, which the proof
    // starts a URL worker of from the frame's page.
    versionDir: () => new URL("./", import.meta.url).href,
    // A tree whose control opens a tincture and carries data besides: the
    // toolkit's grammar refuses the whole tree. The counter's trees are held
    // until `resume()`, so no later tree replaces it before the toolkit reads
    // it.
    openWithData(ref) {
      held = true
      canvas.render({
        type: "stack",
        direction: "column",
        gap: "s",
        children: [
          {type: "text", value: "open with data " + generation},
          {type: "control", effect: {open: ref, data: {note: "carried"}}}
        ]
      })
      return true
    },
    resume() {
      held = false
      draw()
      return true
    }
  })

  draw()
}

// ---- attempts ------------------------------------------------------------------

const settle = (promise) =>
  Promise.race([promise, new Promise((resolve) => setTimeout(() => resolve({timeout: true}), SETTLE_MS))])

// What the worker saw of an error: its name and the browser's sentence. The
// proof redacts any credential a sentence's address carries before it keeps
// it.
const seenError = (error) => ({
  error: (error && error.name) || "Error",
  message: String((error && error.message) || "").slice(0, 240)
})

async function fetched(url, init = {}) {
  try {
    const response = await settle(fetch(url, {cache: "no-store", credentials: "omit", ...init}))
    if (response && response.timeout) return {outcome: "no answer"}
    let body = null
    try {
      body = await response.json()
    } catch (_error) {
      body = null
    }
    const refusal = body && body.error && typeof body.error.message === "string" ? body.error : null
    const code = refusal ? (/\(([a-z_]+)\)\.?$/.exec(refusal.message) || [])[1] || null : null
    return {
      outcome: response.type === "opaqueredirect" ? "redirected" : "answered",
      status: response.status,
      class: refusal ? refusal.class || null : null,
      code
    }
  } catch (error) {
    return {outcome: "refused", ...seenError(error)}
  }
}

async function imported(url) {
  try {
    const loaded = await settle(import(url))
    if (loaded && loaded.timeout) return {outcome: "no answer"}
    return {outcome: "loaded"}
  } catch (error) {
    return {outcome: "refused", ...seenError(error)}
  }
}

function classic(url) {
  try {
    self.importScripts(url)
    return {outcome: "loaded"}
  } catch (error) {
    return {outcome: "refused", ...seenError(error)}
  }
}

// A worker started from a URL: whether it ran (it posts), failed (an
// error event) or could not be constructed.
function urlWorker(url) {
  let worker
  try {
    worker = new Worker(url)
  } catch (error) {
    return Promise.resolve({outcome: "not started", ...seenError(error)})
  }
  return settle(
    new Promise((resolve) => {
      worker.onmessage = () => resolve({outcome: "ran"})
      worker.onerror = (event) => {
        if (event && typeof event.preventDefault === "function") event.preventDefault()
        resolve({outcome: "not started", error: "error event"})
      }
    })
  ).then((seen) => {
    worker.terminate()
    return seen.timeout ? {outcome: "not started", error: "no message"} : seen
  })
}

const STREAM_BODY = JSON.stringify({v: 1, stream: "feed.results", subject: "candles"})
const JSON_HEADERS = {"content-type": "application/json"}

// Each exit, attempted once. `targets` names, under the endpoint's origin:
// the open's own data path, the neighbour's script at its same-site path,
// the neighbour's connect origin, a path to navigate to, the public invoke
// and webhook paths, the forbidden address a redirect would lead to, the
// UDP port of the proof's listener, and the bearer of another frame. Each
// address the worker builds carries an `attempt` query naming the attempt,
// so the proof finds it in its proxy.
async function exits(targets) {
  const at = (path, attempt) => targets.origin + path + (path.includes("?") ? "&" : "?") + "attempt=" + attempt
  const own = targets.own_data_path
  const seen = {}

  // Navigating the frame: a worker has no window to navigate, and its
  // location cannot be assigned.
  let assigned
  try {
    self.location.href = at(targets.navigate_to, "navigate")
    assigned = {outcome: "no error"}
  } catch (error) {
    assigned = {outcome: "refused", ...seenError(error)}
  }
  seen.navigate = {
    location_assign: typeof self.location.assign,
    open: typeof self.open,
    href_assigned: assigned,
    protocol_after: self.location.protocol
  }

  // Messaging a sibling: no window, parent, top, opener or frames reaches
  // one; a broadcast goes to the canvas's own opaque origin alone.
  let broadcast
  try {
    const channel = new BroadcastChannel("cyfr-canvas-proof")
    channel.postMessage({from: "canvas-probe"})
    channel.close()
    broadcast = {outcome: "posted"}
  } catch (error) {
    broadcast = {outcome: "refused", ...seenError(error)}
  }
  seen.sibling = {
    window: typeof self.window,
    parent: typeof self.parent,
    top: typeof self.top,
    opener: typeof self.opener,
    frames: typeof self.frames,
    document: typeof self.document,
    post_message_to_parent: typeof (self.parent && self.parent.postMessage),
    broadcast
  }

  // The colluding sibling's messages to this frame: what reached the module.
  const state = self.__canvasProbe.state()
  seen.colluding = {forged_installed_seen: state.forged, installed: state.installed}

  // The neighbour's script at its same-site path, and its connect origin.
  seen.neighbour = {
    import: await imported(at(targets.neighbour_script, "neighbour_import")),
    import_scripts: classic(at(targets.neighbour_script, "neighbour_import_scripts")),
    connect_origin: await fetched(targets.neighbour_connect + "?attempt=neighbour_connect")
  }

  // A redirect from an allowed canvas or version address to a forbidden
  // one: nothing under the open's data path or the version's prefix
  // answers 3xx, whatever the path. The version addresses are derived from
  // this module's own, the one served prefix the policy admits.
  const versionDir = new URL("./", import.meta.url).href
  const prefixRoot = new URL("../../../", import.meta.url).href
  const version = (href, attempt) => href + (href.includes("?") ? "&" : "?") + "attempt=" + attempt
  const forbidden = encodeURIComponent(targets.origin + targets.forbidden)
  seen.redirect = {
    fetch: {
      data_root: await fetched(at(own, "redirect_data_root"), {method: "POST", body: STREAM_BODY, redirect: "manual"}),
      data_no_slash: await fetched(at(own.replace(/\/$/, ""), "redirect_data_no_slash"), {
        method: "POST",
        body: STREAM_BODY,
        redirect: "manual"
      }),
      stream_slash: await fetched(at(own + "stream/", "redirect_stream_slash"), {
        method: "POST",
        body: STREAM_BODY,
        redirect: "manual"
      }),
      dot_segments: await fetched(at(own + "..%2F..%2F..%2F_c%2Fv1%2F", "redirect_dot_segments"), {
        method: "POST",
        body: STREAM_BODY,
        redirect: "manual"
      }),
      next_query: await fetched(at(own + "stream?next=" + forbidden, "redirect_next_query"), {
        method: "POST",
        body: STREAM_BODY,
        redirect: "manual"
      })
    },
    script: {
      version_directory: await imported(version(versionDir.slice(0, -1), "redirect_version_directory")),
      version_directory_slash: await imported(version(versionDir, "redirect_version_directory_slash")),
      prefix_root: await imported(version(prefixRoot, "redirect_prefix_root")),
      dot_segments: await imported(version(versionDir + "..%2F..%2F..%2F_c%2Fv1%2F", "redirect_script_dot_segments")),
      next_query: await imported(version(versionDir + "canvas.js?next=" + forbidden, "redirect_script_next_query"))
    }
  }

  // A worker's RTCPeerConnection, which would send UDP to the listener.
  let rtc = {outcome: "absent"}
  if (typeof self.RTCPeerConnection === "function") {
    try {
      const peer = new self.RTCPeerConnection({iceServers: [{urls: "stun:127.0.0.1:" + targets.udp_port}]})
      peer.createDataChannel("probe")
      await peer.setLocalDescription(await peer.createOffer())
      rtc = {outcome: "constructed"}
      peer.close()
    } catch (error) {
      rtc = {outcome: "refused", ...seenError(error)}
    }
  }
  seen.rtc = {
    rtc_peer_connection: typeof self.RTCPeerConnection,
    webkit_rtc_peer_connection: typeof self.webkitRTCPeerConnection,
    attempt: rtc
  }

  // A public invoke and a webhook.
  seen.public = {
    invoke: await fetched(at(targets.public_invoke, "public_invoke"), {
      method: "POST",
      headers: JSON_HEADERS,
      body: JSON.stringify({v: 1, ref: "catalyst:local.candles", operation: "quote", args: {}, public: {}})
    }),
    webhook: await fetched(at(targets.webhook, "webhook"), {method: "POST", body: "{}"})
  }

  // A write on the data routes: the open's path has no invoke or action
  // route, its stream route takes no write, the shared action route is not
  // the canvas's, and the module holds no bearer to write with.
  seen.write = {
    own_invoke: await fetched(at(own + "invoke", "write_own_invoke"), {
      method: "POST",
      headers: JSON_HEADERS,
      body: JSON.stringify({v: 1, ref: "catalyst:local.candles", operation: "quote", args: {}})
    }),
    own_action: await fetched(at(own + "action", "write_own_action"), {
      method: "POST",
      headers: JSON_HEADERS,
      body: JSON.stringify({v: 1, operation: "feed.press", args: {}})
    }),
    own_stream: await fetched(at(own + "stream", "write_own_stream"), {
      method: "POST",
      headers: JSON_HEADERS,
      body: JSON.stringify({v: 1, operation: "feed.press", args: {}})
    }),
    shared_action: await fetched(at(targets.shared_action, "write_shared_action"), {
      method: "POST",
      headers: JSON_HEADERS,
      body: JSON.stringify({v: 1, operation: "feed.press", args: {}})
    })
  }

  // Another frame's bearer, which the probe received, on its own route.
  seen.foreign_bearer = await fetched(at(own + "stream", "foreign_bearer"), {
    method: "POST",
    headers: {...JSON_HEADERS, authorization: "Bearer " + targets.foreign_bearer},
    body: STREAM_BODY
  })

  return seen
}

// The worker policy's attempts. `targets` names, under the endpoint's
// origin: another open's data path, and a file at another credential's
// served prefix.
async function policy(targets) {
  const at = (path, attempt) => targets.origin + path + (path.includes("?") ? "&" : "?") + "attempt=" + attempt
  const versionDir = new URL("./", import.meta.url).href
  return {
    origin: self.origin,
    worker: {protocol: self.location.protocol, role: self.name},
    other_open: await fetched(at(targets.other_data_path, "policy_other_open"), {
      method: "POST",
      headers: JSON_HEADERS,
      body: STREAM_BODY
    }),
    version_file: await fetched(import.meta.url + "?attempt=policy_version_fetch"),
    other_prefix: {
      import: await imported(at(targets.other_prefix_file, "policy_other_prefix_import")),
      import_scripts: classic(at(targets.other_prefix_file, "policy_other_prefix_import_scripts"))
    },
    sibling: SHARED,
    nested_worker: await urlWorker(versionDir + "canvas.js?attempt=policy_nested_worker")
  }
}
