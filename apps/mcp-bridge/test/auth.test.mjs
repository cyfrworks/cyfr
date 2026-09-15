// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The bridge's half of the authentication reproduces every shared vector:
// root texts, keys, canonical strings, headers, header parsing and sealed
// values; a tampered body, key or lifetime does not verify or open; a valid
// field is accepted, and an invalid field, root text or header is refused.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as auth from "../auth.mjs";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const V = JSON.parse(readFileSync(path.join(DIR, "..", "..", "..", "tests", "fixtures", "bridge_auth.json"), "utf8"));
const root = Buffer.from(V.root_hex, "hex");
const owner = V.owner;
const ownerKey = auth.ownerKey(root, owner);
const invoke = { ...owner, boot: V.invoke.boot, ts: V.invoke.ts, nonce: V.invoke.nonce };
const control = {
  generation: V.control.generation,
  seq: V.control.seq,
  cyfr_boot: V.control.cyfr_boot,
  boot: V.control.boot,
  ts: V.control.ts,
};

test("every valid root text decodes to the root, and every invalid one is refused", () => {
  for (const text of V.root_text.valid) assert.deepEqual(auth.decodeRoot(text), root, text);
  for (const text of V.root_text.invalid) assert.throws(() => auth.decodeRoot(text), auth.InvalidField, text);
  assert.throws(() => auth.decodeRoot(undefined), auth.InvalidField);
});

test("keys derive as the vectors say", () => {
  assert.equal(auth.controlKey(root).toString("hex"), V.control_key_hex);
  assert.equal(auth.sealKey(root).toString("hex"), V.seal_key_hex);
  assert.equal(ownerKey.toString("hex"), V.owner_key_hex);
});

test("an invoke's canonical string and header match, and the header verifies", () => {
  assert.equal(auth.canonical("invoke", invoke, V.invoke.body), V.invoke.canonical);
  assert.equal(auth.invokeHeader(ownerKey, invoke, V.invoke.body), V.invoke.header);

  const parsed = auth.parseHeader("invoke", V.invoke.header);
  assert.equal(parsed.kind, "invoke");
  assert.deepEqual(parsed.fields, invoke);
  assert.equal(parsed.bodyHash, V.invoke.canonical.split("\n").at(-1));
  assert.ok(auth.verify(ownerKey, parsed));
  assert.ok(auth.bodyMatches(parsed, V.invoke.body));
  assert.ok(!auth.bodyMatches(parsed, V.invoke.body + " "));
  assert.ok(!auth.verify(auth.ownerKey(root, { ...owner, epoch: owner.epoch + 1 }), parsed));

  // The MAC covers the body hash the header names: another hash does not verify.
  assert.ok(!auth.verify(ownerKey, { ...parsed, bodyHash: auth.bodyHash(V.invoke.body + " ") }));
});

test("a control message's canonical string and header match, and the header verifies", () => {
  const key = auth.controlKey(root);
  assert.equal(auth.canonical("control", control, V.control.body), V.control.canonical);
  assert.equal(auth.controlHeader(key, control, V.control.body), V.control.header);

  const parsed = auth.parseHeader("control", V.control.header);
  assert.equal(parsed.kind, "control");
  assert.deepEqual(parsed.fields, control);
  assert.ok(auth.verify(key, parsed));
  assert.ok(auth.bodyMatches(parsed, V.control.body));
  assert.ok(!auth.verify(ownerKey, parsed));
});

test("every accepted header parses as its kind to its fields, body hash and MAC", () => {
  for (const { kind, header, fields, body_hash: bodyHash, mac } of V.header_parse.accepted) {
    assert.deepEqual(auth.parseHeader(kind, header), { kind, fields, bodyHash, mac }, header);
  }
});

test("every malformed header is refused as its kind", () => {
  for (const { kind, header } of V.header_parse.malformed) {
    assert.equal(auth.parseHeader(kind, header), null, JSON.stringify(header));
  }
  assert.equal(auth.parseHeader("other", V.invoke.header), null);
  assert.equal(auth.parseHeader(undefined, V.invoke.header), null);
});

test("a sealed environment matches, opens for its owner and lifetime only", () => {
  const key = auth.sealKey(root);
  const iv = Buffer.from(V.seal.iv_hex, "hex");
  assert.equal(auth.seal(key, owner, V.seal.boot, Buffer.from(V.seal.plaintext), iv), V.seal.sealed);
  assert.equal(auth.open(key, owner, V.seal.boot, V.seal.sealed).toString(), V.seal.plaintext);
  assert.equal(auth.open(key, owner, "bb_other", V.seal.sealed), null);
  assert.equal(auth.open(key, { ...owner, epoch: owner.epoch + 1 }, V.seal.boot, V.seal.sealed), null);
});

test("every valid field is accepted and every invalid field is refused", () => {
  for (const { field, value } of V.valid_fields) {
    assert.doesNotThrow(() => auth.canonical("invoke", { ...invoke, [field]: value }, "{}"), `${field}=${value}`);
  }
  for (const { field, value } of V.invalid_fields) {
    assert.throws(() => auth.canonical("invoke", { ...invoke, [field]: value }, "{}"), auth.InvalidField, `${field}=${value}`);
  }
});
