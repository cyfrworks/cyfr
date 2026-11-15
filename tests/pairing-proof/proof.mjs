// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The pairing proof, run in the official Playwright image by run.sh
// against `cyfr` releases behind the harness's HTTPS front (README.md):
// the directory dir.test, which serves the account pages, and two CYFRs,
// x.test and y.test, both set up by the person in the browser. Chromium
// alone, since a passkey is made and used by its virtual authenticator
// (../browser/account.mjs). The devices are test devices
// (../browser/device.mjs), clients of the CYFRs' device channel this
// process drives frame by frame.
// Each step is one row of the record; the proof fails when a row does not
// hold, and stops at the first row a later one rests on.
//
// The CYFRs' part of a step (their setup tokens, what each holds) is
// run.sh's, asked for through OUT_DIR (`ask-N.json`, answered
// `answer-N.json`). The asks that carry a setup token are deleted once
// read.
//
// Usage: node proof.mjs HOMES_FILE OUT_DIR

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  addDevice, createAccount, devicesPage, passkeys, readLog, setUp, signIn,
} from "../browser/account.mjs";
import { answer, connectDevice, helloDevice, newDevice } from "../browser/device.mjs";
import {
  ask as askRunSh, launchBrowser, readHomes, redact as redactKnown, sleep, startProxy,
} from "../browser/lib.mjs";

const [homesFile, outDir] = process.argv.slice(2);
if (!homesFile || !outDir) {
  console.error("usage: node proof.mjs HOMES_FILE OUT_DIR");
  process.exit(64);
}
mkdirSync(outDir, { recursive: true });

const { homes } = readHomes(homesFile);
const homeNamed = (name) => homes.find((home) => home.name === name) || (() => { throw new Error(`no home ${name}`); })();
const DIR = homeNamed("dir");
const X = homeNamed("x");
const Y = homeNamed("y");
const NAME = "pair-a";
const layer = "#system-layer-dialog";
// How far past the bound a close may fall: the device asks every two
// seconds, and each ask is answered on its own.
const SLACK_S = 6;
const rows = [];
const record = {};
// Every recovery code, its secret and the setup tokens, so no record is
// shown to hold one.
const secrets = [];

function row(step, held, what, detail) {
  rows.push({ step, held: !!held, what, detail });
  console.log(`${held ? "held  " : "FAILED"} ${step}: ${what} — ${redact(JSON.stringify(detail)).slice(0, 2000)}`);
  return !!held;
}

const redact = (text) => redactKnown(text, secrets);

const ask = (request, options) => askRunSh(request, { outDir, timeoutMs: 300_000, refuseError: true, ...options });

let proxyPort = null;

const peopleAt = async (home) => (await ask({ op: "people", cell: home.name })).people;
const clientOf = async (home, kid) => {
  for (const person of await peopleAt(home)) {
    const found = person.clients.find((c) => c.kid === kid);
    if (found) return found;
  }
  return null;
};

// The device's first connection at `home` for the account `identifier`:
// its channel standing, or the code that closed it.
const hello = (device, home, identifier) =>
  helloDevice(device, { identifier, proxyPort, base: home.origin });

// An intent every two seconds on `ch` until its channel closes or
// `limitS` passes: the close code and the seconds it took, from `from`.
async function closedWithin(ch, from, limitS) {
  let code;
  ch.closed.then((c) => { code = c; });
  while (Date.now() - from <= limitS * 1000) {
    if (code !== undefined) return { code, after_s: Math.round((Date.now() - from) / 1000) };
    await Promise.race([ch.intent("confirmation.pending", {}), sleep(2_000)]);
    await sleep(2_000);
  }
  return { code: code ?? null, after_s: null };
}

// The setup link of `home`, signed in with the person's passkey: where the
// browser landed.
async function setUpAt(page, keys, home) {
  const { token } = await ask({ op: "setup_token", cell: home.name }, { secret: true });
  secrets.push(token);
  return setUp(page, keys, home, token);
}

// ---------------------------------------------------------------------------
// The steps
// ---------------------------------------------------------------------------

async function main(browser) {
  const keys = passkeys();
  const laptop = await (await browser.newContext()).newPage();

  // account
  const made = await createAccount(laptop, keys, { directory: DIR, name: NAME, secrets });
  const identifier = made.code?.identifier;
  const atX = made.section === "done" ? await setUpAt(laptop, keys, X) : { landed: false };
  const atY = atX.landed ? await setUpAt(laptop, keys, Y) : { landed: false };
  record.account = { made: made.section, x: atX, y: atY };
  if (!row("account", made.section === "done" && atX.landed && atY.landed,
    `@${NAME} is made at the pages and sets up both x.test and y.test by signing in with it`, record.account)) return;

  // page
  const device = newDevice({ name: "pairing proof device" });
  const added = await addDevice(laptop, keys, { directory: DIR, device });
  const listed = await readLog(DIR, identifier);
  const helloX = await hello(device, X, identifier);
  const clientX = device.clientId;
  const helloY = await hello({ ...device, clientId: null, certificate: null }, Y, identifier);
  const xClient = await clientOf(X, device.kid);
  const yClient = await clientOf(Y, device.kid);
  record.page = {
    added: { section: added.section, shown: added.shown }, listed: listed.keys,
    x: helloX.channel ? "standing" : helloX.code, y: helloY.channel ? "standing" : helloY.code, x_client: xClient, y_client: yClient,
  };
  if (!row("page",
    added.section === "added" && listed.keys.some((k) => k.kid === device.kid && k.kind === "device") &&
      !!helloX.channel && !!helloY.channel && xClient?.standing === "active" && yClient?.standing === "active",
    "a test device's key added at /account/add with the passkey, its short code shown, admits the device at both CYFRs by its " +
      "hello alone: each answers its sign-in request against the log and stands its channel",
    record.page)) return;

  // device_confirm: an API key the browser asks for at X, confirmed by
  // the test device over its own channel, which reads the CYFR's record,
  // asks its request and signs it.
  const segment = (await peopleAt(X)).find((p) => p.identifier === identifier)?.segment;
  await laptop.goto(`${X.origin}/a/${encodeURIComponent(segment)}/api-keys`);
  await laptop.waitForSelector(".phx-connected", { timeout: 60_000 });
  await laptop.locator("button", { hasText: "Create Key" }).click();
  await laptop.locator('#api-key-form input[name="name"]').fill("pairing-proof");
  await laptop.locator('#api-key-form button[type="submit"]').click();
  await laptop.waitForSelector(`${layer} [data-test="confirmation"][data-own="true"]`, { timeout: 30_000 });
  const ch = helloX.channel;
  const pending = await ch.intent("confirmation.pending", {});
  const waiting = (pending.result?.confirmations || []).find((c) => c.operation && c.operation.includes("key"));
  const requested = waiting ? await ch.intent("confirmation.request", { ref: waiting.ref }) : { ok: false };
  let confirmedByDevice = { ok: false };
  if (requested.ok) {
    const signed = answer(device, requested.result.request, { home: X.origin, purpose: "confirm" });
    confirmedByDevice = await ch.intent("confirmation.confirm", { ref: waiting.ref, answer: signed });
  }
  const keyShown = await laptop.waitForFunction(() => document.body.innerText.includes("It will not be shown again"), null,
    { timeout: 30_000 }).then(() => true).catch(() => false);
  record.device_confirm = {
    pending: waiting ? { operation: waiting.operation, methods: waiting.methods } : null,
    requested: { ok: requested.ok, purpose: requested.result?.request?.purpose, error: requested.error },
    confirmed: { ok: confirmedByDevice.ok, error: confirmedByDevice.error }, key_shown: keyShown,
  };
  if (!row("device_confirm",
    !!waiting && requested.result?.request?.purpose === "confirm" && confirmedByDevice.ok && keyShown,
    "an API key the browser asks for at x.test waits on a fresh confirmation; the device reads the record over its channel, " +
      "signs the confirm request with its key, and the browser's page makes the key",
    record.device_confirm)) return;

  // renewal: the device renews its certificate on its open channel at X
  // and goes on working there under the replacement.
  const renewedFrom = device.certificate;
  await sleep(2_000);
  const renewal = await Promise.race([
    ch.renew(), ch.closed.then((code) => ({ closed: code })), sleep(30_000).then(() => ({ timed_out: true })),
  ]);
  const afterRenewal = await ch.intent("confirmation.pending", {});
  record.renewal = {
    renewed: !!renewal.certificate, closed: renewal.closed ?? null, timed_out: !!renewal.timed_out,
    expires_before: renewedFrom?.expires_at, expires_after: device.certificate?.expires_at,
    standing_expires: ch.standing?.expires_at, same_client: device.certificate?.client_id === renewedFrom?.client_id,
    intent_after: { ok: afterRenewal.ok, error: afterRenewal.error },
  };
  if (!row("renewal",
    !!renewal.certificate && device.certificate.expires_at > renewedFrom.expires_at &&
      ch.standing?.expires_at === device.certificate.expires_at && record.renewal.same_client && afterRenewal.ok,
    "the device renews its certificate on its open channel at x.test: the replacement, for the same client, lives longer, the " +
      "channel's standing names it, and the device's next intent is answered under it",
    record.renewal)) return;

  // remove_key: the device removed at the devices page; both CYFRs end its
  // channel within their bound.
  const channelY = helloY.channel;
  const devices = await devicesPage(laptop, keys, { directory: DIR, identifier });
  const removed = await devices.removeKey(device.kid);
  const removedAt = Date.now();
  const bound = (await ask({ op: "bound" })).seconds;
  const [closedX, closedY] = await Promise.all([
    closedWithin(ch, removedAt, bound + SLACK_S + 30), closedWithin(channelY, removedAt, bound + SLACK_S + 30),
  ]);
  const afterX = await clientOf(X, device.kid);
  const afterY = await clientOf(Y, device.kid);
  record.remove_key = { removed, closed_x: closedX, closed_y: closedY, bound, slack: SLACK_S, x_client: afterX, y_client: afterY };
  if (!row("remove_key",
    removed.done && closedX.code === 4403 && closedY.code === 4403 && closedX.after_s <= bound + SLACK_S &&
      closedY.after_s <= bound + SLACK_S && afterX?.standing !== "active" && afterY?.standing !== "active",
    "the device removed from the account at the devices page has its channel closed 4403 at both CYFRs within their freshness " +
      "bound, and neither holds it standing",
    record.remove_key)) return;

  // readd: added again, the device is admitted afresh; then removed and
  // added again while it waits, both entries landing between two of X's
  // refreshes: X retires it all the same, and its next hello admits it
  // again as a new client.
  const back = await addDevice(laptop, keys, { directory: DIR, device });
  device.clientId = null;
  device.certificate = null;
  const again = await hello(device, X, identifier);
  const firstClient = device.clientId;
  const quiet = again.channel;
  const devicesAgain = await devicesPage(laptop, keys, { directory: DIR, identifier });
  const removedAgain = await devicesAgain.removeKey(device.kid);
  const readded = await addDevice(laptop, keys, { directory: DIR, device });
  const changedAt = Date.now();
  const between = await readLog(DIR, identifier);
  const retired = quiet ? await closedWithin(quiet, changedAt, bound + SLACK_S + 30) : { code: null };
  device.clientId = null;
  device.certificate = null;
  const readmitted = await hello(device, X, identifier);
  readmitted.channel?.close();
  record.readd = {
    back: back.section, admitted_again: !!again.channel, first_client_new: firstClient !== clientX,
    removed: removedAgain, readded: readded.section, listed: between.keys.some((k) => k.kid === device.kid),
    kinds: between.kinds.slice(-2), retired, readmitted: readmitted.channel ? "standing" : readmitted.code,
    new_client: !!device.clientId && device.clientId !== firstClient,
  };
  if (!row("readd",
    back.section === "added" && !!again.channel && firstClient !== clientX && removedAgain.done && readded.section === "added" &&
      between.kinds.slice(-2).join() === "remove_key,add_key" && record.readd.listed && retired.code === 4403 &&
      !!readmitted.channel && record.readd.new_client,
    "added again, the device is admitted as a new client; removed and added again between two refreshes, x.test retires it " +
      "although the account lists it, and its next hello admits it once more as another client",
    record.readd)) return;

  // restore: x.test stopped, its restore declared and started again. The
  // restore suspends x.test's own bindings, the device's client and
  // certificate and the browser's session, and touches no key of the
  // account; the device's hello and a fresh sign-in bring each back.
  const restoredClient = device.clientId;
  const beforeRestore = await readLog(DIR, identifier);
  const declared = await ask({ op: "restore", cell: "x" });
  const held = await connectDevice({ ...device }, { proxyPort, base: X.origin });
  held.channel?.close();
  await laptop.goto(`${X.origin}/`);
  await laptop.waitForLoadState("domcontentloaded");
  const laptopAt = new URL(laptop.url()).pathname;
  const afterRestore = await readLog(DIR, identifier);
  const standingAfter = (await peopleAt(X)).find((p) => p.identifier === identifier)?.clients.filter((c) => c.standing === "active") ?? [];
  device.clientId = null;
  device.certificate = null;
  const backByHello = await hello(device, X, identifier);
  backByHello.channel?.close();
  const signedInAgain = await signIn(laptop, keys, X);
  record.restore = {
    declared: declared.declared, old_certificate: held.channel ? "standing" : held.code, laptop_at: laptopAt,
    log_unchanged: afterRestore.head === beforeRestore.head, active_after: standingAfter,
    hello: backByHello.channel ? "standing" : backByHello.code, new_client: !!device.clientId && device.clientId !== restoredClient,
    signed_in: signedInAgain,
  };
  row("restore",
    /^rst_/.test(declared.declared || "") && !held.channel && laptopAt === "/login" && record.restore.log_unchanged &&
      standingAfter.length === 0 && !!backByHello.channel && record.restore.new_client && signedInAgain.landed,
    "a declared restore of x.test refuses the device's certificate, ends the browser's session and leaves no client standing, " +
      "while the account's log is as it was; the device's hello admits it again as a new client and the passkey signs in afresh",
    record.restore);
}

// ---------------------------------------------------------------------------

let proxy;
try {
  proxy = await startProxy({ homes });
} catch (error) {
  console.error(`FAIL: ${error.message.split("\n")[0]}`);
  process.exit(1);
}
proxyPort = proxy.address().port;
const browser = await launchBrowser("chromium", proxy);
const version = browser.version();
console.log(`== chromium ${version}`);
let failure = null;
try {
  await main(browser);
} catch (error) {
  failure = redact(error.stack || String(error));
  console.error(`FAIL: ${failure}`);
  for (const context of browser.contexts()) {
    for (const page of context.pages()) {
      const text = await page.locator("body").innerText({ timeout: 2_000 }).catch(() => "unread");
      console.error(`  at ${page.url().replace(/#.*/, "#…")}: ${JSON.stringify(redact(text).slice(0, 3000))}`);
    }
  }
} finally {
  await browser.close();
  proxy.close();
}

const STEPS = ["account", "page", "device_confirm", "renewal", "remove_key", "readd", "restore"];
const outcome = (step) => {
  const found = rows.find((r) => r.step === step);
  return found ? (found.held ? "held" : "FAILED") : "not reached";
};
writeFileSync(join(outDir, "pairing-proof.json"), redact(JSON.stringify({ chromium: version, rows, record, failure }, null, 2)));
const table = [`| step | chromium ${version} |`, "|---|---|", ...STEPS.map((step) => `| ${step} | ${outcome(step)} |`)];
writeFileSync(join(outDir, "pairing-proof.md"), table.join("\n") + "\n");
console.log(table.join("\n"));
if (failure || STEPS.some((step) => outcome(step) !== "held")) {
  console.error("FAIL: a step of the pairing proof did not hold");
  process.exit(1);
}
console.log("ok: every step held");
