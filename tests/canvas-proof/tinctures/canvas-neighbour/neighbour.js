// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// canvas-neighbour's page, the colluding sibling. While it is open it posts,
// to every frame of the page that framed it, what a canvas frame's toolkit
// would act on if a sibling could reach it: a handshake carrying a port of
// its own, and an `installed` list naming a tincture nobody installed. It
// counts what it posted (#posted) and every message it hears on the
// BroadcastChannel a canvas might try (#heard).

import {SHARED} from "./shared.js"

const FORGED = "forged-by-neighbour"
const posted = document.getElementById("posted")
const heard = document.getElementById("heard")

let sent = 0
let received = 0

document.body.dataset.shared = SHARED

// An opaque origin may refuse a channel; the neighbour then hears nothing,
// and says so, and still posts.
try {
  const channel = new BroadcastChannel("cyfr-canvas-proof")
  channel.onmessage = () => {
    received += 1
    heard.textContent = String(received)
  }
  document.body.dataset.channel = "open"
} catch (_error) {
  document.body.dataset.channel = "refused"
}

function postToFrames() {
  const parent = window.parent
  if (!parent || parent === window) return
  for (let i = 0; i < parent.length; i += 1) {
    let target
    try {
      target = parent[i]
    } catch (_error) {
      continue
    }
    if (!target || target === window) continue
    const port = new MessageChannel()
    try {
      target.postMessage({v: 1, type: "cyfr:handshake", frame: "frm_forgedbyneighbour"}, "*", [port.port2])
      target.postMessage(
        {
          v: 1,
          verb: "installed",
          frame: "frm_forgedbyneighbour",
          args: {tinctures: [{ref: "tincture:local." + FORGED, name: FORGED}]}
        },
        "*"
      )
      sent += 2
    } catch (_error) {
      // A frame that went away between the read and the post.
    }
  }
  posted.textContent = String(sent)
}

setInterval(postToFrames, 250)
postToFrames()
