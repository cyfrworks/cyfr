// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The bridge's half of the authentication reproduces every shared vector:
// keys, canonical strings, headers and sealed values; a tampered body, key
// or lifetime does not verify or open; an invalid field is refused.

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

test("keys derive as the vectors say", () => {
  assert.equal(auth.controlKey(root).toString("hex"), V.control_key_hex);
  assert.equal(auth.sealKey(root).toString("hex"), V.seal_key_hex);
  assert.equal(ownerKey.toString("hex"), V.owner_key_hex);
});

test("an invoke's canonical string and header match, and the header verifies", () => {
  assert.equal(auth.canonical("invoke", invoke, V.invoke.body), V.invoke.canonical);
  assert.equal(auth.invokeHeader(ownerKey, invoke, V.invoke.body), V.invoke.header);

  const parsed = auth.parseHeader(V.invoke.header);
  assert.equal(parsed.kind, "invoke");
  assert.deepEqual(parsed.fields, invoke);
  assert.ok(auth.verify(ownerKey, parsed, V.invoke.body));
  assert.ok(!auth.verify(ownerKey, parsed, V.invoke.body + " "));
  assert.ok(!auth.verify(auth.ownerKey(root, { ...owner, epoch: owner.epoch + 1 }), parsed, V.invoke.body));
});

test("a control message's canonical string and header match, and the header verifies", () => {
  const key = auth.controlKey(root);
  assert.equal(auth.canonical("control", control, V.control.body), V.control.canonical);
  assert.equal(auth.controlHeader(key, control, V.control.body), V.control.header);

  const parsed = auth.parseHeader(V.control.header);
  assert.equal(parsed.kind, "control");
  assert.deepEqual(parsed.fields, control);
  assert.ok(auth.verify(key, parsed, V.control.body));
  assert.ok(!auth.verify(ownerKey, parsed, V.control.body));
});

test("a header that is not exactly one well-formed v1 header does not parse", () => {
  const good = V.invoke.header;
  for (const bad of [
    good.replace("v1 ", "v2 "),
    `${good} extra=1`,
    good.replace(" nonce=n_7d3e9a", ""),
    good.replace("gen=3", "gen=03"),
    good.replace("epoch=7", "epoch=7 epoch=8"),
    good.replace("kind=invoke", "kind=other"),
  ]) {
    assert.equal(auth.parseHeader(bad), null, bad);
  }
});

test("a sealed environment matches, opens for its owner and lifetime only", () => {
  const key = auth.sealKey(root);
  const iv = Buffer.from(V.seal.iv_hex, "hex");
  assert.equal(auth.seal(key, owner, V.seal.boot, Buffer.from(V.seal.plaintext), iv), V.seal.sealed);
  assert.equal(auth.open(key, owner, V.seal.boot, V.seal.sealed).toString(), V.seal.plaintext);
  assert.equal(auth.open(key, owner, "bb_other", V.seal.sealed), null);
  assert.equal(auth.open(key, { ...owner, epoch: owner.epoch + 1 }, V.seal.boot, V.seal.sealed), null);
});

test("every invalid field is refused", () => {
  for (const { field, value } of V.invalid_fields) {
    assert.throws(() => auth.canonical("invoke", { ...invoke, [field]: value }, "{}"), auth.InvalidField, field);
  }
});
