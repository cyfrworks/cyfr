// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
const {
  bytes, bytesFrom, check, mismatches, objectModels, sha256hex,
} = await import(process.env.HANDLE_PROOF_MODELS || "./models.mjs");

test("directory bytes decode from PostgreSQL and CYFR whole-row reads", () => {
  const genesis = Buffer.from('{"kind":"genesis"}');
  assert.deepEqual(bytesFrom(`\\x${genesis.toString("hex")}`), genesis);
  assert.deepEqual(bytesFrom(genesis.toString()), genesis);
  assert.deepEqual(bytesFrom(bytes(genesis)), genesis);
});

test("the proof holds every column of a native directory row through tamper and restore", async () => {
  const fixture = JSON.parse(readFileSync(new URL("../fixtures/directory_wire.json", import.meta.url)));
  const genesis = Buffer.from(fixture.entries["genesis-alice"]);
  const identifier = `per_${sha256hex(genesis)}`;
  const key = "setup:registry.directory.identity_log_entries";
  const now = Date.parse("2026-10-29T00:00:00Z");
  const row = {
    id: 1,
    identifier,
    seq: 0,
    kind: "genesis",
    entry_hash: `sha256:${sha256hex(genesis)}`,
    prev_hash: null,
    entry: `\\x${genesis.toString("hex")}`,
    request_id: null,
    request_digest: null,
    outcome: "accepted",
    outcome_body: null,
    bytes: genesis.length,
    inserted_at: "2026-10-29T00:00:00Z",
  };
  const seen = {
    identifier,
    origins: { a: "https://a.test", b: "https://b.test" },
    genesis: { a: genesis.toString("base64") },
    rows: { [key]: [structuredClone(row)] },
    w: { enroll: { name: "the enrollment", from: now, to: now } },
  };
  const model = objectModels(seen)[key]();
  assert.deepEqual(mismatches([row], model), []);
  assert.notDeepEqual(mismatches([{ ...row, id: "ile_old" }], model), []);
  assert.notDeepEqual(mismatches([{ ...row, id: Number.MAX_SAFE_INTEGER }], model), []);
  assert.notDeepEqual(mismatches([{ ...row, entry: genesis.toString() }], model), []);

  const result = await check([structuredClone(row)], model, {
    read: async () => [structuredClone(row)],
    state: async () => ({ rows: [structuredClone(row)], constraints: ["unchanged"] }),
    write: async (_index, field, value) => {
      row[field] = value;
      return { set: 1, role: "origin" };
    },
  });
  assert.deepEqual(result.failures, []);
  assert.equal(result.loops.length, Object.keys(row).length);
  assert.ok(result.loops.every((loop) => loop.named && loop.state_same && loop.held_again));

  // Read again at the end, the row is held to what setup read, and every
  // field's loop runs again.
  const heldModel = objectModels(seen)["held:registry.directory.identity_log_entries"]();
  assert.deepEqual(mismatches([row], heldModel), []);
  assert.notDeepEqual(mismatches([{ ...row, id: 2 }], heldModel), []);
  const heldResult = await check([structuredClone(row)], heldModel, {
    read: async () => [structuredClone(row)],
    state: async () => ({ rows: [structuredClone(row)], constraints: ["unchanged"] }),
    write: async (_index, field, value) => {
      row[field] = value;
      return { set: 1, role: "origin" };
    },
  });
  assert.deepEqual(heldResult.failures, []);
  assert.equal(heldResult.loops.length, Object.keys(row).length);
  assert.ok(heldResult.loops.every((loop) => loop.named && loop.state_same && loop.held_again));
});
