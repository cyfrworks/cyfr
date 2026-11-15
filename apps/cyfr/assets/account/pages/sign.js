// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// /account/sign#<request>: a CYFR's request (plan §6) signed with the
// passkey the person picks, and the answer sent to the request's
// `return`. The page names no account (the browser's passkey picker does)
// and sends nothing to its own server for a sign-in or a confirmation; a
// registry signature reads the account's log first, since the registry
// request it signs names the passkey's kid. A browser that holds no
// passkey of the account may make one for a sign-in (`offer`): the person
// names the account, and the new passkey goes back to the CYFR, which
// shows its code for a device of the account to add it.

import {fromB64url} from "../base64url.js"
import {Refusal, b64, refuse} from "../encoding.js"
import {keyOf, userId} from "../identity.js"
import {isHandle} from "../registry.js"
import {here} from "./common.js"
import {answer, digest, fragment, newPasskey, parseFragment, readRequest} from "../sign_in.js"
import {$, attempt, only, say, words} from "../view.js"

// Each operation in words, naming every field of the body it signs.
const OPERATIONS = {
  "handle.claim": ({handle}, at) => `Claim the name @${handle} at ${at}`,
  "policy.accept": ({policy_version}, at) => `Accept the terms (version ${policy_version}) at ${at}`,
  "tokens.mint": ({label}, at) => `Create a publishing token named “${label}” at ${at}`,
  "appeal.file": ({action_type, action_ref, argument}, at) => `Appeal the ${action_type} ${action_ref} at ${at}, saying: “${argument}”`,
  "publisher.claim": ({slug}, at) => `Claim the publisher name ${slug} at ${at}`,
  "publisher.verify": ({slug, label}, at) => `Confirm the publisher name ${slug} at ${at}, with a publishing token named “${label}”`
}

/** What the person is asked to sign, in words. */
export function describe(request) {
  if (request.purpose === "sign_in") return `Sign in to ${request.audience}`
  if (request.purpose === "confirm") return `Confirm a change at ${request.audience}`
  const {operation, body, registry} = request.registry_request
  return OPERATIONS[operation](body, registry)
}

/** The request a fragment carries, refused when malformed or past its expiry at `now`. */
export function readSigned(text, now) {
  const request = readRequest(parseFragment(text))
  if (now >= request.expires_at) refuse("expired")
  return request
}

/**
 * Sign `request` and resolve to the URL the browser goes to: its `return`
 * with the answer in the fragment. A registry request is signed by a
 * passkey of the account it names: with one passkey listed that one is
 * asked; with several, the person first picks one over a page-local
 * challenge, since the digest names the signer before it is signed.
 */
export async function sign(request, env) {
  if (request.purpose !== "registry") {
    const assertion = await env.passkeys.assert({challenge: await digest(request)})
    if (!assertion.identifier) refuse("no_account")
    return `${request.return}#${fragment(answer(request, assertion))}`
  }

  const place = await here(env)
  const {state} = await place.directory.read(request.registry_request.identifier)
  const listed = state.keys.filter((key) => key.kind === "passkey")
  if (listed.length === 0) refuse("no_passkey")
  let chosen = listed[0]
  if (listed.length > 1) {
    const picked = await env.passkeys.assert({challenge: env.random(32), allow: listed.map((key) => fromB64url(key.credential_id))})
    chosen = listed.find((key) => key.credential_id === b64(picked.credentialId))
    if (!chosen) refuse("unknown_passkey")
  }
  const assertion = await env.passkeys.assert({challenge: await digest(request, chosen.kid), allow: [fromB64url(chosen.credential_id)]})
  // An assertion restricted to a credential may carry no user handle; the
  // account is then the one the registry request names.
  const identifier = assertion.identifier ?? request.registry_request.identifier
  return `${request.return}#${fragment(answer(request, {...assertion, identifier}, chosen.kid))}`
}

/**
 * A passkey made in this browser for the account `name` holds, offered to
 * the CYFR that sent the sign-in `request`: resolves to the URL of its
 * `return` with the new passkey in the fragment. Throws `name_invalid` for
 * no name's spelling and `name_unknown` for a name no account holds.
 */
export async function offer(request, name, env) {
  if (!isHandle(name)) refuse("name_invalid")
  const place = await here(env)
  const identifier = (await place.registry.handle(name)).answer?.identifier
  if (!identifier) refuse("name_unknown")
  const {credentialId, pub} = await env.passkeys.create({userId: userId(identifier), name: `@${name}`, challenge: env.random(32)})
  return `${request.return}#${fragment(newPasskey(request, identifier, await keyOf({pub, credentialId})))}`
}

export function run(doc, env) {
  let request
  try {
    request = readSigned(env.location.hash.slice(1), env.now())
  } catch (error) {
    say(doc, "refused-text", error instanceof Refusal ? words(error) : words(new Refusal("bad_link")))
    only(doc, "refused")
    return
  }
  $(doc, "what").textContent = describe(request)
  $(doc, "recover-link").setAttribute("href", `recover#request=${env.location.hash.slice(1)}`)
  $(doc, "offer-way").hidden = request.purpose !== "sign_in"
  $(doc, "offer-start").addEventListener("click", () => only(doc, "offer"))
  const make = $(doc, "offer-make")
  make.addEventListener("click", () =>
    attempt(doc, make, "offer-error", async () => {
      if (env.now() >= request.expires_at) refuse("expired")
      env.navigate(await offer(request, $(doc, "offer-name").value.trim().toLowerCase(), env))
    })
  )
  only(doc, "ask")
  const button = $(doc, "use-passkey")
  button.addEventListener("click", () =>
    attempt(doc, button, "ask-error", async () => {
      if (env.now() >= request.expires_at) refuse("expired")
      env.navigate(await sign(request, env))
    })
  )
}
