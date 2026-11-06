// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// /account/add#key=&alg=&kind=&code=: a device added to the account of
// the passkey the person picks (plan §7). The device shows its short code;
// the page shows the same code from the key in the link and refuses a
// link whose code is not its key's. A first assertion names the account,
// the page reads its log and composes `add_key`, and a second assertion,
// restricted to that passkey, signs it. A lost response resends the same
// entry; `exists` is success. The device learns of it by reading its
// account's log.

import {refuse, unb64} from "../encoding.js"
import {keyOf, next} from "../identity.js"
import {here, namedByPasskey, shortCode, signedByPasskey} from "./common.js"
import {$, attempt, only, say, words} from "../view.js"

/** The device key a link names, its kid's short code matching the link's `code`; throws `bad_link`. */
export async function readDevice(params) {
  const pub = unb64(params.get("key"), 32)
  if (!pub || params.get("alg") !== "ed25519" || params.get("kind") !== "device") refuse("bad_link")
  const key = await keyOf({pub})
  if (shortCode(key.kid) !== params.get("code")) refuse("bad_link")
  return key
}

/**
 * The adding, step by step: `sign()` names the account and signs the
 * entry (two ceremonies), `send()` appends it and may be sent again after
 * a lost response. `sign()` resolves to "listed" when the account already
 * lists the device.
 */
export function adding(env, place, device) {
  let session = null
  let signed = null
  return {
    async sign() {
      session = await namedByPasskey(env, place.directory)
      if (session.state.keys.some((key) => key.kid === device.kid)) return "listed"
      const entry = next(session.state, "add_key", {key: device}, {at: env.now(), signer: session.passkey.kid})
      signed = await signedByPasskey(env, session, entry)
      return "signed"
    },
    send: () => place.directory.append(session.identifier, signed)
  }
}

export async function run(doc, env) {
  let device
  let place
  try {
    device = await readDevice(new URLSearchParams(env.location.hash.slice(1)))
    place = await here(env)
  } catch (error) {
    say(doc, "refused-text", words(error))
    only(doc, "refused")
    return
  }
  $(doc, "device-code").textContent = shortCode(device.kid)
  only(doc, "ask")

  const flow = adding(env, place, device)
  const send = async () => {
    await flow.send()
    only(doc, "added")
  }
  const button = $(doc, "add")
  button.addEventListener("click", () =>
    attempt(doc, button, "ask-error", async () => {
      if ((await flow.sign()) === "listed") return only(doc, "added")
      only(doc, "sending")
      await attempt(doc, $(doc, "retry"), "sending-error", send)
    })
  )
  const retry = $(doc, "retry")
  retry.addEventListener("click", () => attempt(doc, retry, "sending-error", send))
}
