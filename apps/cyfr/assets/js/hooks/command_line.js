// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

/**
 * `/cli`, where a person approves a command line's sign-in. `cyfr login`
 * prints this page's address with the approval secret in the fragment's
 * `code`, which a browser never sends to a server. The hook reads it,
 * clears the fragment from the address before anything else, so no
 * history entry, bookmark or shared address keeps it, and hands the page
 * the secret, or null when the address carried none.
 */

import {codeFromFragment} from "../system_layer/device_key.js"
import {takeFragment} from "./carry.js"

const CommandLine = {
  mounted() {
    this.win = this.win || globalThis.window
    const fragment = takeFragment(this.win)
    this.pushEvent("cli_code", {code: fragment === null ? null : codeFromFragment(fragment)})
  }
}

export default CommandLine
