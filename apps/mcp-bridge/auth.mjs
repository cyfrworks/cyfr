// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// How CYFR and the bridge authenticate each other: the bridge's half. The
// server's half is Cyfr.BridgeAuth (apps/cyfr_contracts), and
// tests/fixtures/bridge_auth.json holds the vectors both must reproduce.
//
// One 32-byte root secret (CYFR_MCP_BRIDGE_KEY, 64 hexadecimal digits) is
// shared by both sides.
// The control key, the seal key and each owner's key are HMAC-SHA256 of the
// root over a label, so nothing but the root is configured or stored. A
// signature is the unpadded base64url HMAC-SHA256 of a canonical string —
// the kind, its fields, and the hex SHA-256 of the raw body, one per line —
// carried in `Cyfr-Bridge-Auth: v1 kind=<kind> name=value … mac=<mac>`.
// Every field is 1 to 256 bytes of printable ASCII without spaces.

import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createHmac,
  timingSafeEqual,
} from "node:crypto";

const VERSION = "v1";
const FIELD = /^[\x21-\x7E]{1,256}$/;
const INTEGER = /^(0|[1-9][0-9]{0,19})$/;

const INVOKE_FIELDS = ["athanor", "server", "generation", "epoch", "boot", "ts", "nonce"];
const CONTROL_FIELDS = ["generation", "seq", "cyfr_boot", "boot", "ts"];
const INTEGER_FIELDS = new Set(["generation", "epoch", "ts", "seq"]);
const HEADER_NAMES = {
  athanor: "athanor",
  server: "server",
  generation: "gen",
  epoch: "epoch",
  boot: "boot",
  ts: "ts",
  nonce: "nonce",
  seq: "seq",
  cyfr_boot: "cyfr_boot",
};
const FIELD_NAMES = Object.fromEntries(Object.entries(HEADER_NAMES).map(([field, header]) => [header, field]));

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

function field(message, name) {
  const value = message[name];
  const text = typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? String(value) : value;
  if (typeof text !== "string" || !FIELD.test(text)) throw new InvalidField(name);
  if (INTEGER_FIELDS.has(name) && !INTEGER.test(text)) throw new InvalidField(name);
  return text;
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

export function canonical(kind, message, body) {
  const names = kind === "invoke" ? INVOKE_FIELDS : kind === "control" ? CONTROL_FIELDS : null;
  if (!names) throw new InvalidField("kind");
  const bodyHash = createHash("sha256").update(body).digest("hex");
  return [`cyfr-bridge/${VERSION}/${kind}`, ...values(message, names), bodyHash].join("\n");
}

const mac = (key, text) => createHmac("sha256", key).update(text).digest("base64url");

function header(kind, key, message, names, body) {
  const pairs = names.map((name) => `${HEADER_NAMES[name]}=${field(message, name)}`);
  return [`${VERSION} kind=${kind}`, ...pairs, `mac=${mac(key, canonical(kind, message, body))}`].join(" ");
}

export const invokeHeader = (key, invoke, body) => header("invoke", key, invoke, INVOKE_FIELDS, body);
export const controlHeader = (key, control, body) => header("control", key, control, CONTROL_FIELDS, body);

// A header's kind, fields and MAC, or null for anything that is not exactly
// one well-formed v1 header: every expected field once, no other.
export function parseHeader(text) {
  if (typeof text !== "string") return null;
  const [version, ...tokens] = text.split(" ");
  if (version !== VERSION) return null;

  const pairs = {};
  for (const token of tokens) {
    const at = token.indexOf("=");
    if (at <= 0) return null;
    const name = token.slice(0, at);
    if (Object.hasOwn(pairs, name)) return null;
    pairs[name] = token.slice(at + 1);
  }

  const kind = pairs.kind;
  const names = kind === "invoke" ? INVOKE_FIELDS : kind === "control" ? CONTROL_FIELDS : null;
  if (!names || !FIELD.test(pairs.mac ?? "")) return null;
  if (Object.keys(pairs).length !== names.length + 2) return null;

  const fields = {};
  for (const name of names) {
    const value = pairs[HEADER_NAMES[name]];
    try {
      fields[name] = field({ [name]: value }, name);
    } catch {
      return null;
    }
    if (INTEGER_FIELDS.has(name)) fields[name] = Number(fields[name]);
  }
  if (Object.keys(pairs).some((name) => name !== "kind" && name !== "mac" && !FIELD_NAMES[name])) return null;

  return { kind, fields, mac: pairs.mac };
}

// Whether `parsed` (from parseHeader) is signed over `body` with `key`,
// compared in constant time.
export function verify(key, parsed, body) {
  let expected;
  try {
    expected = Buffer.from(mac(key, canonical(parsed.kind, parsed.fields, body)));
  } catch {
    return false;
  }
  const presented = Buffer.from(parsed.mac);
  return presented.length === expected.length && timingSafeEqual(presented, expected);
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
