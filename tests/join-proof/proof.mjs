// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The join proof, run in the official Playwright image by run.sh against
// `cyfr` releases behind the harness's HTTPS front (README.md): the
// person's home A, the hub H, the directories dir.test (A's) and
// dir2.test (H's), and a fresh installation A2 the person restores onto.
// Each step is one row per browser of the record; the proof fails when a
// row does not hold, and stops at the first row a later one rests on.
//
// Chromium runs every step, and the glass's steps once more at a 720×720
// touch viewport. Firefox and WebKit offer no virtual authenticator, so
// they run the sign-in at H, the carry between the homes and a second
// browser profile; each fresh confirmation those need is given on a glass
// paired at A in Chromium (common.mjs, steps.mjs).
//
// Usage: node proof.mjs HOMES_FILE OUT_DIR

import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { launchBrowser, startProxy } from "../browser/lib.mjs";
import {
  A, BROWSERS, ask, crossHome, crossSiteHeld, dumpPages, homes, outDir, record, redact, row, rows, secrets, setUpHome,
  setUpHub, signIn,
} from "./common.mjs";
import { rest } from "./steps.mjs";

async function main(proxy) {
  const chromium = await launchBrowser("chromium", proxy);
  record.versions = { chromium: chromium.version() };
  const home = await setUpHome(chromium, proxy);
  if (!home.held) return;
  const [hubHeld, hub] = await setUpHub(home.identifier);
  if (!hubHeld) return;

  // Chromium: the sign-in by the person's own passkey at A.
  const first = await signIn(chromium, "chromium", proxy, { home: A, identifier: home.identifier, passkeysFrom: home.desk });
  if (!first.held) return;
  if (!(await resolution(home.identifier))) return;

  // Firefox and WebKit: signed in at A by the fixture's door, each
  // confirmation given on the glass in Chromium; then a second profile.
  // They run one at a time, and the requests the proxy sees meanwhile are
  // theirs but for the Chromium glass at A, whose requests never cross
  // homes: each browser's cross-home requests are its window's.
  const windows = {};
  for (const name of BROWSERS.filter((b) => b !== "chromium")) {
    const from = proxy.seen.length;
    const browser = await launchBrowser(name, proxy);
    record.versions[name] = browser.version();
    try {
      for (const step of ["sign_in", "second_profile"]) {
        const { cookie } = await ask({ op: "a_cookie" }, { secret: true });
        secrets.push(cookie);
        const run = await signIn(browser, name, proxy, { home: A, identifier: home.identifier, glass: home.glass, cookie, step });
        await run.context.close();
        if (!run.held) break;
      }
    } finally {
      await browser.close();
      windows[name] = [from, proxy.seen.length];
    }
  }

  // Chromium's own second profile.
  const second = await signIn(chromium, "chromium", proxy, { home: A, identifier: home.identifier, passkeysFrom: home.desk, step: "second_profile" });
  await second.context.close();

  await rest(chromium, proxy, { home, hub, hubPage: first.page, hubContext: first.context });
  await chromium.close();

  // Every request one home received from another home's page, in every
  // browser and every step, was labelled cross-site.
  const outside = (i) => Object.values(windows).every(([start, end]) => i < start || i >= end);
  const seenBy = { chromium: proxy.seen.filter((_, i) => outside(i)) };
  for (const [name, [start, end]] of Object.entries(windows)) seenBy[name] = proxy.seen.slice(start, end);
  record.cross_site = {};
  for (const [name, seen] of Object.entries(seenBy)) {
    const cross = crossSiteHeld(seen);
    const byRoute = {};
    for (const r of crossHome(seen)) byRoute[`${r.from} → ${r.to}`] = (byRoute[`${r.from} → ${r.to}`] || 0) + 1;
    record.cross_site[name] = { requests: cross.requests, wrong: cross.wrong, by_route: byRoute };
    row("cross_site", name, cross.held,
      "every cross-home request the browser made in the run carried sec-fetch-site: cross-site", record.cross_site[name]);
  }
}

// H reads the person at the directory their genesis names, dir.test,
// though H enrolls its own people at dir2.test; and neither home holds a
// list of the person's homes, in a table or in the pages' storage.
async function resolution(identifier) {
  const atDir = (await ask({ op: "dir_seen", directory: "dir.test" })).paths;
  const atDir2 = (await ask({ op: "dir_seen", directory: "dir2.test" })).paths;
  const tables = { a: (await ask({ op: "tables", cell: "a" })).tables, h: (await ask({ op: "tables", cell: "h" })).tables };
  const listLike = (names) => names.filter((name) => /connection|saved_home|navigation|visited|bookmark/.test(name));
  record.resolution = {
    read_at_dir: atDir.filter((path) => path.includes(identifier)).length,
    read_at_dir2: atDir2.filter((path) => path.includes(identifier)).length,
    list_tables: { a: listLike(tables.a), h: listLike(tables.h) },
  };
  return row("resolution", "chromium",
    record.resolution.read_at_dir > 0 && record.resolution.read_at_dir2 === 0 &&
      record.resolution.list_tables.a.length === 0 && record.resolution.list_tables.h.length === 0,
    "H resolves the person at dir.test, which their genesis names, though H's own directory is dir2.test; neither home keeps a list of the homes a person visits",
    record.resolution);
}

let proxy;
try {
  proxy = await startProxy(null, { homes });
} catch (error) {
  console.error(`FAIL: ${error.message.split("\n")[0]}`);
  process.exit(1);
}

let failure = null;
try {
  await main(proxy);
} catch (error) {
  failure = redact(error.stack || String(error));
  console.error(`FAIL: ${failure}`);
  await dumpPages().catch(() => null);
} finally {
  proxy.close();
}

const STEPS = JSON.parse(process.env.JOIN_PROOF_STEPS || "null") || [
  ["home", ["chromium"]], ["hub", ["chromium"]], ["sign_in", BROWSERS], ["resolution", ["chromium"]],
  ["second_profile", BROWSERS],
  ["crafted", ["chromium"]], ["copied_session", ["chromium"]], ["dropped_callback", ["chromium"]],
  ["closed_hops", ["chromium"]], ["forged_completion", ["chromium"]], ["h_passkey", ["chromium"]],
  ["a_passkey_at_h", ["chromium"]], ["phone", ["chromium"]], ["renewal", ["chromium"]], ["thread", ["chromium"]],
  ["removal", ["chromium"]], ["rotate", ["chromium"]], ["recertify", ["chromium"]], ["tabs", ["chromium"]],
  ["lost_home", ["chromium"]], ["restore", ["chromium"]], ["retired", ["chromium"]], ["admin_again", ["chromium"]],
  ["viewport", ["chromium"]], ["directory_down", ["chromium"]], ["cross_site", BROWSERS],
];
const outcome = (step, browser) => {
  const found = rows.filter((r) => r.step === step && r.browser === browser);
  if (!found.length) return "not reached";
  return found.every((r) => r.held) ? "held" : "FAILED";
};
const columns = ["chromium", "firefox", "webkit"].filter((b) => BROWSERS.includes(b));
const cell = (step, browsers, browser) => (browsers.includes(browser) ? outcome(step, browser) : "Chromium only");
writeFileSync(join(outDir, "join-proof.json"), redact(JSON.stringify({ versions: record.versions, rows, record, failure }, null, 2)));
const table = [
  `| step | ${columns.map((b) => `${b} ${(record.versions || {})[b] || ""}`.trim()).join(" | ")} |`,
  `|---|${columns.map(() => "---").join("|")}|`,
  ...STEPS.map(([step, browsers]) => `| ${step} | ${columns.map((b) => cell(step, browsers, b)).join(" | ")} |`),
];
writeFileSync(join(outDir, "join-proof.md"), table.join("\n") + "\n");
console.log(table.join("\n"));
const unheld = STEPS.some(([step, browsers]) => browsers.some((b) => columns.includes(b) && outcome(step, b) !== "held"));
if (failure || unheld) {
  console.error("FAIL: a step of the join proof did not hold");
  process.exit(1);
}
console.log("ok: every step held");
