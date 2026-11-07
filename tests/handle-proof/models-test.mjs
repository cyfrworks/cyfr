// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
const {
  bytes, bytesFrom, check, entryOf, mismatches, objectModels, sha256hex,
} = await import(process.env.HANDLE_PROOF_MODELS || "./models.mjs");

test("directory bytes decode from PostgreSQL and CYFR whole-row reads", () => {
  const genesis = Buffer.from('{"kind":"genesis"}');
  assert.deepEqual(bytesFrom(`\\x${genesis.toString("hex")}`), genesis);
  assert.deepEqual(bytesFrom(genesis.toString()), genesis);
  assert.deepEqual(bytesFrom(bytes(genesis)), genesis);
});

test("the proof holds every column of a log's rows through tamper and restore", async () => {
  const fixture = JSON.parse(readFileSync(new URL("../fixtures/directory_wire.json", import.meta.url)));
  const genesis = Buffer.from(fixture.entries["genesis-alice"]);
  const added = Buffer.from(fixture.entries["add-device"]);
  const identifier = `per_${sha256hex(genesis)}`;
  const key = "setup:registry.directory.entries[a]";
  const now = Date.parse("2026-11-07T00:00:00Z");
  const row = (seq, kind, entry, prev) => ({
    identifier,
    seq,
    kind,
    entry_hash: `sha256:${sha256hex(entry)}`,
    prev_hash: prev,
    entry: `\\x${entry.toString("hex")}`,
    bytes: entry.length,
    inserted_at: "2026-11-07T00:00:00+00:00",
  });
  const rows = [row(0, "genesis", genesis, null), row(1, "add_key", added, `sha256:${sha256hex(genesis)}`)];
  const listed = entryOf(rows[1].entry).parsed.key;
  const seen = {
    identifier,
    origins: { a: "https://a.test", b: "https://b.test" },
    credentials: { a: { kid: listed.kid, credentialIdB64url: listed.credential_id } },
    rows: { [key]: structuredClone(rows) },
    w: { make: { name: "the account's making", from: now, to: now } },
    at: {},
  };
  // The fixture's genesis names its own directory, where the run's names
  // registry.test, so the model refuses it there; held to its own bytes,
  // every other field holds.
  const model = objectModels(seen)[key]();
  assert.deepEqual(mismatches(rows, model).map((m) => m.field), ["[0].entry"]);
  model[0].entry = { ...model[0].entry, value: rows[0].entry };
  assert.deepEqual(mismatches(rows, model), []);
  assert.notDeepEqual(mismatches([{ ...rows[0], seq: 7 }, rows[1]], model), []);
  assert.notDeepEqual(mismatches([rows[0], { ...rows[1], prev_hash: rows[1].entry_hash }], model), []);
  assert.notDeepEqual(mismatches([rows[0], { ...rows[1], entry: rows[0].entry }], model), []);

  const stored = structuredClone(rows);
  const result = await check(structuredClone(stored), model, {
    read: async () => structuredClone(stored),
    state: async () => ({ rows: structuredClone(stored), constraints: ["unchanged"] }),
    write: async (i, field, value) => {
      stored[i][field] = value;
      return { set: 1, role: "origin" };
    },
  });
  assert.deepEqual(result.failures, []);
  assert.equal(result.loops.length, Object.keys(rows[0]).length * 2);
  assert.ok(result.loops.every((loop) => loop.named && loop.state_same && loop.held_again));
});
