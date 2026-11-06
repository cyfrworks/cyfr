// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// /account/devices#: the keys of the account the person's passkey names
// (plan §7), listed by kind, short code and the date each was added, and
// one removed with a second assertion, restricted to that passkey, over
// the `remove_key` entry. A key never removes itself, so the passkey in
// use is listed without a Remove button: another passkey, a device or the
// recovery code removes it.

import {next} from "../identity.js"
import {addedAt, here, keyLabel, namedByPasskey, shortCode, signedByPasskey} from "./common.js"
import {$, attempt, only, say, words} from "../view.js"

/** The account's keys as the page lists them. */
export function listing(session) {
  const at = addedAt(session.entries)
  return session.state.keys.map((key) => ({
    kid: key.kid,
    kind: key.kind,
    code: shortCode(key.kid),
    added: at.get(key.kid),
    current: key.kid === session.passkey.kid
  }))
}

/** The `remove_key` entry for `kid`, signed by the session's passkey. */
export function removal(env, session, kid) {
  return signedByPasskey(env, session, next(session.state, "remove_key", {kid}, {at: env.now(), signer: session.passkey.kid}))
}

export async function run(doc, env) {
  let place
  try {
    place = await here(env)
  } catch (error) {
    say(doc, "refused-text", words(error))
    only(doc, "refused")
    return
  }
  only(doc, "ask")
  let session = null
  // The removal last signed, sent again unchanged after a lost response.
  let pending = null

  const draw = () => {
    const rows = listing(session).map((key) => {
      const row = doc.createElement("li")
      const label = doc.createElement("span")
      label.textContent = keyLabel(key)
      row.append(label)
      if (!key.current) {
        const remove = doc.createElement("button")
        remove.type = "button"
        remove.textContent = "Remove"
        remove.addEventListener("click", () =>
          attempt(doc, remove, "list-error", async () => {
            if (pending?.kid !== key.kid) pending = {kid: key.kid, entry: await removal(env, session, key.kid)}
            await place.directory.append(session.identifier, pending.entry)
            pending = null
            session = {...session, ...(await place.directory.read(session.identifier))}
            draw()
          })
        )
        row.append(remove)
      }
      return row
    })
    $(doc, "keys").replaceChildren(...rows)
    only(doc, "list")
  }

  const open = $(doc, "open")
  open.addEventListener("click", () =>
    attempt(doc, open, "ask-error", async () => {
      session = await namedByPasskey(env, place.directory)
      draw()
    })
  )
}
