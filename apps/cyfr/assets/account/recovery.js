// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Recovery material in the account pages. A recovery code's 32-byte
// secret is drawn here from the browser's cryptographic random source and
// is the seed of the account's recovery key (Ed25519), which signs a
// genesis, recovery entries and the registry requests made at birth. The
// key lives in page memory only: a page drops it once its work is done,
// and the secret is never stored, sent or put in an address. The person
// keeps the code (`encodeRecoveryCode`) and types it to resume or recover.

import {fromB64url} from "./base64url.js"
import {Refusal, b64} from "./encoding.js"
import {ed25519Key, recoverySigner} from "./identity.js"
import {decodeRecoveryCode, encodeRecoveryCode} from "./recovery_code.js"

export const SECRET_BYTES = 32

/** A recovery key from its secret: `{pub, pubText, signer, sign}`. */
export async function recoveryKey(secret) {
  const key = await ed25519Key(secret)
  return {...key, pubText: b64(key.pub), signer: await recoverySigner(key.pub)}
}

/** A new secret drawn from `random` (bytes of a length), and its key. */
export async function drawRecovery(random) {
  const secret = random(SECRET_BYTES)
  const key = await recoveryKey(secret)
  return {secret, key}
}

/** The code the person keeps for `identifier` and `secret`. */
export const codeFor = (identifier, secret) => encodeRecoveryCode(identifier, secret)

/** The identifier and key a typed code holds; throws `not_a_code` or `typo`. */
export async function readCode(text) {
  const read = await decodeRecoveryCode(text)
  if (read.error) throw new Refusal(read.error)
  return {identifier: read.identifier, key: await recoveryKey(fromB64url(read.secret))}
}
