// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

/**
 * `/confirm`, where a person whose keys are at another CYFR comes back
 * from confirming a change there. Their own CYFR sends the browser here
 * with its certified assertion in the fragment's `home_assertion`
 * (`tests/fixtures/confirmation_assertion.json`), which a browser never
 * sends to a server. The hook reads it, clears the fragment from the
 * address before anything else, so no history entry or bookmark keeps it,
 * and hands the page the assertion's unpadded base64url text, or null when
 * the address carried none.
 */

import {takeFragment} from "./carry.js"

/** The `home_assertion` an address's fragment carries, or null. */
export function homeAssertionFromFragment(fragment) {
  if (typeof fragment !== "string") return null
  const value = new URLSearchParams(fragment.replace(/^#/, "")).get("home_assertion")
  return value && /^[A-Za-z0-9_-]+$/.test(value) ? value : null
}

const HomeConfirm = {
  mounted() {
    this.win = this.win || globalThis.window
    const fragment = takeFragment(this.win)
    this.pushEvent("home_assertion", {assertion: fragment === null ? null : homeAssertionFromFragment(fragment)})
  }
}

export default HomeConfirm
