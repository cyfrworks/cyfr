// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The glass's one base64url codec: the RFC 4648 §5 alphabet, unpadded both
// ways. Padding and any other character are refused on the way in.

/** Unpadded base64url of `bytes` (an ArrayBuffer or a view of one). */
export function b64url(bytes) {
  const view = bytes instanceof ArrayBuffer ? new Uint8Array(bytes) : new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  let binary = ""
  for (const byte of view) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

/** The bytes unpadded base64url `text` spells, as a Uint8Array. */
export function fromB64url(text) {
  if (typeof text !== "string" || !/^[A-Za-z0-9_-]*$/.test(text)) throw new TypeError("not unpadded base64url")
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/")
  const binary = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4))
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}
