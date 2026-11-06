// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// What the pages that change an account share: the directory this page
// is served by, an account named by a passkey, and an entry signed by it.

import {b64, refuse} from "../encoding.js"
import {attach, challenge} from "../identity.js"
import {directory, readConfig, registry} from "../network.js"

/**
 * This page's configuration, directory and registry. A configuration
 * whose directory is at another origin is refused: a passkey made here
 * signs only for this host.
 */
export async function here(env) {
  const config = await readConfig(env.origin, env.fetch)
  if (new URL(config.directory).origin !== env.origin) refuse("bad_config")
  return {config, directory: directory(config.directory, env.fetch), registry: registry(config.registry, env.fetch)}
}

/**
 * The account a passkey names: a discoverable assertion over a page-local
 * challenge, whose user handle names the account, then its log, which
 * must list that passkey.
 */
export async function namedByPasskey(env, dir) {
  const picked = await env.passkeys.assert({challenge: env.random(32)})
  if (!picked.identifier) refuse("no_account")
  const {state, entries} = await dir.read(picked.identifier)
  const passkey = state.keys.find((key) => key.kind === "passkey" && key.credential_id === b64(picked.credentialId))
  if (!passkey) refuse("unknown_passkey")
  return {identifier: picked.identifier, state, entries, passkey, credentialId: picked.credentialId}
}

/** `entry` signed by the session's passkey: a second assertion, restricted to it, over the entry's challenge. */
export async function signedByPasskey(env, session, entry) {
  const made = await env.passkeys.assert({challenge: await challenge(entry), allow: [session.credentialId]})
  return attach(entry, {authenticator_data: made.authenticatorData, client_data: made.clientData, signature: made.signature})
}

/** A key's short code, as a device shows it: the first 16 hex digits of its kid. */
export const shortCode = (kid) => kid.slice("sha256:".length, "sha256:".length + 16)

/** When each listed key was added: the `at` of the entry that listed it last. */
export function addedAt(entries) {
  const at = new Map()
  for (const entry of entries) {
    if (entry.kind === "add_key") at.set(entry.key.kid, entry.at)
    if (entry.kind === "recover") for (const key of entry.keys) at.set(key.kid, entry.at)
  }
  return at
}

const KINDS = {passkey: "Passkey", device: "Device"}

/** How the pages list one key: its kind, short code and the date it was added. */
export function keyLabel({kind, code, added, current}) {
  const date = added === undefined ? "" : `, added ${new Date(added).toLocaleDateString()}`
  return `${KINDS[kind]} ${code}${current ? " (this passkey)" : ""}${date}`
}
