// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The pages' few DOM helpers and the one place their words for a refusal
// live. A page's HTML holds every section it can show; the script shows
// one at a time and fills in text, never HTML.

import {Refusal} from "./encoding.js"
import {Unreachable} from "./network.js"

const WORDS = {
  unreachable: "CYFR could not be reached. Check your connection and try again.",
  expired: "This request has expired. Go back to your CYFR and start again.",
  too_large: "This link is not one this page can answer.",
  invalid_fragment: "This link is not one this page can answer.",
  bad_link: "This link is not one this page can answer.",
  bad_config: "This page is not set up correctly. Try again later.",
  gone: "This account no longer exists.",
  not_found: "This account is not known here.",
  no_account: "That passkey does not belong to an account here.",
  unknown_passkey: "That passkey is no longer on its account. Use another passkey, or your recovery code.",
  no_passkey: "This account has no passkey. Add one with your recovery code first.",
  name_taken: "That name is taken. Choose another.",
  name_invalid: "A name is 1 to 39 lowercase letters, digits and single hyphens, starting and ending with a letter or digit.",
  name_elsewhere: "That name is not this account's. Type the name of the account this code recovers.",
  not_a_code: "That is not a recovery code. Check what you typed.",
  typo: "That recovery code has a typo. Check each group and try again.",
  code_replaced: "That recovery code no longer works for its account.",
  other_code: "That recovery code is for another account.",
  stale_head: "Your account changed while this page was open. Start again.",
  duplicate_key: "That is already on your account.",
  cancelled: "The passkey was not used. Try again when you are ready."
}

/** The plain words for what went wrong. */
export function words(error) {
  if (error instanceof Unreachable) return WORDS.unreachable
  if (error instanceof Refusal) return WORDS[error.reason] ?? "Something went wrong. Try again."
  if (error?.name === "NotAllowedError" || error?.name === "AbortError") return WORDS.cancelled
  return "Something went wrong. Try again."
}

export const $ = (doc, id) => doc.getElementById(id)

/** Show the section `id` of `doc` and hide its siblings in `main`. */
export function only(doc, id) {
  for (const section of doc.querySelectorAll("main > section")) section.hidden = section.id !== id
}

export function say(doc, id, text) {
  const element = $(doc, id)
  element.textContent = text
  element.hidden = text === ""
}

/** Run `action` with `button` disabled, showing what went wrong in the element `errorId`. */
export async function attempt(doc, button, errorId, action) {
  button.disabled = true
  say(doc, errorId, "")
  try {
    await action()
  } catch (error) {
    say(doc, errorId, words(error))
  } finally {
    button.disabled = false
  }
}

/** The recovery code drawn into `slot`, a line break allowed only after each group's hyphen. */
export function drawCode(doc, slot, code) {
  const groups = code.split("-")
  slot.replaceChildren(
    ...groups.flatMap((group, i) => (i < groups.length - 1 ? [doc.createTextNode(`${group}-`), doc.createElement("wbr")] : [doc.createTextNode(group)]))
  )
}

/** Write `code` to the clipboard and say so on `button`; a refused write leaves the button as it was. */
export async function copyCode(button, code, clipboard = globalThis.navigator?.clipboard) {
  try {
    await clipboard.writeText(code)
    button.textContent = "Copied"
  } catch (_error) {
    // The code stays on screen to copy by hand or print.
  }
}
