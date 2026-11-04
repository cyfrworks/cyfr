// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The identity proof, run in the official Playwright image by run.sh
// against `cyfr` releases behind the harness's HTTPS front (README.md):
// homes A, B, C, C2 and C3 and a directory, each a cell on its own `.test`
// name, and the cyfr.run stand-in A registers names at. A's first person
// comes through setup's two screens. Chromium alone, since a passkey is
// made and used by its virtual authenticator. The devices paired at A are
// test devices (../browser/device.mjs), clients of the device channel this
// process drives; a device's steps run once more from a Prism at the
// handheld's 720×720 touch viewport (../browser/handheld.mjs).
// Each step is one row of the record; the proof fails when a row does not
// hold, and stops at the first row a later one rests on.
//
// The homes' part of a step — a cell stopped, copied, killed or started
// again, the directory's front broken on purpose, a restore posted at a
// phase, and what a home holds — is run.sh's, asked for through OUT_DIR
// (`ask-N.json`, answered `answer-N.json`). An ask or an answer that
// carries a recovery code, a setup token or an installation token is
// deleted once read.
//
// Usage: node proof.mjs HOMES_FILE OUT_DIR

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { channel, connectDevice, newDevice, pair as pairDevice } from "../browser/device.mjs";
import { HANDHELD, measure, unmet } from "../browser/handheld.mjs";
import {
  admit, ask as askRunSh, launchBrowser, readCode, readHomes, redact as redactKnown,
  saveAdmissionCode, saveCode, sleep, startProxy, virtualAuthenticator, waitFor,
} from "../browser/lib.mjs";

const [homesFile, outDir] = process.argv.slice(2);
if (!homesFile || !outDir) {
  console.error("usage: node proof.mjs HOMES_FILE OUT_DIR");
  process.exit(64);
}
mkdirSync(outDir, { recursive: true });

const { homes } = readHomes(homesFile);
const homeNamed = (name) => homes.find((home) => home.name === name) || (() => { throw new Error(`no home ${name}`); })();
const A = homeNamed("a").origin;
const C = homeNamed("c").origin;
const C3 = homeNamed("c3").origin;
// The name A's person types on setup's first screen.
const NAME = "identity-a";
// The landing page's flash once the recovery code is saved.
const SAVED = "Saved. You can add another recovery code in Settings, and keep it apart from this one.";
// The route segment of A's person's own athanor, read once setup lands.
let segmentA = null;
const settingsOf = (base, segment) => `${base}/a/${encodeURIComponent(segment)}/settings`;
const shellOf = (base, segment) => `${base}/a/${encodeURIComponent(segment)}/canvas`;
const rows = [];
const record = {};
// Every recovery code, its secret and every token the proof handled, so
// no page, address or record is shown to hold one.
const secrets = [];

function row(step, held, what, detail) {
  rows.push({ step, held: !!held, what, detail });
  const shown = JSON.stringify(detail);
  console.log(`${held ? "held  " : "FAILED"} ${step}: ${what} — ${redact(shown).slice(0, 2000)}`);
  return !!held;
}

// What the proof writes, with every secret it handled replaced
// (lib.mjs `redact`).
const redact = (text) => redactKnown(text, secrets);

// The homes' part of a step, asked of run.sh (lib.mjs `ask`). `secret: true`
// removes the answer once read; run.sh has removed the ask.
const ask = (request, options) => askRunSh(request, { outDir, timeoutMs: 300_000, refuseError: true, ...options });

// The proxy every home is reached through, the browsers' and the test
// devices' (`main`).
let proxyPort = null;

// A connection of the test device's own under `certificate` (its current
// one unless named): `connect`, the challenge signed with its key, and the
// code the home closed it with, or "open" when it stood.
async function connectWith(device, base, certificate = device.certificate) {
  // The challenge is answered as the home the certificate names expects:
  // a certificate presented at another home is that home's to refuse.
  const ch = channel({ ...device, certificate }, { proxyPort, base, purpose: "connect", home: certificate.audience });
  const outcome = await Promise.race([ch.opened.then(() => "open"), ch.closed, sleep(20_000).then(() => "timed out")]);
  if (outcome === "open") ch.close();
  return { code: outcome, seen: ch.log.filter((e) => e.dir === "in").map((e) => e.type) };
}

const connected = (page) => page.waitForSelector(".phx-connected", { timeout: 60_000 });
const layer = "#system-layer-dialog";
const layerText = (page) => page.locator(layer).innerText({ timeout: 2_000 }).catch((error) => `unread: ${error.message.split("\n")[0]}`);

async function closePrompt(page) {
  const close = page.locator(`${layer}[open] [data-test="prompt-dismiss"]`);
  if (await close.count()) {
    await close.click();
    await page.waitForFunction(() => !document.getElementById("system-layer-dialog")?.open, null, { timeout: 30_000 });
  }
}

async function open(page, url, { close = true } = {}) {
  await page.goto(url);
  await connected(page);
  if (close) await closePrompt(page);
}

// The page's own request, confirmed here with the passkey its
// authenticator holds.
async function confirmHere(page) {
  const own = `${layer} [data-test="confirmation"][data-own="true"]`;
  await page.waitForSelector(`${own} [data-test="confirm-passkey"]`, { timeout: 30_000 });
  await page.locator(`${own} [data-test="confirm-passkey"]`).click();
}

// What the page says after a change: its flash, or the layer's sentence.
const flashed = (page, text, timeout = 30_000) =>
  page.waitForFunction((t) => document.body.innerText.includes(t), text, { timeout });

// Where a secret the proof handled might have gone in the page's own
// browser: its storage, its address, and every request the proxy saw.
async function leaks(page, proxy, mark) {
  const stored = await page.evaluate(() => {
    const dump = (store) => {
      const out = [];
      for (let i = 0; i < store.length; i++) out.push(store.key(i), store.getItem(store.key(i)));
      return out.join("\n");
    };
    return `${dump(localStorage)}\n${dump(sessionStorage)}\n${location.href}\n${document.cookie}`;
  });
  const requests = proxy.seen.slice(mark).map((r) => `${r.url} ${r.referer ?? ""}`).join("\n");
  return secrets.filter((secret) => secret && (stored.includes(secret) || requests.includes(secret))).length;
}

// ---------------------------------------------------------------------------
// The steps
// ---------------------------------------------------------------------------

async function firstPasskey(page, authenticator, base, segment, step) {
  await open(page, settingsOf(base, segment));
  await page.locator('[data-test="passkey-register"]').click();
  await flashed(page, "Passkey registered.");
  await page.waitForSelector('[data-test="passkey"][data-state="active"]', { timeout: 30_000 });
  // The authenticator may hold a credential an earlier, refused ceremony
  // made; the home holds the one it registered.
  const held = (await authenticator.credentials()).filter((c) => c.rpId === new URL(base).host).length;
  const registered = await page.locator('[data-test="passkey"][data-state="active"]').count();
  record[step] = { credentials_for_rp: held, registered_here: registered };
  return row(step, held >= 1 && registered === 1, "the first passkey is registered from the settings page through the system layer's ceremony", record[step]);
}

// A test device (../browser/device.mjs) paired at A from the desktop's
// Devices: its key made in this process, its code typed there, the pairing
// confirmed with the desktop's passkey, completed with the device's key,
// and its channel standing under the certificate A answered. `page` is the
// desktop's, or the handheld's, whose screens are measured when `measured`
// is given. `confirmer` is the page whose passkey confirms the pairing,
// `page` unless named: the handheld shares the desktop's session, so its
// request is the desktop's own too, and the desktop's passkey confirms it
// there, its counter held by the one authenticator that uses it. Answers
// the device.
async function pairAtA(page, { name = "identity proof test device", measured = null, confirmer = null } = {}) {
  const device = newDevice({ name });
  await open(page, shellOf(A, segmentA));
  await page.locator("#shell-devices").click();
  await page.waitForSelector(`${layer} [data-test="pairing"]`, { timeout: 30_000 });
  await page.locator(`${layer} [data-test="pairing-key-input"]`).fill(device.code);
  await page.locator(`${layer} [data-test="pairing-begin"]`).click();
  if (measured) {
    await page.waitForSelector(`${layer} [data-test="confirmation"][data-own="true"] [data-test="confirm-passkey"]`, { timeout: 30_000 });
    measured.consent_prompt = await measure(page, layer);
  }
  if (confirmer) {
    // The desktop shows the request as its own or as another client's,
    // as the home names who asked: either is confirmed with the passkey.
    await open(confirmer, shellOf(A, segmentA), { close: false });
    const panel = `${layer} [data-test="confirmation"]`;
    await confirmer.waitForFunction((selector) => [...document.querySelectorAll(selector)]
      .some((p) => /pairing\.begin/.test(p.textContent) && p.querySelector('[data-test="confirm-passkey"]')), panel, { timeout: 30_000 });
    const handles = await confirmer.$$(panel);
    for (const handle of handles) {
      if (/pairing\.begin/.test(await handle.textContent())) {
        await (await handle.$('[data-test="confirm-passkey"]')).click();
        break;
      }
    }
  } else {
    await confirmHere(page);
  }
  await page.waitForSelector(`${layer} [data-test="pairing-link"]`, { timeout: 30_000 });
  const link = await page.locator(`${layer} [data-test="pairing-link"]`).inputValue();
  if (measured) measured.pairing_link = await measure(page, layer);
  await closePrompt(page);
  const paired = await pairDevice(device, { proxyPort, base: A, secret: link.split("#code=")[1] });
  if (paired.error) return null;
  const opened = await connectDevice(device, { proxyPort, base: A });
  if (!opened.channel) return null;
  opened.channel.close();
  return device;
}

// A's first person, made through setup's two screens at A's setup link,
// the setup token in its fragment: the name typed on the first and found
// free at the stand-in, a passkey made, the second's recovery code once
// the identity is registered at dir.test and the name claimed, and "I
// saved it", which signs the browser in and lands in CYFR with the
// sentence that offers another code; Settings' identity card then names
// the person. Answers the row and the code.
async function setUp(desk, authenticator, proxy) {
  const mark = proxy.seen.length;
  const { token } = await ask({ op: "token", cell: "a" }, { secret: true });
  secrets.push(token);
  await desk.goto(`${A}/setup#${token}`);
  await connected(desk);
  const { recovery: code } = await admit(desk, NAME, secrets);
  // Decided on the text a person reads, never the raw HTML: the code is
  // drawn with a <wbr> after each hyphen, which splits it in the markup
  // and adds nothing to the text.
  const shownBeforeSave = (await desk.locator('[data-test="admission-code"] [data-test="recovery-code"]').textContent()).trim() === code.code;
  const landed = await saveAdmissionCode(desk);
  await connected(desk);
  const saidSaved = await flashed(desk, SAVED).then(() => true, () => false);
  const afterSave = (await desk.evaluate(() => document.body.textContent)).includes(code.code);
  const leaked = await leaks(desk, proxy, mark);
  const person = await ask({ op: "a_person" });
  segmentA = person.segment;
  const head = await ask({ op: "a_head" });
  const held = (await authenticator.credentials()).filter((c) => c.rpId === new URL(A).host).length;
  await open(desk, settingsOf(A, segmentA));
  const card = await desk.locator('[data-test="identity"]').getAttribute("data-state", { timeout: 30_000 });
  const nameShown = (await desk.locator('[data-test="identity-name"]').innerText({ timeout: 30_000 })).trim();
  record.setup = {
    people: person.people, admission: person.admission, identifier: code.identifier, a_identifier: head.identifier,
    enrollment: head.enrollment, card, name_shown: nameShown, credentials_for_rp: held,
    landed: new URL(landed).pathname, said_saved: saidSaved, drawn_on_screen_2: shownBeforeSave,
    kept_after_saving: afterSave, leaked,
  };
  return [row("setup",
    person.people === 1 && person.admission === "setup" && code.identifier === head.identifier &&
      head.enrollment === "enrolled" && card === "named" && nameShown === `Your name is @${NAME}.` && held === 1 &&
      saidSaved && shownBeforeSave && !afterSave && leaked === 0,
    `A's first person comes through setup's two screens: @${NAME} typed and free, a passkey made, the identity registered at dir.test and the name claimed, the recovery code naming A's identity drawn on the second screen, and "I saved it" erases it and lands in CYFR signed in; neither the code, its secret nor the setup token reaches the browser's storage, an address or any request the proxy saw`,
    record.setup), code];
}

// The stand-in's answer for A's name, and the directory A's genesis names.
async function named(code) {
  const answer = await ask({ op: "handle_answer", name: NAME });
  record.name = answer;
  return row("name",
    answer.status === 200 && answer.answer?.handle === NAME && answer.answer?.identifier === code.identifier &&
      answer.held_by === code.identifier && answer.answer?.directory === "https://dir.test" &&
      answer.genesis_directory === "https://dir.test" && answer.attempt_directory === "https://dir.test",
    `the stand-in answers @${NAME} with A's identifier and https://dir.test, the directory A's genesis names`,
    answer);
}

async function secondCode(desk, proxy, first) {
  const mark = proxy.seen.length;
  await open(desk, settingsOf(A, segmentA));
  await desk.locator('[data-test="identity-add-code"]').click();
  await desk.waitForSelector(`${layer} [data-test="recovery"][data-kind="holder"]`, { timeout: 30_000 });
  await desk.locator(`${layer} [data-test="recovery-signer"]`).fill(first.code);
  await desk.locator(`${layer} [data-test="recovery-submit"]`).click();
  await confirmHere(desk);
  const code = await readCode(desk, secrets);
  await saveCode(desk);
  const leaked = await leaks(desk, proxy, mark);
  record.second_code = { same_identifier: code.identifier === first.identifier, distinct: code.secret !== first.secret, leaked };
  return [row("second_code", record.second_code.same_identifier && record.second_code.distinct && leaked === 0,
    "another recovery code, approved by the first one typed into the prompt, its secret drawn in the browser",
    record.second_code), code];
}

async function rotate(desk, device) {
  const before = await ask({ op: "a_head" });
  const held = device.certificate;
  await open(desk, settingsOf(A, segmentA));
  await desk.locator('[data-test="identity-rotate"]').click();
  await confirmHere(desk);
  await flashed(desk, "Your live key was rotated.");
  const after = await ask({ op: "a_head" });

  // The certificate signed under the replaced key opens nothing; the device
  // renews by its device key on its next connection, whose stale connect
  // is closed 4408, and stands again under a new certificate.
  const replaced = await connectWith(device, A, held);
  const renewed = await connectDevice(device, { proxyPort, base: A });
  const sent = renewed.channel ? renewed.channel.log.filter((e) => e.dir === "out").map((e) => e.type) : [];
  if (renewed.channel) renewed.channel.close();
  record.rotate = {
    head_moved: before.head !== after.head, live_key_moved: before.live_key !== after.live_key,
    replaced_certificate: replaced, renewed: !!renewed.channel, sent,
    new_certificate: JSON.stringify(device.certificate) !== JSON.stringify(held),
  };
  return row("rotate",
    record.rotate.head_moved && record.rotate.live_key_moved && replaced.code === 4408 &&
      record.rotate.renewed && sent[0] === "renew" && record.rotate.new_certificate,
    "the live key rotated under a fresh confirmation: a certificate signed under the replaced key opens nothing, and the paired device renews by its device key",
    record.rotate);
}

async function cache() {
  const answer = await ask({ op: "b_resolve" });
  const head = await ask({ op: "a_head" });
  record.cache = { b: answer.key_epoch, a: head.head };
  return row("cache", answer.key_epoch === head.head,
    "B, which holds nothing of the person's, reads the identity at its directory and caches the head",
    record.cache);
}

// The restore page of `base`, filled with `token` and the recovery code
// `code` (`readCode`), and its answer once it settles.
async function restoreThere(page, base, token, code) {
  await page.goto(`${base}/restore`);
  await connected(page);
  await page.locator('[data-test="restore-token"]').fill(token);
  await page.locator('[data-test="restore-code"]').fill(code.code);
  await page.locator('[data-test="restore-submit"]').click();
  await page.waitForSelector('[data-test="restore-status"]:not([data-state="idle"]):not([data-state="retry"])', { timeout: 180_000 });
  return page.locator('[data-test="restore-status"]').getAttribute("data-state");
}

async function restoredHome(page, proxy, base, cell, token, code, step) {
  const mark = proxy.seen.length;
  const state = await restoreThere(page, base, token, code);
  const fields = await page.$$eval("[data-field]", (inputs) => inputs.map((input) => input.value));
  const leaked = await leaks(page, proxy, mark);
  const posted = proxy.seen.slice(mark).filter((r) => r.method === "POST" && r.url === `${base}/restore`);
  record[step] = { state, emptied: fields.every((value) => value === ""), leaked, posts: posted.length };
  const held = row(step, state === "completed" && record[step].emptied && leaked === 0,
    `the person restores on ${cell} with the recovery code and its own installation token; the form forgets both`,
    record[step]);
  return held;
}

// ---------------------------------------------------------------------------
// A device's steps once more from the handheld (HANDHELD)
// ---------------------------------------------------------------------------

// The handheld follows the desktop through a device's steps: its Prism,
// signed in at A in the desktop's session, pairs a second test device
// there, its consent prompt and link measured, the desktop's passkey
// confirming it;
// after the rotation its Devices lists that device standing under a
// renewed certificate; and that device's certificate opens nothing at C,
// a home that holds no device of it. Each of those screens meets the
// handheld's checks, which the `viewport` row holds.
async function handheldPairs(browser, desk) {
  const context = await browser.newContext(HANDHELD);
  await context.addCookies(await desk.context().cookies(A));
  const page = await context.newPage();
  const hand = { context, page, measured: {}, facts: {} };
  hand.device = await pairAtA(page, { name: "identity proof handheld device", measured: hand.measured, confirmer: desk });
  hand.facts.paired_subject = hand.device && hand.device.certificate.subject.kind;
  return hand;
}

async function handheldReconnects(hand) {
  const before = hand.device && hand.device.certificate;
  const renewed = hand.device ? await connectDevice(hand.device, { proxyPort, base: A }) : {};
  if (renewed.channel) renewed.channel.close();
  hand.facts.renewed_after_rotation = !!renewed.channel && JSON.stringify(hand.device.certificate) !== JSON.stringify(before);
  await open(hand.page, shellOf(A, segmentA));
  await hand.page.locator("#shell-devices").click();
  const listed = `${layer} [data-test="pairing-client"][data-client="${hand.device && hand.device.clientId}"]`;
  hand.facts.listed_after_rotation = await hand.page.waitForSelector(listed, { timeout: 30_000 }).then(() => true).catch(() => false);
  hand.measured.devices = await measure(hand.page, layer);
}

async function handheldElsewhere(hand) {
  hand.facts.at_c = hand.device ? (await connectWith(hand.device, C)).code : null;
  await hand.context.close();
  const failures = unmet(hand.measured);
  record.viewport = { viewport: HANDHELD.viewport, ...hand.facts, measured: hand.measured, failures };
  return row("viewport",
    hand.facts.paired_subject === "local" && hand.facts.renewed_after_rotation && hand.facts.listed_after_rotation &&
      hand.facts.at_c !== "open" && failures.length === 0,
    "at 720×720: a device paired locally from the handheld's Prism, its consent and link read there, listed under its renewed certificate after the rotation, and refused at a home that holds no device of it, every control 24×24 CSS px or more, text 12 px or more, nothing overflowing",
    record.viewport);
}

async function main(browser, proxy) {
  proxyPort = proxy.address().port;
  const deskContext = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const desk = await deskContext.newPage();
  const deskAuthenticator = await virtualAuthenticator(desk);

  const [setUpHeld, code1] = await setUp(desk, deskAuthenticator, proxy);
  if (!setUpHeld) return;
  if (!(await named(code1))) return;
  // Two test devices paired at A, from the desktop and from the
  // handheld, which the rotation renews.
  const device = await pairAtA(desk);
  if (!device) {
    row("rotate", false, "a test device paired at A stands", { device });
    return;
  }
  const hand = await handheldPairs(browser, desk);
  const [added, code2] = await secondCode(desk, proxy, code1);
  if (!added) return;
  if (!(await rotate(desk, device))) return;
  await handheldReconnects(hand);
  if (!(await cache())) return;

  // A thief takes a copy of A as it stands.
  record.preserved = await ask({ op: "preserve_a" });

  // C, configured for one restore: its setup is refused before any
  // recovery code.
  const reserved = await ask({ op: "c_setup" });
  record.reserved = reserved;
  if (!row("reserved", reserved.refused === "restore_reserved",
    "C, an empty installation configured for restore, refuses its setup before any recovery code is presented", reserved)) return;

  // C's token and the second recovery code, handed to run.sh, which posts
  // with them as the browser does; neither stays in an ask or an answer.
  const tokenC = (await ask({ op: "token", cell: "c" }, { secret: true })).token;
  secrets.push(tokenC);
  const claims = await ask({ op: "c_claims", code: code2 }, { secret: true });
  record.claims = claims;
  if (!row("claims",
    claims.other_token === 401 &&
      claims.unknown_identity?.status === 422 && claims.unknown_identity?.error === "unknown_identity" &&
      claims.wrong_secret?.status === 422 && claims.wrong_secret?.error === "not_a_holder" &&
      claims.typo?.status === 422 && claims.typo?.error === "typo" && claims.attempts === 0,
    "C's own token alone opens it: another cell's token is refused, and so are a recovery code of an identity the directory never saw, one whose secret holds no recovery key of the identity and the person's own code with one symbol changed, each for its reason, and nothing is claimed", claims)) return;

  const phases = await ask({ op: "c_phases", code: code2 }, { secret: true, timeoutMs: 900_000 });
  record.phases = phases;
  if (!row("phases",
    phases.submitted.status === 503 && phases.submitted.phase === "submitted" &&
      phases.accepted.status === 503 && phases.accepted.phase === "accepted" &&
      phases.recoveries === 1,
    "C killed at submitted (its reply lost) and at accepted (its head unread) resumes each time under the same request, and the directory holds one recovery",
    phases)) return;
  if (!row("replay", phases.replay.entry_hash && phases.replay.entry_hash === phases.accepted.entry_hash,
    "the recovery's request sent again returns its recorded outcome, and nothing new is recorded", phases.replay)) return;
  if (!row("thief", phases.thief.won === false && phases.thief.later_refused,
    "a thief rotating on a copy of A, concurrently, loses: the recovery's keys hold, and a rotation after it is refused", phases.thief)) return;

  const cContext = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const cPage = await cContext.newPage();
  const cAuthenticator = await virtualAuthenticator(cPage);
  if (!(await restoredHome(cPage, proxy, C, "C", tokenC, code2, "restore"))) return;

  const observed = await ask({ op: "b_observes", cell: "c" }, { timeoutMs: 300_000 });
  record.b_observes = observed;
  if (!row("b_observes", observed.observed && observed.seconds <= observed.bound + observed.slack,
    "B, holding only a directory cache, observes C's new head within its freshness bound (and the one poll of B that saw it)", observed)) return;

  // The restored person on C: their first passkey's window does not slide
  // with use; a reproof opens a new one; then a door is linked.
  const { segment: segmentC, waited } = await ask({ op: "c_window" });
  const settingsC = settingsOf(C, segmentC);
  const until = Date.now() + waited * 1000;
  while (Date.now() < until) {
    await open(cPage, settingsC);
    await sleep(3_000);
  }
  await open(cPage, settingsC);
  await cPage.locator('[data-test="passkey-register"]').click();
  await cPage.waitForFunction(() => /Passkey:/.test(document.body.innerText), null, { timeout: 30_000 });
  const lapsed = await cPage.locator('[data-test="passkey"]').count();
  const reproof = await (async () => {
    await cPage.goto(`${C}/restore`);
    await connected(cPage);
    await cPage.locator('[data-test="restore-token"]').fill(tokenC);
    await cPage.locator('[data-test="restore-code"]').fill(code2.code);
    await cPage.locator('[data-test="restore-submit"]').click();
    await cPage.waitForSelector('[data-test="restore-status"][data-state="restored"]', { timeout: 60_000 });
    await cPage.locator('[data-test="restore-reproof"]').click();
    await cPage.waitForSelector('[data-test="restore-status"][data-state="completed"]', { timeout: 60_000 });
    return cPage.locator('[data-test="restore-status"]').getAttribute("data-state");
  })();
  record.window = { refused_after_window: lapsed === 0, reproof };
  if (!row("window", lapsed === 0 && reproof === "completed",
    "past the restore session's window, kept in use, no first passkey registers; the recovery code proven again under a new challenge opens a new window",
    record.window)) return;
  if (!(await firstPasskey(cPage, cAuthenticator, C, segmentC, "first_passkey"))) return;

  const cookie = (await cContext.cookies(C)).find((c) => c.name === "_cyfr_key");
  const linked = await ask({ op: "c_link_ticket", cookie: cookie.value }, { secret: true });
  await cContext.addCookies([{ ...cookie, value: linked.cookie }]);
  // The page presents the ticket as it loads, and asks for its confirmation.
  await open(cPage, settingsC, { close: false });
  await confirmHere(cPage);
  await flashed(cPage, "Linked github sign-in");
  const doors = await cPage.locator('[data-test="door"]').count();
  record.door = { doors };
  if (!row("door", doors === 1, "the restored person links a door, freshly confirmed with their new passkey", record.door)) return;

  // The device paired at A is not C's: C holds no paired client, and its
  // certificate opens nothing at C.
  const people = await ask({ op: "people", cell: "c" });
  const atC = await connectWith(device, C);
  record.pair_again = { people: people.people, at_c: atC };
  if (!row("pair_again", people.people.length === 1 && people.people[0].paired_clients === 0 && atC.code !== "open",
    "a restore without the old paired client's row: the device paired at A opens nothing at C and pairs again", record.pair_again)) return;
  if (!(await handheldElsewhere(hand))) return;

  // A gone: recovery still completes, and a recovery accepted, its reply
  // lost and superseded elsewhere, activates nothing.
  await ask({ op: "a_down" });
  const tokenC2 = (await ask({ op: "token", cell: "c2" }, { secret: true })).token;
  secrets.push(tokenC2);
  const accepted = await ask({ op: "c2_accepted", code: code1 }, { secret: true, timeoutMs: 600_000 });
  record.c2_accepted = accepted;
  const tokenC3 = (await ask({ op: "token", cell: "c3" }, { secret: true })).token;
  secrets.push(tokenC3);
  const c3Context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const c3Page = await c3Context.newPage();
  const front = await ask({ op: "front_mark" });
  if (!(await restoredHome(c3Page, proxy, C3, "C3, with A gone", tokenC3, code2, "without_a"))) return;
  const seen = await ask({ op: "front_since", mark: front.mark, cell: "a" });
  record.without_a = { ...record.without_a, directory_paths_only: seen.directory_only, a_answers: seen.a_answers };
  if (!row("without_a_reach", seen.directory_only && seen.a_answers === false,
    "with A gone, the restore reached the directory alone: no home, and no saved-home list, was asked", record.without_a)) return;

  const superseded = await ask({ op: "c2_resume", tolerate: true }, { timeoutMs: 300_000 });
  record.superseded = superseded;
  if (!row("superseded",
    accepted.status === 503 && accepted.phase === "accepted" && superseded.status === 409 && superseded.error === "superseded" &&
      superseded.phase === "superseded" && superseded.staged === false && superseded.people === 0,
    "C2's recovery, accepted with its reply lost and replaced by C3's, resumes as superseded and activates nothing",
    superseded)) return;

  const observedC3 = await ask({ op: "b_observes", cell: "c3" }, { timeoutMs: 300_000 });
  record.b_observes_again = observedC3;
  if (!row("b_observes_again", observedC3.observed && observedC3.seconds <= observedC3.bound + observedC3.slack,
    "B observes C3's head within its bound (and the one poll that saw it), with A gone", observedC3)) return;

  const down = await ask({ op: "directory_down" }, { timeoutMs: 300_000 });
  record.directory_down = down;
  row("directory_down", down.within.key_epoch && down.past.refused === "identity_stale",
    "with the directory down, B serves the cached head within its bound and pauses past it", down);
}

// ---------------------------------------------------------------------------

let proxy;
try {
  proxy = await startProxy({ homes });
} catch (error) {
  console.error(`FAIL: ${error.message.split("\n")[0]}`);
  process.exit(1);
}
const browser = await launchBrowser("chromium", proxy);
const version = browser.version();
console.log(`== chromium ${version}`);
let failure = null;
try {
  await main(browser, proxy);
} catch (error) {
  failure = redact(error.stack || String(error));
  console.error(`FAIL: ${failure}`);
  for (const context of browser.contexts()) {
    for (const page of context.pages()) {
      const text = await page.locator("body").innerText({ timeout: 2_000 }).catch(() => "unread");
      console.error(`  at ${page.url().replace(/#.*/, "#…")}: ${JSON.stringify(redact(text).slice(0, 3000))}`);
      const shown = await layerText(page);
      if (shown && !shown.startsWith("unread")) console.error(`  its layer: ${JSON.stringify(redact(shown).slice(0, 2000))}`);
    }
  }
} finally {
  await browser.close();
  proxy.close();
}

const STEPS = [
  "setup", "name", "second_code", "rotate", "cache", "reserved", "claims", "phases", "replay", "thief",
  "restore", "b_observes", "window", "first_passkey", "door", "pair_again", "viewport", "without_a", "without_a_reach",
  "superseded", "b_observes_again", "directory_down",
];
const outcome = (step) => {
  const found = rows.find((r) => r.step === step);
  return found ? (found.held ? "held" : "FAILED") : "not reached";
};
writeFileSync(join(outDir, "identity-proof.json"), redact(JSON.stringify({ chromium: version, rows, record, failure }, null, 2)));
const table = [`| step | chromium ${version} |`, "|---|---|", ...STEPS.map((step) => `| ${step} | ${outcome(step)} |`)];
writeFileSync(join(outDir, "identity-proof.md"), table.join("\n") + "\n");
console.log(table.join("\n"));
if (failure || STEPS.some((step) => outcome(step) !== "held")) {
  console.error("FAIL: a step of the identity proof did not hold");
  process.exit(1);
}
console.log("ok: every step held");
