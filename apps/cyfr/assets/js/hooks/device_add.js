// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

/**
 * `/devices/add`, where a person adds a new device. The new device shows a
 * QR code of this page's address with its key's digest in the fragment's
 * `key`, which a browser never sends to a server. The hook reads it,
 * clears the fragment from the address before anything else, so no
 * history entry or bookmark keeps it, and hands the page the digest, or
 * null when the address carried none.
 */

import {keyDigestFromFragment} from "../system_layer/device_key.js"
import {takeFragment} from "./carry.js"

const DeviceAdd = {
  mounted() {
    this.win = this.win || globalThis.window
    const fragment = takeFragment(this.win)
    this.pushEvent("device_key", {
      key_digest: fragment === null ? null : keyDigestFromFragment(fragment)
    })
  }
}

export default DeviceAdd
