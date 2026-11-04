// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The join proof's steps after the sign-ins, Chromium's alone
// (README.md): what a crafted or forged link does, a copied session, a
// dropped answer and closed tabs; an invitation the person, who already
// has a name, accepts by signing in from their CYFR; a passkey and a
// phone at the hub; a removal, a rotation and a recovery; and an
// unreachable directory.

import { createHash, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { connect as tlsConnect } from "node:tls";
import { HANDHELD, measure, unmet } from "../browser/handheld.mjs";
import { firstPasskey } from "../browser/lib.mjs";
import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { commandLineActs, confirmAtHome, crossDevice, holdAssertion, recertify, terminalRenewal, terminalStep } from "./terminal.mjs";
import {
  A, A2, H, SETTINGS, addSession, admitted, assertions, ask, authenticatorWith, begin, captureAssertions, closePrompt,
  confirmFromHere, confirmHere, connected, continueAtHub, counted, credentialsFor, crossSiteHeld, flashed,
  confirmSignIn, freshContext, layer, nameHome, open, passkeySignIn, pressInLayer, ready, record, row,
  secrets, signIn, signInAtHome, signInAtHub, sleep, storageOf, waitFor,
} from "./common.mjs";

const b64url = (object) => Buffer.from(JSON.stringify(object)).toString("base64url");
const settingsAt = (base, slug) => `${base}/a/${encodeURIComponent(slug)}/settings`;
const shellAt = (base, slug) => `${base}/a/${encodeURIComponent(slug)}/canvas`;
// The person's own athanor at H, by its route: where they work there,
// read once they are admitted (`rest`).
let hubAthanor = null;
const seconds = (ms) => Math.round(ms / 100) / 10;

// The person's state at H, through run.sh.
const atHub = (identifier) => ask({ op: "h_person", identifier });
const receiptsAtHub = async (identifier) => (await ask({ op: "h_receipts", identifier })).receipts.length;
const carryActions = async (cell, identifier) => (await ask({ op: "carry_actions", cell, identifier })).actions;
const receiptRowsAtHub = async (identifier) => (await ask({ op: "h_receipts", identifier })).receipts;
const sameRows = (before, after) =>
  JSON.stringify(before.map((row) => JSON.stringify(row)).sort()) === JSON.stringify(after.map((row) => JSON.stringify(row)).sort());

// A page at H that a signed-out session lands back on.
async function signedOut(page, url) {
  await page.goto(url);
  return new URL(page.url()).pathname === "/login";
}

// The carry hook consumes a fragment only when it mounts.
async function refusedAssertion(page, fragment) {
  await page.goto("about:blank");
  const [response] = await Promise.all([
    page.waitForResponse((answer) => answer.url() === `${H}/auth/cyfr/callback` && answer.request().method() === "POST", { timeout: 30_000 }),
    page.goto(`${H}/login#cyfr=${fragment}`),
  ]);
  if (response.status() !== 401) throw new Error(`the assertion callback answered ${response.status()}, not a refusal`);
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
  const before = { receipts: await receiptRowsAtHub(identifier), person: await atHub(identifier), actions: await carryActions("a", identifier) };

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
  await refusedAssertion(page, b64url({ assertion: {}, genesis: {} }));
  const signedIn = !(await signedOut(page, settingsAt(H, hubAthanor)));
  await context.close();

  const after = { receipts: await receiptRowsAtHub(identifier), person: await atHub(identifier), actions: await carryActions("a", identifier) };
  const confirmations = (await ask({ op: "confirmations", cell: "a", identifier })).confirmations.filter((c) => c.state === "pending");
  record.crafted = {
    at_a: atA.trim(), signed_in_at_h: signedIn, receipts: [before.receipts, after.receipts],
    sessions: [before.person.sessions, after.person.sessions], actions: [before.actions, after.actions],
    pending_confirmations_at_a: confirmations.length,
  };
  return row("crafted", "chromium",
    !signedIn && sameRows(before.receipts, after.receipts) && sameRows(before.person.sessions, after.person.sessions) &&
      sameRows(before.actions, after.actions) && confirmations.length === 0,
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
  await flashed(page, "The passkey did not answer. Nothing was confirmed.");
  const actions = await carryActions("a", identifier);
  const last = actions[actions.length - 1];

  // The copy at H: a cookie of A's is no session there.
  await context.addCookies([{
    name: cookie.name, value: cookie.value, domain: new URL(H).hostname, path: "/", httpOnly: true, secure: true, sameSite: "Lax",
  }]);
  const atH = !(await signedOut(page, settingsAt(H, hubAthanor)));
  await context.close();

  // The person's own Prism at A, the page holding their passkey, shows the
  // request the copy made; it is cancelled there.
  const confirmer = home.confirmer;
  await confirmer.goto(`${A}/`);
  await connected(confirmer);
  const other = `${layer} [data-test="confirmation"][data-own="false"]`;
  await confirmer.waitForSelector(other, { timeout: 30_000 }).catch(() => null);
  const shownToPerson = await confirmer.locator(other).count();
  record.copied_session = {
    asserted: last && last.asserted, receipts: [before.receipts, await receiptsAtHub(identifier)],
    signed_in_at_h: atH, shown_in_the_persons_prism: shownToPerson,
  };
  for (let i = 0; i < 5 && (await confirmer.locator(`${other} [data-test="confirm-cancel"]`).count()); i++) {
    await confirmer.locator(`${other} [data-test="confirm-cancel"]`).first().click().catch(() => null);
    await confirmer.waitForTimeout(1_000);
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
  const signedIn = !(await signedOut(page, settingsAt(H, hubAthanor)));
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

async function forgedCompletion(chromium, { home, identifier, hubPage, hubContext }) {
  const savedAddress = (page) => page.evaluate(() => localStorage.getItem("cyfr:sign-in:your-cyfr"));
  const addressesBefore = { a: await savedAddress(home.desk), h: await savedAddress(hubPage) };
  const before = { person: await atHub(identifier), receipts: await receiptRowsAtHub(identifier) };
  // A pending carry of the person's, never taken to H, and a return
  // fragment no home sent saying it was admitted.
  await open(home.desk, `${A}/carry`);
  await home.desk.locator("#carry-destination").fill(H);
  await home.desk.route(`${H}/**`, (route) => route.abort());
  const blocked = home.desk.waitForEvent("requestfailed", {
    predicate: (request) => request.isNavigationRequest() && request.url().startsWith(`${H}/login`), timeout: 30_000,
  });
  await home.desk.locator('#carry-begin button[type="submit"]').click();
  await blocked;
  await home.desk.unroute(`${H}/**`);
  const pending = await waitFor(async () => (await carryActions("a", identifier)).filter((a) => a.phase === "pending").pop(),
    { timeoutMs: 30_000, what: "the pending carry" });
  const forged = b64url({ protocol: "cyfr-carry/v1", action_id: pending.action_id, outcome: "admitted" });
  await open(home.desk, `${A}/carry#${forged}`);
  await waitFor(async () =>
    (await carryActions("a", identifier)).some((action) => action.action_id === pending.action_id && action.phase === "completed") ||
      await home.desk.locator('[data-test="carry-notice"]').isVisible(),
    { timeoutMs: 30_000, what: "the forged completion's handled or refused outcome" });
  const unknown = b64url({ protocol: "cyfr-carry/v1", action_id: "car_nobody", outcome: "admitted" });
  await home.desk.goto("about:blank");
  await open(home.desk, `${A}/carry#${unknown}`);
  await home.desk.locator('[data-test="carry-notice"]').waitFor({ timeout: 30_000 });
  // H's storage in the browser that signed in there: the one address it
  // remembers for its sign-in page, and LiveView's reload counters.
  const atH = await hubContext.newPage();
  await atH.goto(`${H}/login`);
  const stored = { h: await storageOf(atH), a: await storageOf(home.desk) };
  const addressesAfter = { a: await savedAddress(home.desk), h: await savedAddress(atH) };
  await atH.close();
  const after = { person: await atHub(identifier), receipts: await receiptRowsAtHub(identifier) };
  const ownKeysAtH = stored.h.local.filter((key) => !/consecutive-reloads/.test(key));
  record.forged_completion = {
    athanors: [before.person.athanors, after.person.athanors], receipts: [before.receipts, after.receipts],
    sessions: [before.person.sessions, after.person.sessions], saved_addresses: [addressesBefore, addressesAfter],
    storage_at_a: stored.a, storage_at_h: stored.h,
  };
  return row("forged_completion", "chromium",
    JSON.stringify(after.person.athanors) === JSON.stringify(before.person.athanors) &&
      sameRows(before.receipts, after.receipts) && sameRows(before.person.sessions, after.person.sessions) &&
      JSON.stringify(addressesAfter) === JSON.stringify(addressesBefore) &&
      stored.a.local.every((key) => /consecutive-reloads/.test(key)) && stored.a.indexeddb.length === 0 &&
      JSON.stringify(ownKeysAtH) === JSON.stringify(["cyfr:sign-in:your-cyfr"]) && stored.h.indexeddb.length === 0,
    "a forged completion writes no athanor, admission or saved address at either home; H's storage holds only cyfr:sign-in:your-cyfr",
    record.forged_completion);
}

// An invitation link H's operator makes for a new group, opened in a
// browser that signs in at A: "Already have a CYFR name? Sign in with it."
// takes the code to H's sign-in page, the person signs in from A, and H
// seats them and writes the allow under their identifier, which states
// H's existing allow anew, naming the invitation (removing that allow
// first would eject the sessions later steps use); a later sign-in needs
// no link, and the link a second time is used.
async function invited(chromium, { home, identifier }) {
  const invitation = await ask({ op: "h_invitation", identifier }, { secret: true });
  const code = new URL(invitation.link).hash.slice(1);
  secrets.push(code);
  const doorBefore = await ask({ op: "h_door", identifier });
  const receiptsBefore = await receiptsAtHub(identifier);

  const context = await freshContext(chromium);
  const page = await context.newPage();
  await authenticatorWith(page, await credentialsFor(home.desk, new URL(A).host));
  await page.goto(invitation.link);
  await connected(page);
  const link = page.locator('[data-test="invite-sign-in"]');
  await link.waitFor({ timeout: 30_000 });
  const linkText = (await link.innerText()).trim();
  await link.click();
  await page.waitForURL((url) => url.origin === H && url.pathname === "/login", { timeout: 30_000 });
  await page.waitForSelector('[data-test="invitation"]', { timeout: 30_000 });
  const said = (await page.locator('[data-test="invitation"]').innerText()).trim();
  const codeOnPage = (await page.content()).includes(code);
  await nameHome(page, A, { at: null });
  await signInAtHome(page, A);
  await begin(page, A);
  await continueAtHub(page);
  await confirmSignIn(page, A, null);
  await admitted(page);
  await context.close();

  const person = await atHub(identifier);
  const doorAfter = await ask({ op: "h_door", identifier });
  const receiptsInvited = await receiptsAtHub(identifier);

  // A later sign-in with no link: the allow admits it.
  const later = await freshContext(chromium);
  const laterPage = await later.newPage();
  await authenticatorWith(laterPage, await credentialsFor(home.desk, new URL(A).host));
  await signInAtHub(laterPage, { home: A });
  await later.close();
  const receiptsLater = await receiptsAtHub(identifier);

  // The link again, in another browser: used.
  const again = await freshContext(chromium);
  const againPage = await again.newPage();
  await againPage.goto(invitation.link);
  await connected(againPage);
  const refused = await againPage.locator('[data-test="invite-refused"]').waitFor({ timeout: 30_000 }).then(() => true).catch(() => false);
  const refusedText = refused ? (await againPage.locator('[data-test="invite-refused"]').innerText()).trim() : null;
  await again.close();

  const allow = doorAfter.entries.find((entry) => entry.effect === "allow");
  record.invited = {
    door_before: doorBefore.entries, door_after: doorAfter.entries,
    link_text: linkText, said, code_on_sign_in_page: codeOnPage,
    seated: person.threads.includes(invitation.thread_id),
    admissions: [receiptsInvited - receiptsBefore, receiptsLater - receiptsInvited],
    second_use_refused: refused, second_use_said: refusedText,
  };
  return row("invited", "chromium",
    doorBefore.entries.length === 1 && !/^invitation /.test(doorBefore.entries[0].note || "") &&
      linkText === "Already have a CYFR name? Sign in with it." &&
      /Sign in from your CYFR to accept\.$/.test(said) && !codeOnPage && record.invited.seated &&
      doorAfter.entries.length === 1 && allow && allow.status === "allowed" && /^invitation inv_/.test(allow.note || "") &&
      receiptsInvited - receiptsBefore === 1 && receiptsLater - receiptsInvited === 1 &&
      refused && /can no longer be used/.test(refusedText || ""),
    "an invitation link opened in A's browser, taken through \"Already have a CYFR name? Sign in with it.\", seats the person in its shared thread and writes the allow under their identifier; a later sign-in needs no link; the link a second time is used",
    record.invited);
}

// The operator at H, signed in by the release fixture's door, with their
// own first passkey there: H's setup made them with a protected device,
// which confirms that registration (`firstPasskey`, the release fixture's
// `device_confirm`).
async function operator(chromium) {
  const { cookie, segment } = await ask({ op: "admin_cookie" }, { secret: true });
  secrets.push(cookie);
  const context = await freshContext(chromium);
  await addSession(context, H, cookie);
  const page = await context.newPage();
  const authenticator = await authenticatorWith(page);
  await open(page, settingsAt(H, segment));
  const registered = await firstPasskey(page, { ask, layer, authenticator });
  await counted();
  return { page, context, segment, registered };
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
  await open(hubPage, settingsAt(H, hubAthanor));
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

// The standing H holds for the command line paired there (`terminal`).
async function terminalStanding(state) {
  if (!state.terminal) return null;
  const clients = (await ask({ op: "paired", cell: "h", identifier: state.identifier })).paired;
  const found = clients.find((c) => c.id === state.terminal.clientId);
  return found ? found.standing : null;
}

// The command line paired at H, observed usable as a person uses it: its
// key record in its own directory, then unlocked there, a session of its
// own opened at H, and `cyfr whoami` acting through it
// (`commandLineActs`). No record, no unlock or a failed whoami is not
// usable; H's standing for it, beside, is recorded and proves nothing alone.
async function commandLineUsable(state) {
  const dir = state.terminal ? join(state.terminal.cliHome, ".cyfr", "devices") : null;
  const records = dir && existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith(".json")) : [];
  if (records.length === 0) return { usable: false, why: "no device record" };
  const acted = await commandLineActs(state.proxy, state);
  return { usable: acted.unlocked && acted.whoami_exit === 0 && acted.exit === 0, ...acted, standing: await terminalStanding(state) };
}

// A credential entry asked for on `page`'s vault at H: its own request,
// waiting on its confirmation. Answers its ref.
async function askEntryAtHub(page, name) {
  await open(page, `${H}/a/${encodeURIComponent(hubAthanor)}/vault`);
  if (!(await page.locator("#vault-create-form").isVisible().catch(() => false))) {
    await page.locator('button[phx-click="show_add"][phx-value-mode="fields"]').click();
  }
  const form = page.locator("#vault-create-form");
  await form.locator('select[name="kind"]').selectOption("api_key", { timeout: 30_000 });
  await form.locator('input[name="name"]').fill(name);
  await form.locator('textarea[name="fields"]').fill(`API_KEY=${name}-not-shown`);
  await form.locator('input[name="destination_hosts"]').fill("fixture.test");
  await form.locator('button[type="submit"]').click();
  const own = `${layer} [data-test="confirmation"][data-own="true"]`;
  return (await page.waitForSelector(own, { timeout: 30_000 })).getAttribute("data-ref");
}

async function thread(state) {
  const { identifier } = state;
  const person = await atHub(identifier);
  const pair = await ask({ op: "pair", user_id: person.user_id });
  state.pair = pair.thread_id;
  const posted = await ask({ op: "post", user_id: person.user_id, thread_id: pair.thread_id, text: "Hello from my own home" });
  const read = await ask({ op: "read", thread_id: pair.thread_id });
  record.thread = { pair: pair.thread_id || pair.answer, posted: !!posted.message_id, read: read.texts };
  return row("thread", "chromium", !!pair.thread_id && read.texts.includes("Hello from my own home"),
    "the operator and the person, who share Household at H, have a pair thread there; the person posts in it and it reads there",
    record.thread);
}

async function removal(state) {
  const { identifier, hub, hubPage, home } = state;
  const removed = await ask({ op: "remove", identifier, thread_id: hub.household, tolerate: true });
  const person = await atHub(identifier);
  const inHousehold = await ask({ op: "post", user_id: person.user_id, thread_id: hub.household, text: "after removal" });
  const inPair = await ask({ op: "post", user_id: person.user_id, thread_id: state.pair, text: "still here" });
  const ownPage = !(await signedOut(hubPage, settingsAt(H, hubAthanor)));
  await open(home.desk, home.settings);
  const aUsable = new URL(home.desk.url()).pathname.endsWith("/settings");
  const commandLine = await commandLineUsable(state);
  record.removal = {
    removed: removed.ok ? true : removed, threads: person.threads, post_in_household: inHousehold,
    post_in_pair: !!inPair.message_id, own_page: ownPage, a_usable: aUsable, command_line_at_hub: commandLine,
  };
  return row("removal", "chromium",
    !!removed.ok && !person.threads.includes(hub.household) && person.threads.includes(state.pair) &&
      !!inHousehold.refused && !!inPair.message_id && ownPage && aUsable && commandLine.usable,
    "removed from H's Household thread, the person can no longer post there, while the pair thread, their own athanor at H, the command line paired there and A stay usable",
    record.removal);
}

async function rotate(chromium, state) {
  const { home, identifier, hubPage } = state;
  // A change at H confirmed at A under the key about to be replaced, its
  // assertion kept by the proof and never delivered (`recertify` presents
  // it once A rotated).
  state.heldAssertion = await holdAssertion({ ...state, hubAthanor });
  const before = await ask({ op: "a_head" });
  await open(home.desk, home.settings);
  await home.desk.locator('[data-test="identity-rotate"]').click();
  await confirmHere(home.desk);
  await flashed(home.desk, "Your live key was rotated.");
  const rotatedAt = Date.now();
  const after = await ask({ op: "a_head" });

  // H retires the sessions bound to the old key_epoch within its bound.
  const retiredMs = await within(() => signedOut(hubPage, settingsAt(H, hubAthanor)), (SETTINGS.fresh + 30) * 1000);
  const passkeys = (await atHub(identifier)).passkeys;

  // The H passkey stays, and signs the person in again.
  await hubPage.goto(`${H}/login`);
  await connected(hubPage);
  await passkeySignIn(hubPage, H);
  const back = !(await signedOut(hubPage, settingsAt(H, hubAthanor)));

  // A CYFR-door session alone activates no new passkey here: a fresh
  // proof is asked for first.
  const fresh = await signIn(chromium, "chromium", state.proxy, { home: A, identifier, passkeysFrom: home.desk, step: "rotate_sign_in" }).catch((error) => ({ error }));
  let asked = null;
  if (fresh.page) {
    await authenticatorWith(fresh.page);
    await open(fresh.page, settingsAt(H, hubAthanor));
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
  return row("rotate", "chromium",
    record.rotate.head_moved && retiredMs !== null && retiredMs <= (SETTINGS.fresh + 30) * 1000 &&
      passkeys.some((p) => p.state === "active") && back && asked === true &&
      passkeysAfter.filter((p) => p.state === "active").length === 1,
    "after A rotates the live key, H retires its old-epoch sessions within its bound; its passkey stays and signs in; a CYFR-door session's new passkey asks for a fresh proof",
    record.rotate);
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
  await open(other, settingsAt(H, hubAthanor)).catch(() => null);
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
  const { home, identifier, code2 } = state;
  // Before A is lost: a session at H by the H passkey, and a change at H
  // waiting for its confirmation.
  const passkeyContext = await freshContext(chromium);
  const passkeyPage = await passkeyContext.newPage();
  await authenticatorWith(passkeyPage, await credentialsFor(state.hubPage, new URL(H).host));
  await passkeyPage.goto(`${H}/login`);
  await connected(passkeyPage);
  await passkeySignIn(passkeyPage, H);
  await open(passkeyPage, shellAt(H, hubAthanor));
  await passkeyPage.locator("#shell-devices").click();
  await passkeyPage.waitForSelector(`${layer} [data-test="pairing"]`, { timeout: 30_000 });
  // A pairing begun for some new device's code, the digest of a key no
  // device here holds: it only waits for its confirmation.
  const someKey = createHash("sha256").update(randomBytes(32)).digest("base64url");
  await passkeyPage.locator(`${layer} [data-test="pairing-key-input"]`).fill(someKey);
  await pressInLayer(passkeyPage, '[data-test="pairing-begin"]');
  await passkeyPage.waitForSelector(`${layer} [data-test="confirmation"][data-own="true"]`, { timeout: 30_000 });
  state.passkeySession = { passkeyContext, passkeyPage };

  // The command line used at H once more while A answers, so the
  // certificate A issued it is renewed if due and outlives A's loss for
  // the check below: a remote device's session ends with its home's
  // certificate, which no one renews once that home is gone.
  const beforeDown = await commandLineUsable(state);

  // A is lost. H's work, a page of the person's there and the command
  // line paired there, goes on, bound to H.
  const down = await ask({ op: "a_down" });
  const hubPage = await state.hubContext.newPage();
  const hubUsable = !(await signedOut(hubPage, settingsAt(H, hubAthanor)));
  await hubPage.close();
  const commandLine = await commandLineUsable(state);
  record.lost_home = {
    a_down: down.down, hub_page: hubUsable, command_line_before_a_down: beforeDown, command_line_at_hub: commandLine,
  };
  if (!row("lost_home", "chromium", down.down && hubUsable && commandLine.usable,
    "with A lost, the person's work at H, a page there and the command line paired there, goes on bound to H",
    record.lost_home)) return false;

  // The person restores on A2 with the second recovery code.
  const { token } = await ask({ op: "token_a2" }, { secret: true });
  secrets.push(token);
  const context = await freshContext(chromium);
  const page = await context.newPage();
  await authenticatorWith(page);
  await page.goto(`${A2}/restore`);
  await connected(page);
  await page.locator('[data-test="restore-token"]').fill(token);
  await page.locator('[data-test="restore-code"]').fill(code2.code);
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
    "A lost, the person restores on an installation-authorized fresh node, A2, with the second recovery code",
    record.restore);
}

async function retired(chromium, state) {
  const { identifier, hub } = state;
  const { passkeyPage, passkeyContext } = state.passkeySession;
  // H retires every old-epoch session, the H passkey's included, within
  // its bound, as it reads the identity's new head.
  const retiredMs = await within(() => signedOut(passkeyPage, settingsAt(H, hubAthanor)), (SETTINGS.fresh + 40) * 1000);
  const measuredFromRestore = retiredMs === null ? null : seconds(Date.now() - state.restoredAt);
  const person = await atHub(identifier);
  const confirmations = (await ask({ op: "confirmations", cell: "h", identifier })).confirmations;

  // The old H passkey signs nobody in.
  await passkeyPage.goto(`${H}/login`);
  await connected(passkeyPage);
  await ready(passkeyPage);
  await passkeyPage.locator("#passkey-sign-in [data-webauthn-start]").click();
  await flashed(passkeyPage, "That passkey did not sign you in here.");
  const oldPasskeyIn = new URL(passkeyPage.url()).pathname !== "/login";
  await passkeyContext.close();

  // An old home's assertion, replayed at H, admits nobody.
  const before = { receipts: await receiptRowsAtHub(identifier), sessions: (await atHub(identifier)).sessions };
  const replay = await freshContext(chromium);
  const replayPage = await replay.newPage();
  const old = assertions[0];
  await refusedAssertion(replayPage, old);
  const replayedIn = !(await signedOut(replayPage, settingsAt(H, hubAthanor)));
  await replay.close();
  const after = { receipts: await receiptRowsAtHub(identifier), sessions: (await atHub(identifier)).sessions };

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
      !oldPasskeyIn && !replayedIn && sameRows(before.receipts, after.receipts) && sameRows(before.sessions, after.sessions) && fresh.held,
    "after the recovery H retires every old-epoch session, the H passkey's included, within its bound; the old passkey and confirmation are retired, an old assertion replays nothing, and the person signs in naming A2",
    record.retired);
}

async function adminAgain(chromium, state) {
  const { identifier } = state;
  const page = state.newHub.page;
  // The command line paired at H under A's certificate stands there still,
  // but its certificate chains to keys the recovery retired: H counts it as
  // no way to confirm, so the person holds none at H.
  const commandLine = await terminalStanding(state);
  await authenticatorWith(page);
  await open(page, settingsAt(H, hubAthanor));
  await page.locator('[data-test="passkey-register"]').click();
  await flashed(page, "administrator authorizes");
  await counted();
  const person = await atHub(identifier);
  const pending = person.passkeys.filter((p) => p.state === "pending");
  const authorized = await authorize(state.admin, person.user_id);
  const after = (await atHub(identifier)).passkeys.filter((p) => p.state === "active");
  record.admin_again = { command_line_at_hub: commandLine, pending: pending.length, authorized, active: after.length };
  return row("admin_again", "chromium",
    commandLine === "active" && pending.length === 1 && authorized.asked && after.length === 1,
    "after the recovery, with the command line paired under the retired keys still standing at H, a new passkey at H again needs a new recorded authorization by H's operator",
    record.admin_again);
}

// The cross-home confirmation's screens at the handheld's 720×720 touch
// viewport (HANDHELD), after the restore: a context holding the person's
// sessions at H and A2 and their A2 passkey asks for a credential entry at
// H and confirms it through A2; H's request panel, A2's /carry#confirm=
// page, A2's prompt and H's /confirm answer are measured and held.
async function viewport(chromium, state) {
  const context = await chromium.newContext(HANDHELD);
  await context.addCookies(await state.newHub.page.context().cookies([H, A2]));
  const page = await context.newPage();
  await authenticatorWith(page, await credentialsFor(state.a2.page, new URL(A2).host));
  const measured = {};
  const ref = await askEntryAtHub(page, "join-viewport-entry");
  const confirmed = await confirmAtHome(page, ref, A2, { measured });
  await context.close();
  const failures = unmet(measured);
  record.viewport = { measured, failures, home_origin: confirmed.home_origin, done: confirmed.done };
  return row("viewport", "chromium",
    confirmed.home_origin === A2 && confirmed.done === "confirmed" && failures.length === 0,
    "at 720×720: a request at H, the person's own CYFR's confirmation page and prompt, and H's answer to its assertion, every control 24×24 CSS px or more, text 12 px or more, nothing overflowing",
    record.viewport);
}

async function directoryDown(state) {
  const { identifier, newHub } = state;
  const page = newHub.page;
  await ask({ op: "directory_fault", directory: "dir.test", mode: "down" });
  const downAt = Date.now();
  const answered = await ask({ op: "h_fresh", identifier });
  const usableWithin = !(await signedOut(page, settingsAt(H, hubAthanor)));
  await sleep((SETTINGS.fresh + 5) * 1000);
  const past = await ask({ op: "h_fresh", identifier });

  // Past the bound the browser's protected work pauses: the page is not
  // served, and the sign-in page it lands on says why.
  await page.goto(settingsAt(H, hubAthanor));
  await page.waitForURL((url) => url.pathname === "/login", { timeout: 30_000 }).catch(() => null);
  await page.waitForFunction(() => /could not be confirmed fresh/.test(document.body.innerText), null, { timeout: 30_000 })
    .catch(() => null);
  const pastPage = await page.locator("body").innerText().catch(() => "");
  const pastPath = new URL(page.url()).pathname;
  await ask({ op: "directory_fault", directory: "dir.test", mode: "none" });

  // The directory back, the same session works again: a pause, not a
  // sign-out.
  const resumedMs = await within(async () => !(await signedOut(page, settingsAt(H, hubAthanor))), 30_000);
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
  const state = { home, hub, hubPage, hubContext, proxy, identifier: home.identifier, code2: home.code2 };
  hubAthanor = (await atHub(home.identifier)).athanor_route;
  if (!row("own_athanor", "chromium", !!hubAthanor, "the person admitted at H has their own athanor there", { route: hubAthanor })) return;
  const steps = [
    () => crafted(chromium, state),
    () => copiedSession(chromium, state),
    () => droppedCallback(chromium, state),
    () => closedHops(chromium, state),
    () => forgedCompletion(chromium, state),
    () => invited(chromium, state),
    () => hubPasskey(chromium, state),
    () => aPasskeyAtHub(chromium, state),
    () => terminalStep(proxy, Object.assign(state, { hubAthanor })),
    () => crossDevice(proxy, state),
    () => terminalRenewal(proxy, state),
    () => thread(state),
    () => removal(state),
    () => rotate(chromium, state),
    () => recertify(proxy, state),
    () => tabs(state),
    () => restore(chromium, state),
    () => retired(chromium, state),
    () => adminAgain(chromium, state),
    () => viewport(chromium, state),
    () => directoryDown(state),
  ];
  for (const step of steps) if (!(await step())) return;
}
