// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A protected device's unlock, its browser's last hop: the box's shell
// sends its browser to `/auth/device/complete#<ticket>`, a one-time
// ticket of 32 bytes in unpadded base64url (`tests/fixtures/device_unlock.json`,
// `exchange`). The fragment never travels in a request; this takes it,
// removes it from the address bar and the history entry before anything
// else, and posts it with the page's CSRF token in the form the page
// drew. A fragment that is not a ticket posts nothing.

export const TICKET = /^[A-Za-z0-9_-]{43}$/

// Answers whether the form was posted. `win` is the page's window:
// its `document`, `location` and `history`.
export function completeUnlock(win) {
  const form = win.document.querySelector("form[data-device-unlock]")
  if (!form) return false

  const hash = win.location.hash || ""
  const ticket = hash.startsWith("#") ? hash.slice(1) : ""

  // The address and the history entry lose the ticket first, so a reload,
  // a back step or a copied address never carries it again.
  win.history.replaceState(null, "", win.location.pathname)

  if (!TICKET.test(ticket)) return false

  form.querySelector("input[name='ticket']").value = ticket
  form.submit()
  return true
}
