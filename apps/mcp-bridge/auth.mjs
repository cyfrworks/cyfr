// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// How CYFR and the bridge authenticate each other: the bridge's half. The
// server's half is Prima.BridgeAuth (apps/prima), and
// tests/fixtures/bridge_auth.json holds the vectors both must reproduce.
//
// One 32-byte root secret (CYFR_MCP_BRIDGE_KEY, 64 hexadecimal digits) is
// shared by both sides.
// The control key, the seal key and each owner's key are HMAC-SHA256 of the
// root over a label, so nothing but the root is configured or stored. A
// signature is the unpadded base64url HMAC-SHA256 of a canonical string —
// the kind, its fields, and the hex SHA-256 of the raw body, one per line —
// carried in `Cyfr-Bridge-Auth: v1 kind=<kind> name=value … body=<hex> mac=<mac>`.
// The header names the body's hash, so its MAC verifies before any of the
// body is read, and the body read afterwards must hash to it. Every field is
// 1 to 256 bytes of printable ASCII without spaces: a string
// field is a string, whatever it spells; an integer field is an integer from
// 0 to 2^53 − 1, written in decimal without leading zeros.

import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createHmac,
  timingSafeEqual,
} from "node:crypto";

const VERSION = "v1";
const FIELD = /^[\x21-\x7E]{1,256}$/;
const DECIMAL = /^(0|[1-9][0-9]*)$/;
const MAX_INTEGER = BigInt(Number.MAX_SAFE_INTEGER);
const BODY_HASH = /^[0-9a-f]{64}$/;

const KIND_FIELDS = new Map([
  ["invoke", ["athanor", "server", "generation", "epoch", "boot", "ts", "nonce"]],
  ["control", ["generation", "seq", "cyfr_boot", "boot", "ts"]],
]);
const INTEGER_FIELDS = new Set(["generation", "epoch", "ts", "seq"]);
const HEADER_NAMES = new Map([
  ["athanor", "athanor"],
  ["server", "server"],
  ["generation", "gen"],
  ["epoch", "epoch"],
  ["boot", "boot"],
  ["ts", "ts"],
  ["nonce", "nonce"],
  ["seq", "seq"],
  ["cyfr_boot", "cyfr_boot"],
]);

export class InvalidField extends Error {
  constructor(field) {
    super(`invalid ${field}`);
    this.field = field;
  }
}

const derive = (root, label) => createHmac("sha256", root).update(label).digest();

const ROOT_TEXT = /^[0-9a-fA-F]{64}$/;

// The root secret from its configured text: exactly 64 hexadecimal digits,
// in either case. Anything else throws InvalidField("root").
export function decodeRoot(text) {
  if (typeof text !== "string" || !ROOT_TEXT.test(text)) throw new InvalidField("root");
  return Buffer.from(text, "hex");
}

function rootKey(root) {
  if (!Buffer.isBuffer(root) || root.length !== 32) throw new InvalidField("root");
  return root;
}

// A message field's text: a string field's string, or an integer field's
// number in decimal. Anything else throws InvalidField(name).
function field(message, name) {
  const value = message[name];
  const text = INTEGER_FIELDS.has(name) ? integerText(value) : value;
  if (typeof text !== "string" || !FIELD.test(text)) throw new InvalidField(name);
  return text;
}

const integerText = (value) => (Number.isSafeInteger(value) && value >= 0 ? String(value) : null);

// A header value read as a field: a string field's text, or an integer
// field's decimal spelling as a number. Anything else is null.
function readField(name, text) {
  if (typeof text !== "string" || !FIELD.test(text)) return null;
  if (!INTEGER_FIELDS.has(name)) return text;
  return DECIMAL.test(text) && BigInt(text) <= MAX_INTEGER ? Number(text) : null;
}

const values = (message, names) => names.map((name) => field(message, name));

/** Whether `value` is a valid string field: 1 to 256 bytes of printable ASCII without spaces. */
export const validField = (value) => typeof value === "string" && FIELD.test(value);

export const controlKey = (root) => derive(rootKey(root), "cyfr-bridge/v1/control");
export const sealKey = (root) => derive(rootKey(root), "cyfr-bridge/v1/seal");

export function ownerKey(root, owner) {
  const label = ["cyfr-bridge/v1/owner", ...values(owner, ["athanor", "server", "generation", "epoch"])].join("\n");
  return derive(rootKey(root), label);
}

/** The hex SHA-256 of a raw body, as canonical strings and headers name it. */
export const bodyHash = (body) => createHash("sha256").update(body).digest("hex");

function canonicalOver(kind, message, hash) {
  const names = KIND_FIELDS.get(kind);
  if (!names) throw new InvalidField("kind");
  return [`cyfr-bridge/${VERSION}/${kind}`, ...values(message, names), hash].join("\n");
}

export const canonical = (kind, message, body) => canonicalOver(kind, message, bodyHash(body));

const mac = (key, text) => createHmac("sha256", key).update(text).digest("base64url");

function header(kind, key, message, body) {
  const hash = bodyHash(body);
  const pairs = KIND_FIELDS.get(kind).map((name) => `${HEADER_NAMES.get(name)}=${field(message, name)}`);
  return [`${VERSION} kind=${kind}`, ...pairs, `body=${hash}`, `mac=${mac(key, canonicalOver(kind, message, hash))}`].join(" ");
}

export const invokeHeader = (key, invoke, body) => header("invoke", key, invoke, body);
export const controlHeader = (key, control, body) => header("control", key, control, body);

// A header of `kind` ("invoke" or "control") as `{kind, fields, bodyHash,
// mac}`, or null. A header is v1 followed by name=value tokens, each
// separated by one space: `kind` naming the kind, every field of the kind
// once under its header name, `body` and `mac`, in any order and nothing
// else. A name is everything before a token's first `=`; a field value and
// the MAC are valid field text, an integer field's value is its decimal
// spelling, and `body` is 64 lowercase hexadecimal digits. Integer fields
// come back as numbers.
export function parseHeader(kind, text) {
  const names = KIND_FIELDS.get(kind);
  if (!names || typeof text !== "string") return null;
  const [version, ...tokens] = text.split(" ");
  if (version !== VERSION) return null;

  const pairs = new Map();
  for (const token of tokens) {
    const at = token.indexOf("=");
    if (at <= 0 || pairs.has(token.slice(0, at))) return null;
    pairs.set(token.slice(0, at), token.slice(at + 1));
  }
  if (
    pairs.size !== names.length + 3 ||
    pairs.get("kind") !== kind ||
    !FIELD.test(pairs.get("mac") ?? "") ||
    !BODY_HASH.test(pairs.get("body") ?? "")
  ) {
    return null;
  }

  const fields = {};
  for (const name of names) {
    const value = readField(name, pairs.get(HEADER_NAMES.get(name)));
    if (value === null) return null;
    fields[name] = value;
  }
  return { kind, fields, bodyHash: pairs.get("body"), mac: pairs.get("mac") };
}

// Whether `parsed` (from parseHeader) is signed with `key` over its fields
// and the body hash it names, compared in constant time. That the body is
// the one named is bodyMatches's to say.
export function verify(key, parsed) {
  let expected;
  try {
    expected = Buffer.from(mac(key, canonicalOver(parsed.kind, parsed.fields, parsed.bodyHash)));
  } catch {
    return false;
  }
  const presented = Buffer.from(parsed.mac);
  return presented.length === expected.length && timingSafeEqual(presented, expected);
}

// Whether `body` hashes to the hash `parsed` names.
export function bodyMatches(parsed, body) {
  const actual = Buffer.from(bodyHash(body));
  const named = Buffer.from(parsed.bodyHash);
  return actual.length === named.length && timingSafeEqual(actual, named);
}

const sealAad = (owner, boot) =>
  ["cyfr-bridge/v1/seal", ...values({ ...owner, boot }, ["athanor", "server", "generation", "epoch", "boot"])].join("\n");

export function seal(key, owner, boot, plaintext, iv) {
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  cipher.setAAD(Buffer.from(sealAad(owner, boot)));
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString("base64url");
}

// What seal() sealed for the same owner and bridge lifetime, or null.
export function open(key, owner, boot, sealed) {
  try {
    const bytes = Buffer.from(sealed, "base64url");
    if (bytes.length < 28) return null;
    const decipher = createDecipheriv("aes-256-gcm", key, bytes.subarray(0, 12));
    decipher.setAAD(Buffer.from(sealAad(owner, boot)));
    decipher.setAuthTag(bytes.subarray(12, 28));
    return Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]);
  } catch {
    return null;
  }
}
