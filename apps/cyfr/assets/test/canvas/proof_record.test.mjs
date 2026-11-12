// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const proof = fileURLToPath(new URL("../../../../../tests/canvas-proof/proof.mjs", import.meta.url));
const steps = [
  "two_canvases", "attention_moves", "switch", "written_canvas", "feed_chart", "app_over_canvas",
  "window_drag", "tile_narrows", "covered_windows", "frame_kept", "hidden_canvas",
  "validation_failures", "crash_fallback", "activation", "grant_control", "request",
  "rebound_control", "connection_allowlist", "policy", "disconnect", "failed_fire",
];

function record(hostClass) {
  const host = { name: "record-test", cpu: "test CPU", cores: 4, class: hostClass };
  return {
    date: "2026-11-12T00:00:00Z", host, adapter: "sqlite", viewport: "desktop",
    executed_runs: 0, feed_results: "fixed",
    browsers: { chromium: "test", firefox: "test", webkit: "test" },
    steps: Object.fromEntries(steps.map((step) => [step, {
      browsers: Object.fromEntries(["chromium", "firefox", "webkit"].map((browser) => [browser, {
        result: "held", observation: { executed: false },
      }])),
    }])),
    measurement: {
      date: "2026-11-12T00:00:00Z", host, viewport: "desktop", clock: "performance.now()",
      counts: { open: 20, validation: 20 },
      frame_open_ms: { p50: 50, p95: 50 }, validation_ms: { p50: 50, p95: 50 },
    },
  };
}

function check(t, value) {
  const dir = mkdtempSync(join(tmpdir(), "canvas-record-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const path = join(dir, "canvas-proof.json");
  writeFileSync(path, JSON.stringify(value));
  const result = spawnSync(process.execPath, [proof, "--check-record", path], { encoding: "utf8" });
  assert.ifError(result.error);
  return result;
}

// GitHub's 200 ms bound catches gross regressions across runner CPU models;
// the reference host retains the 100 ms canvas budget.
for (const [hostClass, budget] of [["reference", 100], ["github-hosted", 200]]) {
  for (const [key, label] of [["frame_open_ms", "frame open"], ["validation_ms", "validation"]]) {
    test(`${hostClass} ${label} holds at ${budget} ms and fails above it`, (t) => {
      const value = record(hostClass);
      value.measurement[key].p95 = budget;
      assert.equal(check(t, value).status, 0);
      value.measurement[key].p95 = budget + 0.1;
      value.measurement.budget_ms = { frame_open_ms: 1000, validation_ms: 1000 };
      const failed = check(t, value);
      assert.equal(failed.status, 1);
      assert.ok(failed.stderr.includes(`over its budget of ${budget} ms`), failed.stderr);
    });
  }
}

for (const hostClass of [undefined, "other-host"]) {
  test(`a record with host class ${hostClass} has no budget to pass`, (t) => {
    const result = check(t, record(hostClass));
    assert.equal(result.status, 1);
    assert.match(result.stderr, /no host class|has no budget/);
  });
}
