// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The tincture proof, run in the official Playwright image by run.sh against
// a `cyfr` release holding proof-game, private, as the Locus builds image
// built it and the publish check admitted it. For every browser the image
// ships, the fixture's person opens proof-game from the Prism shell:
//
//   1. the frame the shell creates holds exactly what the declaration asks
//      (`allow-scripts allow-pointer-lock`, `fullscreen; autoplay`, never
//      `allow-same-origin`) at the version's /_s/ address;
//   2. the game runs: Rapier steps in its inline worker, the scene renders
//      (or the browser has no WebGL, which is recorded), the sound decodes
//      once, and the game says it is ready;
//   3. one save: `cyfr.invoke` of the seeded catalyst the game declares,
//      admitted past the frame's own checks and answered by the gate;
//   4. the second open is served from the browser's cache: none of its
//      assets reaches the network unless as a conditional request;
//   5. frame-open and asset-fetch latencies over OPENS warm opens (one
//      signed-in browser, the shell closing and launching the game again)
//      and OPENS cold opens (a new browser context each time).
//
// Frame-open is the time from the person's launch in the shell to the
// game's ready: its first rendered frame after physics stepped and the sound
// decoded. Asset-fetch is each /_s/ resource's duration as the frame's
// Resource Timing reports it.
//
// Usage: node proof.mjs SERVER_URL SEGMENT COOKIE OUT_DIR [OPENS]

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  BROWSERS, SITE, chromium, closeFrame, firefox, launch, openShell, percentiles, signedIn, sleep,
  startProxy, waitFor, webkit,
} from "../browser/lib.mjs";

const TYPES = { chromium, firefox, webkit };
const NAME = "proof-game";
const failures = [];
const check = (condition, what, detail) => {
  if (!condition) failures.push({ what, detail });
  console.log(`${condition ? "ok" : "FAIL"}: ${what}${condition ? "" : ` — ${JSON.stringify(detail)}`}`);
  return condition;
};

const readGame = (frame) => frame.evaluate(() => {
  const g = window.__game;
  return g && {
    readyAt: g.readyAt, steps: g.steps, frames: g.frames, engine: g.engine, renderer: g.renderer,
    audio: g.audio, errors: g.errors, saved: g.saved,
  };
});

// One open from the picker to the game's ready.
async function open(page, proxy) {
  const mark = proxy.seen.length;
  const launchedAt = Date.now();
  const { frame, attributes } = await launch(page, NAME);
  const game = await waitFor(async () => {
    const g = await readGame(frame).catch(() => null);
    return g && (g.readyAt || (g.errors && g.errors.length && Date.now() - launchedAt > 20_000)) ? g : null;
  }, { timeoutMs: 60_000, what: "the game's ready" });
  const resources = (await frame.evaluate(() => window.__game.resources()))
    .filter((r) => r.name.includes("/_s/"));
  return {
    frame, attributes, game,
    openMs: game.readyAt ? game.readyAt - launchedAt : null,
    resources,
    requests: proxy.seen.slice(mark).filter((r) => new URL(r.url).pathname.startsWith("/_s/")),
  };
}

async function run(name, base, proxy, segment, cookie, opens) {
  const browser = await TYPES[name].launch({ proxy: { server: `http://127.0.0.1:${proxy.address().port}` } });
  const record = { version: browser.version() };
  try {
    // ---- warm: one signed-in browser, the game opened again and again ----
    proxy.seen = [];
    const context = await signedIn(browser, base, cookie);
    const page = await context.newPage();
    await openShell(page, base, segment, NAME);

    const first = await open(page, proxy);
    const a = first.attributes;
    const sandbox = (a.sandbox || "").split(/\s+/).sort();
    check(JSON.stringify(sandbox) === JSON.stringify(["allow-pointer-lock", "allow-scripts"]),
      `${name}: the frame's sandbox is the declaration's`, a.sandbox);
    check((a.allow || "").split(/;\s*/).sort().join(";") === "autoplay;fullscreen",
      `${name}: the frame's allow is the declaration's`, a.allow);
    check(a.src.startsWith("/_s/") && a.src.endsWith(`/local/${NAME}/1.0.0/dist/index.html`),
      `${name}: the frame's page is the private version's, under its asset credential`, a.src.replace(/^\/_s\/[^/]+/, "/_s/…"));
    const g = first.game;
    check(g.readyAt && g.steps > 0, `${name}: Rapier stepped in the inline worker and the game was ready`, g);
    check(g.audio && g.audio.decoded, `${name}: the sound decoded once`, g.audio);
    record.first = { openMs: first.openMs, renderer: g.renderer, engine: g.engine, audio: g.audio, errors: g.errors };

    // The save: one invocation of the declared catalyst.
    const saved = await first.frame.evaluate(() => window.__game.save());
    const frameRefusal = !saved.ok && (saved.code === "unauthenticated" || /frame|declare/i.test(saved.message || ""));
    check(saved.ok || (saved.code && !frameRefusal),
      `${name}: the save passed the frame's checks and the gate answered it`, saved);
    record.save = saved;

    // Pointer lock and fullscreen, from a gesture inside the frame.
    await first.frame.click("#stage", { position: { x: 400, y: 300 } }).catch(() => {});
    await first.frame.press("body", "f").catch(() => {});
    await sleep(300);
    record.gestures = await first.frame.evaluate(() => ({
      pointerLock: !!document.pointerLockElement, fullscreen: !!document.fullscreenElement,
    }));
    console.log(`${name}: save ${JSON.stringify(saved)}, gestures ${JSON.stringify(record.gestures)}`);
    await first.frame.evaluate(async () => {
      if (document.pointerLockElement) document.exitPointerLock();
      if (document.fullscreenElement) await document.exitFullscreen().catch(() => {});
    });
    await sleep(300);
    await closeFrame(page, a.id);

    const warm = [first];
    for (let i = 1; i < opens; i++) {
      const next = await open(page, proxy);
      warm.push(next);
      await closeFrame(page, next.attributes.id);
    }
    const second = warm[1];
    const assets = second.requests.filter((r) => !r.url.endsWith("/dist/index.html"));
    // WebKit's network cache stores no media response (audio, video), so
    // it fetches the sound again whatever the headers say; every other
    // asset must come from the cache or be revalidated.
    const media = (r) => /\.(wav|mp3|ogg|oga|opus|flac|m4a)$/.test(new URL(r.url).pathname);
    const fetched = assets.filter((r) => !media(r) && !(r.conditional || r.status === 304));
    check(second.game.readyAt && fetched.length === 0,
      `${name}: the second open's assets (media aside) came from the browser's cache`,
      assets.map((r) => ({ path: new URL(r.url).pathname.replace(/^\/_s\/[^/]+/, "/_s/…"), status: r.status, conditional: r.conditional })));
    record.second = {
      document: second.requests.filter((r) => r.url.endsWith("/dist/index.html")).map((r) => ({ status: r.status, conditional: r.conditional })),
      assets: assets.map((r) => ({ path: new URL(r.url).pathname.split("/").slice(-2).join("/"), status: r.status, conditional: r.conditional })),
    };
    await context.close();

    // ---- cold: a new browser context for each open ----
    const cold = [];
    for (let i = 0; i < opens; i++) {
      const fresh = await signedIn(browser, base, cookie);
      const freshPage = await fresh.newPage();
      await openShell(freshPage, base, segment, NAME);
      cold.push(await open(freshPage, proxy));
      await fresh.close();
    }

    const ms = (list) => list.map((o) => o.openMs).filter((v) => v !== null);
    const durations = (list) => list.flatMap((o) => o.resources.map((r) => r.duration));
    record.frameOpen = { warm: percentiles(ms(warm.slice(1))), cold: percentiles(ms(cold)) };
    record.assetFetch = { warm: percentiles(durations(warm.slice(1))), cold: percentiles(durations(cold)) };
    check(record.frameOpen.warm.n >= opens - 1 && record.frameOpen.cold.n >= opens,
      `${name}: every open reached the game's ready`, record.frameOpen);
  } finally {
    await browser.close();
  }
  return record;
}

const round = (v) => (v === null ? "—" : Math.round(v));

async function main() {
  const [server, segment, cookie, outDir, opensArg] = process.argv.slice(2);
  if (!server || !segment || !cookie || !outDir) {
    console.error("usage: node proof.mjs SERVER_URL SEGMENT COOKIE OUT_DIR [OPENS]");
    process.exit(64);
  }
  const opens = Number(opensArg || 50);
  mkdirSync(outDir, { recursive: true });
  const proxy = await startProxy(server);
  const base = `http://${SITE}:${new URL(server).port || 80}`;
  const record = {};
  for (const name of BROWSERS) {
    console.log(`== ${name}`);
    record[name] = await run(name, base, proxy, segment, cookie, opens);
  }
  proxy.close();
  writeFileSync(join(outDir, "tincture-proof.json"), JSON.stringify(record, null, 2));

  const row = (label, pick) =>
    `| ${label} | ${BROWSERS.map((b) => {
      const s = pick(record[b]);
      return `${round(s.p50)} / ${round(s.p95)} / ${round(s.p99)} (n=${s.n})`;
    }).join(" | ")} |`;
  const table = [
    `| ms, p50 / p95 / p99 | ${BROWSERS.map((b) => `${b} ${record[b].version}`).join(" | ")} |`,
    `|---|${BROWSERS.map(() => "---|").join("")}`,
    row("frame-open, warm", (r) => r.frameOpen.warm),
    row("frame-open, cold", (r) => r.frameOpen.cold),
    row("asset-fetch, warm", (r) => r.assetFetch.warm),
    row("asset-fetch, cold", (r) => r.assetFetch.cold),
  ];
  writeFileSync(join(outDir, "tincture-proof.md"), table.join("\n") + "\n");
  console.log(table.join("\n"));
  for (const b of BROWSERS) {
    console.log(`${b}: renderer ${record[b].first.renderer}, engine ${record[b].first.engine}, ` +
      `gestures ${JSON.stringify(record[b].gestures)}, save ${JSON.stringify(record[b].save)}, ` +
      `second open ${JSON.stringify(record[b].second)}`);
  }

  if (failures.length) {
    console.error(`FAIL: ${failures.length} check(s) failed`);
    process.exit(1);
  }
  console.log("ok: the tincture proof passed in every browser");
}

main().catch((error) => {
  console.error(`FAIL: ${error.stack || error}`);
  process.exit(1);
});
