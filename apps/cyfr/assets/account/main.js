// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The account pages' one script. Each page's <body data-page> names the
// page it runs; the browser's own capabilities are handed to it as one
// environment, which the tests replace with canned material. The service
// worker keeps the pages for a visit with no network.

import {passkeys} from "./ceremony.js"
import * as add from "./pages/add.js"
import * as devices from "./pages/devices.js"
import * as created from "./pages/new.js"
import * as recover from "./pages/recover.js"
import * as sign from "./pages/sign.js"

const PAGES = {new: created, sign, add, recover, devices}

function storage() {
  try {
    return window.localStorage
  } catch (_error) {
    return null
  }
}

const env = {
  origin: window.location.origin,
  location: window.location,
  passkeys: passkeys(navigator.credentials, window.location.hostname),
  fetch: (url, init) => window.fetch(url, init),
  storage: storage(),
  now: () => Date.now(),
  random: (size) => crypto.getRandomValues(new Uint8Array(size)),
  navigate: (url) => window.location.assign(url),
  print: () => window.print()
}

PAGES[document.body.dataset.page]?.run(document, env)

if ("serviceWorker" in navigator) navigator.serviceWorker.register("sw.js", {scope: "./"}).catch(() => {})
