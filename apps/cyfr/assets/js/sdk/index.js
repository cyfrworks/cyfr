// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The Cyfr tincture SDK, built into `priv/static/sdk/cyfr.js` and injected
// into a tincture's entry page, so `window.cyfr` is there before the page's
// own scripts run:
//
//   cyfr.ready()
//   const result = await cyfr.invoke("c:local.weather:1.0.0", "run", {city: "Lisbon"})
//
// Its listener is registered here, before the page loads, so the shell's
// handshake on the frame's load always finds it.

import {createClient} from "./client.js"

const client = createClient({
  win: window,
  fetchFn: window.fetch.bind(window),
  base: document.baseURI
})

window.addEventListener("message", client.onWindowMessage)
window.cyfr = client.api
