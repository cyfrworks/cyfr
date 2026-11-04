// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { mkdtempSync, readdirSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

// Execute the proof's own row decisions without starting its browsers.
function functions(path, names, context) {
  const source = readFileSync(new URL(path, import.meta.url), "utf8");
  const text = names.map((name) => {
    const start = source.indexOf(`async function ${name}(`);
    assert.notEqual(start, -1, `${name} exists`);
    const end = source.indexOf("\n}", start);
    return source.slice(start, end + 2);
  }).join("\n");
  return runInNewContext(`${text}\n({${names.join(",")}})`, context);
}

for (const close of [4401, null, "timed out", "challenge refused"]) {
  test(`identity requires the foreign home's refusal, close=${close}`, async () => {
    const context = {
      C: "https://c.test", proxyPort: 1, HANDHELD: { viewport: { width: 720, height: 720 } },
      record: {}, unmet: () => [], sleep: () => new Promise(() => {}),
      channel: () => ({ opened: new Promise(() => {}), closed: Promise.resolve(close), log: [], close() {} }),
      row: (_step, held) => held,
    };
    const proof = functions("../identity-proof/proof.mjs", ["connectWith", "handheldElsewhere"], context);
    const hand = {
      device: { certificate: { audience: "https://a.test" } },
      context: { close: async () => {} }, measured: {},
      facts: { paired_subject: "local", renewed_after_rotation: true, listed_after_rotation: true },
    };
    const held = await proof.handheldElsewhere(hand);
    assert.equal(held, close === 4401, "a timeout, a transport close or a local refusal is no refusal from C");
  });
}

function page() {
  let url = "https://h.test/a/me/settings";
  const element = { selectOption: async () => {}, fill: async () => {}, click: async () => {} };
  element.locator = () => element;
  element.isVisible = async () => true;
  return {
    goto: async (target) => { url = target; }, url: () => url, close: async () => {}, locator: () => element,
    waitForSelector: async () => ({ getAttribute: async () => "cnr_pending" }),
  };
}

for (const step of ["removal", "lost_home"]) {
  test(`join ${step} cannot call a dead terminal usable from its standing row`, async (t) => {
    const cliHome = mkdtempSync(join(tmpdir(), "cyfr-proof-no-device-"));
    t.after(() => rmSync(cliHome, { recursive: true, force: true }));
    assert.equal(existsSync(join(cliHome, ".cyfr", "devices")), false);
    const stop = new Error("the row was recorded");
    let held;
    const hubPage = page();
    const context = {
      URL, H: "https://h.test", A2: "https://a2.test", hubAthanor: "me", createHash, randomBytes,
      // The real filesystem: the row reads the command line's own directory.
      existsSync, readdirSync, join,
      layer: "#system-layer-dialog", record: {},
      settingsAt: (base) => `${base}/a/me/settings`, shellAt: (base) => `${base}/a/me/canvas`,
      open: async () => {}, connected: async () => {}, ready: async () => {},
      authenticatorWith: async () => {}, credentialsFor: async () => [], passkeySignIn: async () => {},
      pressInLayer: async () => {}, freshContext: async () => ({ newPage: async () => page() }),
      ask: async (request) => {
        switch (request.op) {
          case "h_person": return { user_id: "usr_person", threads: ["pair"] };
          case "remove": return { ok: true };
          case "post": return request.thread_id === "household" ? { refused: true } : { message_id: "msg_pair" };
          case "paired": return { paired: [{ id: "pcl_terminal", standing: "active" }] };
          case "a_down": return { down: true };
          default: throw new Error(`unexpected fixture request ${request.op}`);
        }
      },
      row: (name, _browser, value) => {
        if (name === step) { held = value; throw stop; }
        return value;
      },
    };
    context.atHub = (identifier) => context.ask({ op: "h_person", identifier });
    const proof = functions("../join-proof/steps.mjs",
      ["signedOut", "terminalStanding", "commandLineUsable", "removal", "restore"], context);
    const state = {
      identifier: "per_person", terminal: { cliHome, clientId: "pcl_terminal" },
      hub: { household: "household" }, pair: "pair", hubPage,
      hubContext: { newPage: async () => page() },
      home: { desk: page(), settings: "https://a.test/a/me/settings" },
    };
    try {
      if (step === "removal") await proof.removal(state);
      else await proof.restore({}, state);
    } catch (error) { if (error !== stop) throw error; }
    assert.equal(held, false, "an active database row cannot prove a terminal with no key or running session usable");
  });
}
