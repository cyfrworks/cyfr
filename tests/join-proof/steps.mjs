// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The join proof's steps after the sign-ins, Chromium's alone
// (README.md): what a crafted or forged link does, a copied session, a
// dropped answer and closed tabs; a passkey and a phone at the hub; a
// removal, a rotation and a recovery; and an unreachable directory.

import { readFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { connect as tlsConnect } from "node:tls";
import { HANDHELD, measure, unmet } from "../browser/handheld.mjs";
import {
  A, A2, H, SETTINGS, addSession, admitted, assertions, ask, authenticatorWith, begin, captureAssertions, closePrompt,
  confirmFromHere, confirmHere, connected, continueAtHub, counted, credentialsFor, crossSiteHeld, deviceLog, flashed,
  freshContext, glassState, instrumentDevice, layer, nameHome, open, passkeySignIn, ready, record, row,
  secrets, signIn, signInAtHome, signInAtHub, sleep, storageOf, storedDevice, waitFor,
} from "./common.mjs";

const b64url = (object) => Buffer.from(JSON.stringify(object)).toString("base64url");
const settingsAt = (base, slug) => `${base}/a/${encodeURIComponent(slug)}/settings`;
const shellAt = (base, slug) => `${base}/a/${encodeURIComponent(slug)}/tinctures`;
const seconds = (ms) => Math.round(ms / 100) / 10;

// The person's state at H, through run.sh.
const atHub = (identifier) => ask({ op: "h_person", identifier });
const receiptsAtHub = async (identifier) => (await ask({ op: "h_receipts", identifier })).receipts.length;
const carryActions = async (cell, identifier) => (await ask({ op: "carry_actions", cell, identifier })).actions;

// A page at H that a signed-out session lands back on.
async function signedOut(page, url) {
  await page.goto(url);
  return new URL(page.url()).pathname === "/login";
}

// Poll `check` every two seconds until it holds or `limitMs` passes:
// the milliseconds it took, or null.
async function within(check, limitMs) {
  const started = Date.now();
  while (Date.now() - started <= limitMs) {
    if (await check()) return Date.now() - started;
    await sleep(2_000);
  }
  return null;
}

// The browser's own request `request` sent to its home through the
// harness's proxy and TLS front, as the browser would send it, and its
// answer read and dropped: the request reaches the home and commits, and
// the browser never sees the answer. Answers the answer's status.
async function sentAndDropped(proxy, request) {
  const target = new URL(request.url());
  const headers = await request.allHeaders();
  const body = request.postData() || "";
  return new Promise((resolve, reject) => {
    const tunnel = httpRequest({ host: "127.0.0.1", port: proxy.address().port, method: "CONNECT", path: `${target.hostname}:443` });
    tunnel.on("connect", (_res, socket) => {
      const tls = tlsConnect({ socket, servername: target.hostname, ca: readFileSync("/authority/authority.pem") }, () => {
        const lines = [`${request.method()} ${target.pathname}${target.search} HTTP/1.1`, `host: ${target.host}`];
        for (const [name, value] of Object.entries(headers)) {
          if (!["host", "content-length", "connection"].includes(name.toLowerCase()) && !name.startsWith(":")) lines.push(`${name}: ${value}`);
        }
        lines.push(`content-length: ${Buffer.byteLength(body)}`, "connection: close", "", "");
        tls.write(lines.join("\r\n"));
        tls.write(body);
      });
      let answer = "";
      tls.on("data", (chunk) => { answer += chunk.toString("latin1"); });
      tls.on("end", () => resolve(Number(answer.split(" ")[1])));
      tls.on("error", reject);
    });
    tunnel.on("error", reject);
    tunnel.end();
  });
}

// Every request of another client's this page's layer shows, cancelled.
async function cancelOthers(page) {
  const other = `${layer}[open] [data-test="confirmation"][data-own="false"] [data-test="confirm-cancel"]`;
  for (let i = 0; i < 5 && (await page.locator(other).count()); i++) {
    await page.locator(other).first().click();
    await page.waitForTimeout(1_000);
  }
}

// ---------------------------------------------------------------------------

async function crafted(chromium, { home, identifier }) {
  const before = { receipts: await receiptsAtHub(identifier), person: await atHub(identifier), actions: (await carryActions("a", identifier)).length };

  // At A, a link naming a challenge for no action of the person's, and a
  // carry meant for a destination's page.
  const challenge = b64url({ protocol: "cyfr-carry/v1", action_id: "car_crafted", audience: H, challenge: Buffer.alloc(32, 9).toString("base64url") });
  await open(home.desk, `${A}/carry#${challenge}`);
  await home.desk.waitForFunction(() => /nothing was signed/.test(document.body.innerText), null, { timeout: 30_000 });
  const atA = await home.desk.locator('[data-test="carry-notice"]').innerText();

  // At H, a carry no gesture asked for, and an assertion for no
  // challenge this browser holds.
  const context = await freshContext(chromium);
  const page = await context.newPage();
  await page.goto(`${H}/login#carry=${b64url({ envelope: { source: A }, payload: {} })}`);
  await connected(page);
  await page.waitForFunction(() => /did not ask for/.test(document.body.innerText), null, { timeout: 30_000 });
  await page.goto(`${H}/login#cyfr=${b64url({ assertion: {}, genesis: {} })}`);
  await page.waitForURL((url) => url.pathname === "/login" && !url.hash, { timeout: 30_000 }).catch(() => null);
  await sleep(2_000);
  const signedIn = !(await signedOut(page, `${H}/a/pair/settings`));
  await context.close();

  const after = { receipts: await receiptsAtHub(identifier), person: await atHub(identifier), actions: (await carryActions("a", identifier)).length };
  const confirmations = (await ask({ op: "confirmations", cell: "a", identifier })).confirmations.filter((c) => c.state === "pending");
  record.crafted = {
    at_a: atA.trim(), signed_in_at_h: signedIn, receipts: [before.receipts, after.receipts],
    sessions: [before.person.sessions.length, after.person.sessions.length], actions: [before.actions, after.actions],
    pending_confirmations_at_a: confirmations.length,
  };
  return row("crafted", "chromium",
    !signedIn && after.receipts === before.receipts && after.person.sessions.length === before.person.sessions.length &&
      after.actions === before.actions && confirmations.length === 0,
    "a crafted carry link at A or H writes nothing: no action, confirmation, receipt or session",
    record.crafted);
}

async function copiedSession(chromium, { home, identifier }) {
  const cookie = (await home.deskContext.cookies(A)).find((c) => c.name === "_cyfr_key");
  secrets.push(cookie.value);
  const before = { receipts: await receiptsAtHub(identifier) };

  // A copy of the person's session at A, in a browser holding none of
  // their passkeys, begins a sign-in at H: A asks for a fresh proof the
  // copy cannot give, and signs nothing.
  const context = await freshContext(chromium);
  const page = await context.newPage();
  await authenticatorWith(page);
  await context.addCookies([cookie]);
  await nameHome(page, A);
  await begin(page, A);
  await continueAtHub(page);
  await page.waitForURL((url) => url.origin === A && url.pathname === "/carry", { timeout: 60_000 });
  const own = `${layer} [data-test="confirmation"][data-own="true"]`;
  await page.waitForSelector(`${own} [data-test="confirm-passkey"]`, { timeout: 60_000 });
  await page.locator(`${own} [data-test="confirm-passkey"]`).click();
  await sleep(3_000);
  const actions = await carryActions("a", identifier);
  const last = actions[actions.length - 1];

  // The copy at H: a cookie of A's is no session there.
  await context.addCookies([{
    name: cookie.name, value: cookie.value, domain: new URL(H).hostname, path: "/", httpOnly: true, secure: true, sameSite: "Lax",
  }]);
  const atH = !(await signedOut(page, `${H}/a/pair/settings`));
  await context.close();

  // The person's own glass at A saw the request the copy made; it is
  // cancelled there.
  const glassShown = await home.glass.locator('[data-test="glass-prompt"]').count();
  record.copied_session = {
    asserted: last && last.asserted, receipts: [before.receipts, await receiptsAtHub(identifier)],
    signed_in_at_h: atH, shown_on_the_persons_glass: glassShown,
  };
  for (const ref of await home.glass.$$eval('[data-test="glass-prompt"]', (els) => els.map((e) => e.getAttribute("data-ref")))) {
    await home.glass.locator(`[data-test="glass-prompt"][data-ref="${ref}"] [data-test="glass-cancel"]`).click().catch(() => null);
  }
  return row("copied_session", "chromium",
    last && !last.asserted && record.copied_session.receipts[0] === record.copied_session.receipts[1] && !atH,
    "a copied A session obtains no assertion for H (its fresh proof cannot be given) and is no session at H",
    record.copied_session);
}

async function droppedCallback(chromium, state) {
  const { home, identifier } = state;
  const before = { receipts: await receiptsAtHub(identifier), sessions: (await atHub(identifier)).sessions.length };
  const context = await freshContext(chromium);
  const page = await context.newPage();
  await authenticatorWith(page, await credentialsFor(home.desk, new URL(A).host));

  // The callback reaches H and commits, and its answer never reaches the
  // browser.
  let dropped = null;
  await page.route(`${H}/auth/cyfr/callback`, async (route) => {
    dropped = await sentAndDropped(state.proxy, route.request());
    await route.abort("connectionreset");
  });
  await nameHome(page, A);
  await signInAtHome(page, A);
  await begin(page, A);
  await continueAtHub(page);
  await page.waitForURL((url) => url.origin === A && url.pathname === "/carry", { timeout: 60_000 });
  await confirmHere(page);
  await waitFor(() => dropped !== null, { timeoutMs: 60_000, what: "the dropped callback" });
  await page.unroute(`${H}/auth/cyfr/callback`);
  const afterDrop = { receipts: await receiptsAtHub(identifier), sessions: (await atHub(identifier)).sessions.length };

  // The browser retries: back at H, naming A again resumes the exchange it
  // holds the challenge of; A answers the assertion it recorded, and H
  // answers the session it made, never a second admission.
  await nameHome(page, A);
  await page.waitForURL((url) => url.origin === A && url.pathname === "/carry", { timeout: 60_000 });
  await connected(page);
  const continued = page.locator('[data-test="carry-continue"] button', { hasText: "Continue" });
  if (await continued.count()) await continued.click();
  await admitted(page);
  const retried = { receipts: await receiptsAtHub(identifier), sessions: (await atHub(identifier)).sessions.length };
  const signedIn = !(await signedOut(page, `${H}/a/pair/settings`));
  await context.close();
  record.dropped_callback = { dropped_status: dropped, before, after_drop: afterDrop, after_retry: retried, signed_in: signedIn };
  return row("dropped_callback", "chromium",
    dropped === 303 && afterDrop.receipts === before.receipts + 1 && retried.receipts === afterDrop.receipts &&
      retried.sessions === afterDrop.sessions && signedIn,
    "a callback committed with its answer dropped: the browser's retry is answered the session it made, never another admission",
    record.dropped_callback);
}

async function closedHops(chromium, { home, identifier }) {
  const outcomes = {};
  for (const hop of ["begun", "challenged", "asserted"]) {
    const before = await receiptsAtHub(identifier);
    const context = await freshContext(chromium);
    let page = await context.newPage();
    await authenticatorWith(page, await credentialsFor(home.desk, new URL(A).host));
    await nameHome(page, A);
    await signInAtHome(page, A);
    await begin(page, A);
    if (hop === "challenged") await continueAtHub(page);
    if (hop === "asserted") {
      await continueAtHub(page);
      await page.waitForURL((url) => url.origin === A && url.pathname === "/carry", { timeout: 60_000 });
      // The assertion is made, and the tab closes before H is reached.
      await page.route(`${H}/login`, (route) => route.abort());
      await confirmHere(page);
      await waitFor(async () => (await carryActions("a", identifier)).some((a) => a.asserted && a.phase === "delivered"), { timeoutMs: 30_000, stepMs: 500, what: "the assertion" });
    }
    await sleep(1_000);
    await page.close();

    // A new tab of the same browser: the person names A at H again.
    page = await context.newPage();
    await authenticatorWith(page, await credentialsFor(home.desk, new URL(A).host));
    await nameHome(page, A);
    await page.waitForURL((url) => url.origin === A && url.pathname === "/carry", { timeout: 60_000 });
    await connected(page);
    if (hop === "begun") {
      // Nothing durable named H's challenge yet: the carry begins again.
      await begin(page, A);
      await continueAtHub(page);
      await page.waitForURL((url) => url.origin === A && url.pathname === "/carry", { timeout: 60_000 });
      await connected(page);
    }
    // The closed tab's own request, if it opened one, shows here as
    // another client's; the person cancels it and continues.
    await page.waitForTimeout(1_500);
    await cancelOthers(page);
    const continued = page.locator('[data-test="carry-continue"] button', { hasText: "Continue" });
    if (await continued.count()) await continued.click();
    // An assertion already made is answered again with no new proof;
    // otherwise the person confirms this one.
    if (hop !== "asserted") await confirmHere(page);
    await admitted(page);
    const after = await receiptsAtHub(identifier);
    outcomes[hop] = { admissions: after - before };
    await context.close();
  }
  record.closed_hops = outcomes;
  return row("closed_hops", "chromium", Object.values(outcomes).every((o) => o.admissions === 1),
    "a tab closed after each hop of the carry: a new tab resumes it, and it ends in one admission",
    record.closed_hops);
}

async function forgedCompletion(chromium, { home, identifier, hub }) {
  const before = { person: await atHub(identifier), receipts: await receiptsAtHub(identifier) };
  // A pending carry of the person's, never taken to H, and a return
  // fragment no home sent saying it was admitted.
  await open(home.desk, `${A}/carry`);
  await home.desk.locator("#carry-destination").fill(H);
  await home.desk.route(`${H}/**`, (route) => route.abort());
  await home.desk.locator('#carry-begin button[type="submit"]').click();
  await sleep(2_000);
  await home.desk.unroute(`${H}/**`);
  const pending = (await carryActions("a", identifier)).filter((a) => a.phase === "pending").pop();
  const forged = b64url({ protocol: "cyfr-carry/v1", action_id: pending.action_id, outcome: "admitted" });
  await open(home.desk, `${A}/carry#${forged}`).catch(() => null);
  await sleep(3_000);
  const unknown = b64url({ protocol: "cyfr-carry/v1", action_id: "car_nobody", outcome: "admitted" });
  await open(home.desk, `${A}/carry#${unknown}`);
  await sleep(2_000);
  const stored = { h: null, a: await storageOf(home.desk) };
  const after = { person: await atHub(identifier), receipts: await receiptsAtHub(identifier) };
  record.forged_completion = {
    memberships: [before.person.memberships, after.person.memberships], receipts: [before.receipts, after.receipts],
    sessions: [before.person.sessions.length, after.person.sessions.length], storage_at_a: stored.a,
  };
  return row("forged_completion", "chromium",
    JSON.stringify(after.person.memberships) === JSON.stringify(before.person.memberships) &&
      after.receipts === before.receipts && after.person.sessions.length === before.person.sessions.length &&
      stored.a.local.every((key) => /consecutive-reloads/.test(key)) && stored.a.indexeddb.length === 0,
    "a forged completion writes no membership, admission or saved address at either home",
    record.forged_completion);
}

// The operator at H, signed in by the release fixture's door, with their
// own first passkey there.
async function operator(chromium) {
  const { cookie, segment } = await ask({ op: "admin_cookie" }, { secret: true });
  secrets.push(cookie);
  const context = await freshContext(chromium);
  await addSession(context, H, cookie);
  const page = await context.newPage();
  await authenticatorWith(page);
  await open(page, settingsAt(H, segment));
  await page.locator('[data-test="passkey-register"]').click();
  await flashed(page, "Passkey registered.");
  await counted();
  return { page, context, segment };
}

// The operator authorizes the person's exact pending registration, with a
// fresh proof of their own given in their browser.
async function authorize(admin, userId) {
  const asked = await ask({ op: "recover_admin", user_id: userId });
  if (!asked.asked) return { asked };
  await open(admin.page, settingsAt(H, admin.segment), { close: false });
  const preview = await confirmFromHere(admin.page);
  const repeated = await ask({ op: "recover_admin_repeat", tolerate: true });
  return { asked: true, preview, repeated: repeated.ok ? Object.keys(repeated.ok) : repeated };
}

async function hubPasskey(chromium, state) {
  const { identifier, hubPage } = state;
  const person = await atHub(identifier);
  await authenticatorWith(hubPage);
  await open(hubPage, settingsAt(H, "pair"));
  await hubPage.locator('[data-test="passkey-register"]').click();
  await flashed(hubPage, "administrator authorizes");
  await counted();
  const pending = (await atHub(identifier)).passkeys;

  // Sign-in alone activates nothing: the pending passkey signs nobody in.
  const probe = await freshContext(chromium);
  const probePage = await probe.newPage();
  await authenticatorWith(probePage, await credentialsFor(hubPage, new URL(H).host));
  await probePage.goto(`${H}/login`);
  await connected(probePage);
  await ready(probePage);
  await probePage.locator("#passkey-sign-in [data-webauthn-start]").click();
  await sleep(3_000);
  const pendingSignedIn = new URL(probePage.url()).pathname !== "/login";
  await probe.close();

  state.admin = await operator(chromium);
  const authorized = await authorize(state.admin, person.user_id);
  const after = (await atHub(identifier)).passkeys;
  record.h_passkey = { pending: pending.map((p) => p.state), pending_signed_in: pendingSignedIn, authorized, after: after.map((p) => p.state) };
  return row("h_passkey", "chromium",
    pending.length === 1 && pending[0].state === "pending" && !pendingSignedIn && authorized.asked &&
      after.length === 1 && after[0].state === "active",
    "a passkey registered at H from a CYFR-door session waits: signing in activates nothing; H's operator authorizes that exact registration under their own fresh proof",
    record.h_passkey);
}

async function aPasskeyAtHub(chromium, { home, identifier }) {
  const before = (await atHub(identifier)).sessions.length;
  const context = await freshContext(chromium);
  const page = await context.newPage();
  await authenticatorWith(page, await credentialsFor(home.desk, new URL(A).host));
  await page.goto(`${H}/login`);
  await connected(page);
  await ready(page);
  await page.locator("#passkey-sign-in [data-webauthn-start]").click();
  await page.waitForFunction(() => /did not (sign you in|finish)/.test(document.body.innerText), null, { timeout: 30_000 }).catch(() => null);
  const said = await page.locator("body").innerText();
  const stillOut = new URL(page.url()).pathname === "/login";
  await context.close();
  const after = (await atHub(identifier)).sessions.length;
  record.a_passkey_at_h = { refused: stillOut, sessions: [before, after], said: /did not (sign you in|finish)/.exec(said)?.[0] || null };
  return row("a_passkey_at_h", "chromium", stillOut && before === after,
    "a passkey scoped to A signs nobody in at H",
    record.a_passkey_at_h);
}

// The person pairs a phone at H's pair athanor: the phone takes them to
// A to certify it, and comes back with A's certificate.
async function pairPhone(chromium, { page, home, base = A, credentialsFrom, viewport, step }) {
  await open(page, shellAt(H, "pair"));
  await page.locator("#shell-devices").click();
  await page.waitForSelector(`${layer} [data-test="pairing"]`, { timeout: 30_000 });
  await page.locator(`${layer} [data-test="pairing-begin"]`).click();
  await confirmHere(page);
  await page.waitForSelector(`${layer} [data-test="pairing-link"]`, { timeout: 30_000 });
  const link = await page.locator(`${layer} [data-test="pairing-link"]`).inputValue();
  await closePrompt(page);
  secrets.push(link.split("#code=")[1]);

  const context = await freshContext(chromium, viewport || { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  await context.addInitScript(instrumentDevice);
  const phone = await context.newPage();
  await authenticatorWith(phone, await credentialsFor(credentialsFrom, new URL(base).host));
  const measured = {};
  await phone.goto(link);
  await phone.waitForSelector('[data-test="glass-status"][data-state="certify"]', { timeout: 60_000 });
  const pending = (await storedDevice(phone)).pending;
  if (viewport) measured.glass_certify = await measure(phone, "#glass");
  await phone.locator('[data-test="glass-home"]').fill(new URL(base).host);
  await phone.locator('[data-test="glass-home-submit"]').click();

  // At the person's home: signed in by passkey, through its sign-in page.
  await phone.waitForURL((url) => url.origin === base && url.pathname === "/login", { timeout: 60_000 });
  await passkeySignIn(phone, base);
  await phone.waitForURL((url) => url.origin === base && url.pathname === "/carry", { timeout: 60_000 });
  await phone.waitForSelector('[data-test="carry-certify"]', { timeout: 60_000 });
  const panel = await phone.locator('[data-test="carry-certify"]').innerText();
  if (viewport) measured.certify_panel = await measure(phone, '[data-test="carry-certify"]');
  await phone.locator('[data-test="certify-continue"]').click();
  const own = `${layer} [data-test="confirmation"][data-own="true"]`;
  await phone.waitForSelector(`${own} [data-test="confirm-passkey"]`, { timeout: 60_000 });
  if (viewport) measured.consent_prompt = await measure(phone, layer);
  const preview = await confirmHere(phone);

  // Back at H with the certificate, the glass pairs and connects.
  await phone.waitForURL((url) => url.origin === H && url.pathname === "/pair", { timeout: 60_000 });
  await phone.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });
  if (viewport) measured.glass_ready = await measure(phone, "#glass");
  const stored = await storedDevice(phone);
  return { phone, context, pending, panel, preview, stored, measured, step };
}

async function phoneStep(chromium, state) {
  const { home, identifier, hubPage } = state;
  const paired = await pairPhone(chromium, { page: hubPage, home, credentialsFrom: home.desk });
  state.phone = paired;
  const cert = paired.stored.device && paired.stored.device.certificate;
  const certifications = (await ask({ op: "certifications", cell: "a" })).certifications;
  const clients = (await ask({ op: "paired", cell: "h", identifier })).paired;
  record.phone = {
    pending_kept: paired.pending && { certify: paired.pending.certify }, panel: paired.panel.slice(0, 300),
    preview: paired.preview.slice(0, 300), issuer: cert && cert.issuer, audience: cert && cert.audience,
    subject: cert && cert.subject && cert.subject.kind, certifications, clients,
    pending_after: paired.stored.pending,
  };
  return row("phone", "chromium",
    cert && cert.issuer === A && cert.audience === H && cert.subject.kind === "identity" &&
      certifications.length === 1 && certifications[0].audience === H && clients.some((c) => c.standing === "active") &&
      paired.stored.pending === null && /person\.certify/.test(paired.preview),
    "a phone pairs at H under A's certificate: it keeps its code while the person certifies it at A under a fresh proof there, and comes back",
    record.phone);
}

async function renewal(chromium, proxy, state) {
  const { phone } = state.phone;
  const first = (await storedDevice(phone)).device.certificate;
  const mark = proxy.seen.length;
  const renewed = await waitFor(async () => {
    const held = (await storedDevice(phone)).device;
    return held && held.certificate.expires_at > first.expires_at ? held.certificate : null;
  }, { timeoutMs: (SETTINGS.cert_seconds + 30) * 1000, stepMs: 1_000, what: "the renewed certificate" }).catch(() => null);
  await phone.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 }).catch(() => null);
  const calls = proxy.seen.slice(mark).filter((r) => r.host === new URL(A).host && new URL(r.url).pathname === "/certify/v1/renew");
  const posts = calls.filter((r) => r.method === "POST");
  const cross = crossSiteHeld(calls);
  record.renewal = {
    renewed: !!renewed, posts: posts.map((r) => ({ status: r.status, site: r.fetch.site, origin: r.origin, cookie: r.cookie })),
    preflights: calls.filter((r) => r.method === "OPTIONS").length, cross_site: cross, state: await glassState(phone),
  };
  return row("renewal", "chromium",
    renewed && posts.length >= 2 && posts.every((r) => r.status === 200 && !r.cookie && r.origin === H) && cross.held &&
      record.renewal.state === "ready",
    "at half its life the phone renews at A by fetch, proving its key, with no cookie and no confirmation, and connects to H under the replacement",
    record.renewal);
}

async function thread(state) {
  const { identifier, hub } = state;
  const person = await atHub(identifier);
  const posted = await ask({ op: "post", user_id: person.user_id, athanor_id: hub.pair.athanor_id, text: "Hello from my own home" });
  const read = await ask({ op: "read", athanor_id: hub.pair.athanor_id, thread_id: posted.thread_id });
  record.thread = { posted: !!posted.thread_id, read: read.texts };
  return row("thread", "chromium", read.texts.includes("Hello from my own home"),
    "the person posts in the pair athanor's thread at H, and it reads there", record.thread);
}

async function removal(state) {
  const { identifier, hub, hubPage, home } = state;
  const removed = await ask({ op: "remove", identifier, athanor_id: hub.group.athanor_id, tolerate: true });
  const person = await atHub(identifier);
  const inGroup = await ask({ op: "post", user_id: person.user_id, athanor_id: hub.group.athanor_id, text: "after removal" });
  const inPair = await ask({ op: "post", user_id: person.user_id, athanor_id: hub.pair.athanor_id, text: "still here" });
  const groupPage = !(await signedOut(hubPage, settingsAt(H, hub.group.slug)));
  const groupUrl = hubPage.url();
  const pairPage = !(await signedOut(hubPage, settingsAt(H, "pair")));
  await open(home.desk, home.settings);
  const aUsable = new URL(home.desk.url()).pathname.endsWith("/settings");
  const phoneState = state.phone ? await glassState(state.phone.phone) : null;
  record.removal = {
    removed: removed.ok ? true : removed, memberships: person.memberships, post_in_group: inGroup, post_in_pair: !!inPair.thread_id,
    group_page: groupUrl.replace(H, ""), pair_page: pairPage, a_usable: aUsable, phone: phoneState,
  };
  return row("removal", "chromium",
    !!removed.ok && !person.memberships.includes(hub.group.athanor_id) && person.memberships.includes(hub.pair.athanor_id) &&
      inGroup.refused && !!inPair.thread_id && !groupUrl.includes(`/a/${hub.group.slug}/settings`) && pairPage && aUsable &&
      phoneState === "ready",
    "removed from H's group athanor, the person's standing there is retired, while the pair athanor, the phone paired there and A stay usable",
    record.removal);
}

async function rotate(chromium, state) {
  const { home, identifier, hubPage } = state;
  const before = await ask({ op: "a_head" });
  const mark = (await deviceLog(state.phone.phone)).length;
  await open(home.desk, home.settings);
  await home.desk.locator('[data-test="identity-rotate"]').click();
  await confirmHere(home.desk);
  await flashed(home.desk, "Your live key was rotated.");
  const rotatedAt = Date.now();
  const after = await ask({ op: "a_head" });

  // H retires the sessions bound to the old key_epoch within its bound.
  const retiredMs = await within(() => signedOut(hubPage, settingsAt(H, "pair")), (SETTINGS.fresh + 30) * 1000);
  const passkeys = (await atHub(identifier)).passkeys;

  // The H passkey stays, and signs the person in again.
  await hubPage.goto(`${H}/login`);
  await connected(hubPage);
  await passkeySignIn(hubPage, H);
  const back = !(await signedOut(hubPage, settingsAt(H, "pair")));

  // A CYFR-door session alone activates no new passkey here: a fresh
  // proof is asked for first.
  const fresh = await signIn(chromium, "chromium", state.proxy, { home: A, identifier, passkeysFrom: home.desk, step: "rotate_sign_in" }).catch((error) => ({ error }));
  let asked = null;
  if (fresh.page) {
    await authenticatorWith(fresh.page);
    await open(fresh.page, settingsAt(H, "pair"));
    await fresh.page.locator('[data-test="passkey-register"]').click();
    asked = await fresh.page.waitForSelector(`${layer} [data-test="confirmation"][data-own="true"]`, { timeout: 30_000 }).then(() => true).catch(() => false);
    await fresh.context.close();
  }
  const passkeysAfter = (await atHub(identifier)).passkeys;
  record.rotate = {
    head_moved: before.head !== after.head, retired_after_s: retiredMs === null ? null : seconds(retiredMs), bound_s: SETTINGS.fresh,
    passkeys: passkeys.map((p) => p.state), passkey_signs_in: back, new_registration_asks_fresh_proof: asked,
    passkeys_after: passkeysAfter.map((p) => p.state), rotated_at: rotatedAt,
  };
  state.phoneMark = mark;
  return row("rotate", "chromium",
    record.rotate.head_moved && retiredMs !== null && retiredMs <= (SETTINGS.fresh + 30) * 1000 &&
      passkeys.some((p) => p.state === "active") && back && asked === true &&
      passkeysAfter.filter((p) => p.state === "active").length === 1,
    "after A rotates the live key, H retires its old-epoch sessions within its bound; its passkey stays and signs in; a CYFR-door session's new passkey asks for a fresh proof",
    record.rotate);
}

async function recertify(state) {
  const { phone } = state.phone;
  // H refuses the certificate chained to the old key; A ends its
  // certification; the phone offers to certify again.
  await phone.waitForSelector('[data-test="glass-status"][data-state="recertify"]', { timeout: (SETTINGS.fresh + 90) * 1000 });
  const log = (await deviceLog(phone)).slice(state.phoneMark || 0);
  const prefilled = await phone.locator('[data-test="glass-home"]').inputValue();
  await phone.locator('[data-test="glass-home-submit"]').click();
  await phone.waitForURL((url) => url.origin === A && url.pathname === "/carry", { timeout: 60_000 });
  await phone.waitForSelector('[data-test="carry-certify"]', { timeout: 60_000 });
  await phone.locator('[data-test="certify-continue"]').click();
  await confirmHere(phone);
  await phone.waitForURL((url) => url.origin === H && url.pathname === "/pair", { timeout: 60_000 });
  await phone.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });
  const cert = (await storedDevice(phone)).device.certificate;
  const head = await ask({ op: "a_head" });
  record.recertify = {
    closes: log.filter((e) => e.event === "close").map((e) => e.code), prefilled,
    key_epoch_current: cert.subject.key_epoch === head.head,
  };
  return row("recertify", "chromium",
    record.recertify.closes.includes(4408) && prefilled === A && record.recertify.key_epoch_current,
    "the phone's certificate ends with the old key: the renewal at A is refused, and the phone is certified again there under a fresh proof, naming A's new key_epoch",
    record.recertify);
}

async function tabs(state) {
  const { home, identifier } = state;
  // A sign-in begun for H in one tab of A, while another tab works at H.
  const tab = await home.deskContext.newPage();
  await open(tab, `${A}/carry`);
  await tab.locator("#carry-destination").fill(H);
  await tab.route(`${H}/**`, (route) => route.abort());
  await tab.locator('#carry-begin button[type="submit"]').click();
  await sleep(2_000);
  await tab.unroute(`${H}/**`);
  const other = await home.deskContext.newPage();
  await open(other, settingsAt(H, "pair")).catch(() => null);
  await open(home.desk, home.settings);
  await open(tab, `${A}/carry`);
  const listed = await tab.locator('[data-test="carry-pending"]').innerText().catch(() => "");
  const actions = (await carryActions("a", identifier)).filter((a) => a.phase === "pending");
  await tab.close();
  await other.close();
  record.tabs = { pending_destinations: [...new Set(actions.map((a) => a.destination))], listed: listed.includes(H) };
  return row("tabs", "chromium", actions.length >= 1 && actions.every((a) => a.destination === H) && record.tabs.listed,
    "switching tabs and homes leaves a running sign-in bound to the home it named", record.tabs);
}

async function restore(chromium, state) {
  const { home, identifier, kit2 } = state;
  // Before A is lost: a session at H by the H passkey, and a change at H
  // waiting for its confirmation.
  const passkeyContext = await freshContext(chromium);
  const passkeyPage = await passkeyContext.newPage();
  await authenticatorWith(passkeyPage, await credentialsFor(state.hubPage, new URL(H).host));
  await passkeyPage.goto(`${H}/login`);
  await connected(passkeyPage);
  await passkeySignIn(passkeyPage, H);
  await open(passkeyPage, shellAt(H, "pair"));
  await passkeyPage.locator("#shell-devices").click();
  await passkeyPage.waitForSelector(`${layer} [data-test="pairing"]`, { timeout: 30_000 });
  await passkeyPage.locator(`${layer} [data-test="pairing-begin"]`).click();
  await passkeyPage.waitForSelector(`${layer} [data-test="confirmation"][data-own="true"]`, { timeout: 30_000 });
  state.passkeySession = { passkeyContext, passkeyPage };

  // A is lost. H's work, a page of the person's there and the phone
  // paired there, goes on, bound to H.
  const down = await ask({ op: "a_down" });
  const hubPage = await state.hubContext.newPage();
  const hubUsable = !(await signedOut(hubPage, settingsAt(H, "pair")));
  await hubPage.close();
  const phoneState = await glassState(state.phone.phone);
  record.lost_home = { a_down: down.down, hub_page: hubUsable, phone_at_hub: phoneState };
  if (!row("lost_home", "chromium", down.down && hubUsable && phoneState === "ready",
    "with A lost, the person's work at H, a page there and the phone paired there, goes on bound to H",
    record.lost_home)) return false;

  // The person restores on A2 from the second kit's three lines.
  const { token } = await ask({ op: "token_a2" }, { secret: true });
  secrets.push(token);
  const context = await freshContext(chromium);
  const page = await context.newPage();
  await authenticatorWith(page);
  await page.goto(`${A2}/restore`);
  await connected(page);
  await page.locator('[data-test="restore-token"]').fill(token);
  await page.locator('[data-test="restore-identifier"]').fill(kit2.identifier);
  await page.locator('[data-test="restore-directory"]').fill(kit2.directory_url);
  await page.locator('[data-test="restore-secret"]').fill(kit2.recovery_secret);
  await page.locator('[data-test="restore-submit"]').click();
  await page.waitForSelector('[data-test="restore-status"]:not([data-state="idle"]):not([data-state="retry"])', { timeout: 180_000 });
  const restored = await page.locator('[data-test="restore-status"]').getAttribute("data-state");
  state.restoredAt = Date.now();
  const head = await ask({ op: "a2_head" });
  const { segment } = await ask({ op: "a2_segment" });

  // Their first passkey at A2, from the restore's own session.
  await open(page, settingsAt(A2, segment));
  await page.locator('[data-test="passkey-register"]').click();
  await flashed(page, "Passkey registered.");
  await counted();
  state.a2 = { page, context, segment };
  record.restore = { a_down: down.down, restored, identifier_kept: head.identifier === identifier };
  return row("restore", "chromium", down.down && restored === "completed" && head.identifier === identifier,
    "A lost, the person restores on an installation-authorized fresh node, A2, from the second kit's three lines",
    record.restore);
}

async function retired(chromium, state) {
  const { identifier, hub } = state;
  const { passkeyPage, passkeyContext } = state.passkeySession;
  // H retires every old-epoch session, the H passkey's included, within
  // its bound, as it reads the identity's new head.
  const retiredMs = await within(() => signedOut(passkeyPage, settingsAt(H, "pair")), (SETTINGS.fresh + 40) * 1000);
  const measuredFromRestore = retiredMs === null ? null : seconds(Date.now() - state.restoredAt);
  const person = await atHub(identifier);
  const confirmations = (await ask({ op: "confirmations", cell: "h", identifier })).confirmations;

  // The old H passkey signs nobody in.
  await passkeyPage.goto(`${H}/login`);
  await connected(passkeyPage);
  await ready(passkeyPage);
  await passkeyPage.locator("#passkey-sign-in [data-webauthn-start]").click();
  await sleep(3_000);
  const oldPasskeyIn = new URL(passkeyPage.url()).pathname !== "/login";
  await passkeyContext.close();

  // An old home's assertion, replayed at H, admits nobody.
  const before = { receipts: await receiptsAtHub(identifier), sessions: (await atHub(identifier)).sessions.length };
  const replay = await freshContext(chromium);
  const replayPage = await replay.newPage();
  const old = assertions[0];
  await replayPage.goto(`${H}/login#cyfr=${old}`);
  await sleep(4_000);
  const replayedIn = !(await signedOut(replayPage, settingsAt(H, "pair")));
  await replay.close();
  const after = { receipts: await receiptsAtHub(identifier), sessions: (await atHub(identifier)).sessions.length };

  // The person signs in at H naming their new home, A2.
  const fresh = await signIn(chromium, "chromium", state.proxy, { home: A2, identifier, passkeysFrom: state.a2.page, step: "a2_sign_in" });
  state.newHub = fresh;
  // The H passkey and the pairing its session left waiting are what the
  // recovery retires. Each must be recorded: the check of an empty list's
  // states holds of nothing.
  const waiting = confirmations.filter((c) => c.operation === "pairing.begin");
  record.retired = {
    retired_within_s: measuredFromRestore, bound_s: SETTINGS.fresh,
    passkeys: person.passkeys.map((p) => p.state), confirmations: confirmations.map((c) => `${c.operation}:${c.state}`),
    old_passkey_signs_in: oldPasskeyIn, replayed: { signed_in: replayedIn, receipts: [before.receipts, after.receipts], sessions: [before.sessions, after.sessions] },
    a2_sign_in: fresh.held,
  };
  return row("retired", "chromium",
    retiredMs !== null && person.passkeys.length > 0 && person.passkeys.every((p) => p.state === "revoked") &&
      waiting.length > 0 && waiting.every((c) => c.state !== "pending") &&
      !oldPasskeyIn && !replayedIn && after.receipts === before.receipts && fresh.held,
    "after the recovery H retires every old-epoch session, the H passkey's included, within its bound; the old passkey and confirmation are retired, an old assertion replays nothing, and the person signs in naming A2",
    record.retired);
}

async function adminAgain(chromium, state) {
  const { identifier } = state;
  const page = state.newHub.page;
  await authenticatorWith(page);
  await open(page, settingsAt(H, "pair"));
  await page.locator('[data-test="passkey-register"]').click();
  await flashed(page, "administrator authorizes");
  await counted();
  const person = await atHub(identifier);
  const pending = person.passkeys.filter((p) => p.state === "pending");
  const authorized = await authorize(state.admin, person.user_id);
  const after = (await atHub(identifier)).passkeys.filter((p) => p.state === "active");
  record.admin_again = { pending: pending.length, authorized, active: after.length };
  return row("admin_again", "chromium", pending.length === 1 && authorized.asked && after.length === 1,
    "after the recovery, a new passkey at H again needs a new recorded authorization by H's operator",
    record.admin_again);
}

async function viewport(chromium, state) {
  const page = state.newHub.page;
  const paired = await pairPhone(chromium, {
    page, base: A2, credentialsFrom: state.a2.page, viewport: HANDHELD, step: "viewport",
  });
  const { phone } = paired;
  const measured = { ...paired.measured };

  // Reconnecting: the page opened again connects under the stored device.
  // Opened by its address, not reloaded: a reload repeats the referrer of
  // the cross-site hop that first brought the page, as its own request.
  await phone.goto(`${H}/pair`);
  await phone.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });
  measured.reconnected = await measure(phone, "#glass");

  // Switching homes: to the person's home and back.
  await phone.goto(`${A2}/`);
  await connected(phone).catch(() => null);
  measured.other_home = await measure(phone);
  await phone.goto(`${H}/pair`);
  await phone.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });

  // Revocation, from H's Devices under H's passkey: the phone reads the
  // request on its glass first, then hears its pairing end.
  await open(page, shellAt(H, "pair"));
  await page.locator("#shell-devices").click();
  await page.waitForSelector(`${layer} [data-test="pairing"]`, { timeout: 30_000 });
  await page.locator(`${layer} [data-test="pairing-revoke"]`).last().click();
  const shown = await phone.waitForSelector('[data-test="glass-prompt"]', { timeout: 60_000 }).then(() => true).catch(() => false);
  if (shown) measured.glass_prompt = await measure(phone, "#glass");
  await confirmHere(page);
  await phone.waitForSelector('[data-test="glass-status"][data-state="revoked"]', { timeout: 60_000 });
  measured.revoked = await measure(phone, "#glass");

  // The glass's and the prompts' screens are what the check holds, the
  // glass's own prompt for the revocation among them; the other home's
  // console page is measured and recorded as a finding.
  const { other_home: otherHome, ...held } = measured;
  const failures = unmet(held);
  record.viewport = { measured: held, glass_prompt_shown: shown, failures, finding_other_home_console: otherHome };
  return row("viewport", "chromium", paired.stored.device && shown && failures.length === 0,
    "at 720×720: pairing, reconnecting, switching homes, revocation and a consent read and confirmed in the system layer, every control 24×24 CSS px or more, text 12 px or more, nothing overflowing",
    record.viewport);
}

async function directoryDown(state) {
  const { identifier, newHub } = state;
  const page = newHub.page;
  await ask({ op: "directory_fault", directory: "dir.test", mode: "down" });
  const downAt = Date.now();
  const answered = await ask({ op: "h_fresh", identifier });
  const usableWithin = !(await signedOut(page, settingsAt(H, "pair")));
  await sleep((SETTINGS.fresh + 5) * 1000);
  const past = await ask({ op: "h_fresh", identifier });

  // Past the bound the browser's protected work pauses: the page is not
  // served, and the sign-in page it lands on says why.
  await page.goto(settingsAt(H, "pair"));
  await page.waitForURL((url) => url.pathname === "/login", { timeout: 30_000 }).catch(() => null);
  await page.waitForFunction(() => /could not be confirmed fresh/.test(document.body.innerText), null, { timeout: 30_000 })
    .catch(() => null);
  const pastPage = await page.locator("body").innerText().catch(() => "");
  const pastPath = new URL(page.url()).pathname;
  await ask({ op: "directory_fault", directory: "dir.test", mode: "none" });

  // The directory back, the same session works again: a pause, not a
  // sign-out.
  const resumedMs = await within(async () => !(await signedOut(page, settingsAt(H, "pair"))), 30_000);
  const said = pastPage.split("\n").find((line) => /could not be confirmed fresh/.test(line)) || null;
  record.directory_down = {
    within: answered.key_epoch ? "fresh" : answered, usable_within: usableWithin, past: past.refused || past,
    past_page: pastPath, said, waited_s: seconds(Date.now() - downAt),
    resumed_after_s: resumedMs === null ? null : seconds(resumedMs),
  };
  return row("directory_down", "chromium",
    !!answered.key_epoch && usableWithin && past.refused === "identity_stale" &&
      pastPath === "/login" && said !== null && resumedMs !== null,
    "with A's directory down, H keeps the person's work within its bound, pauses the browser's protected work past it, saying why, and resumes it once the directory answers",
    record.directory_down);
}

// ---------------------------------------------------------------------------

export async function rest(chromium, proxy, { home, hub, hubPage, hubContext }) {
  const state = { home, hub, hubPage, hubContext, proxy, identifier: home.identifier, kit2: home.kit2 };
  const steps = [
    () => crafted(chromium, state),
    () => copiedSession(chromium, state),
    () => droppedCallback(chromium, state),
    () => closedHops(chromium, state),
    () => forgedCompletion(chromium, state),
    () => hubPasskey(chromium, state),
    () => aPasskeyAtHub(chromium, state),
    () => phoneStep(chromium, state),
    () => renewal(chromium, proxy, state),
    () => thread(state),
    () => removal(state),
    () => rotate(chromium, state),
    () => recertify(state),
    () => tabs(state),
    () => restore(chromium, state),
    () => retired(chromium, state),
    () => adminAgain(chromium, state),
    () => viewport(chromium, state),
    () => directoryDown(state),
  ];
  for (const step of steps) if (!(await step())) return;
}
