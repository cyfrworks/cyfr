// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The owner table without HTTP: versions compare lexicographically, backend
// definitions and credential masking follow their rules, and admission keeps
// each nonce for its window in a bounded cache.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  MAX_NONCES,
  NONCE_WINDOW_MS,
  Owners,
  Refusal,
  compareVersions,
  mask,
  secretValues,
  validateBackends,
} from "../owners.mjs";
import { FakeSpawner } from "./fake-spawner.mjs";

const CHILD = path.join(path.dirname(fileURLToPath(import.meta.url)), "fake-child.mjs");

const refusal = (code) => (err) => err instanceof Refusal && err.code === code;

test("versions compare by generation, then epoch", () => {
  assert.equal(compareVersions({ g: 1, e: 9 }, { g: 2, e: 1 }), -1);
  assert.equal(compareVersions({ g: 2, e: 1 }, { g: 2, e: 2 }), -1);
  assert.equal(compareVersions({ g: 2, e: 2 }, { g: 2, e: 2 }), 0);
  assert.equal(compareVersions({ g: 3, e: 1 }, { g: 2, e: 7 }), 1);
});

test("a backend definition is canonical once valid: env names sorted", () => {
  assert.deepEqual(validateBackends([{ name: "fs-1", command: "npx -y pkg", env_names: ["TOKEN", "API_KEY"] }]), [
    { name: "fs-1", command: "npx -y pkg", env_names: ["API_KEY", "TOKEN"] },
  ]);
  for (const bad of [
    [{ name: "fs", command: "x", env_names: [], extra: true }],
    [{ name: "-fs", command: "x", env_names: [] }],
    [{ name: "a".repeat(33), command: "x", env_names: [] }],
    [{ name: "fs", command: "x".repeat(4097), env_names: [] }],
    [{ name: "fs", command: "x\u0000y", env_names: [] }],
    [{ name: "fs", command: "x", env_names: ["A", "A"] }],
    [{ name: "fs", command: "x", env_names: ["SHELL"] }],
    [{ name: "fs", command: "x", env_names: ["A".repeat(65)] }],
    Array.from({ length: 17 }, (_, i) => ({ name: `b${i}`, command: "x", env_names: [] })),
  ]) {
    assert.throws(() => validateBackends(bad), refusal("bad_request"), JSON.stringify(bad).slice(0, 80));
  }
});

test("credential values of 8 bytes or more are masked, whole and after their scheme; literal names are not", () => {
  const secrets = secretValues({
    a: { TOKEN: "sk-live-abcdefgh", AUTH: "Bearer tok-12345678", PIN: "1234567", NODE_ENV: "production" },
    b: { OTHER: "sk-live-abcdefgh-longer" },
  });
  assert.deepEqual(secrets, ["sk-live-abcdefgh-longer", "Bearer tok-12345678", "sk-live-abcdefgh", "tok-12345678"]);
  assert.deepEqual(
    mask({ text: "sk-live-abcdefgh-longer then tok-12345678", list: ["1234567", "production"], n: 3, [`k-sk-live-abcdefgh`]: null }, secrets),
    { text: "[REDACTED] then [REDACTED]", list: ["1234567", "production"], n: 3, "k-[REDACTED]": null },
  );
});

test("admission keeps each nonce for its window and refuses once the cache is full", async () => {
  let clock = 1_000_000;
  const owners = new Owners({ spawner: new FakeSpawner(), now: () => clock, leaseCheckMs: 60_000 });
  const base = { athanor: "ath_1", server: "mcp_1", g: 1, e: 1 };
  try {
    const synced = await owners.sync({
      ...base,
      leaseMs: 60_000,
      backends: validateBackends([{ name: "b", command: `node ${CHILD} well-behaved`, env_names: [] }]),
      openEnv: () => ({ b: {} }),
    });
    assert.equal(synced.status, "running");

    owners.admit({ ...base, ts: clock, nonce: "n0" });
    assert.throws(() => owners.admit({ ...base, ts: clock, nonce: "n0" }), refusal("replay"));

    for (let i = 1; i < MAX_NONCES; i++) owners.admit({ ...base, ts: clock, nonce: `n${i}` });
    assert.throws(() => owners.admit({ ...base, ts: clock, nonce: "one-more" }), (err) => refusal("nonce_cache_full")(err) && err.status === 503);

    // Past their window the nonces are pruned, and admission resumes.
    clock += NONCE_WINDOW_MS + 1;
    owners.renew([{ athanor: "ath_1", server: "mcp_1", e: 1 }], 1, 60_000);
    owners.admit({ ...base, ts: clock, nonce: "one-more" });
    assert.equal(owners.get("ath_1", "mcp_1").nonces.size, 1);
  } finally {
    await owners.close();
  }
});
