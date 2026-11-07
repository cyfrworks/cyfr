// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The identity proof, run in the official Playwright image by run.sh
// against `cyfr` releases behind the harness's HTTPS front (README.md):
// the directory dir.test, which serves the account pages, and a.test, a
// CYFR that relies on it. Chromium alone, since a passkey is made and
// used by its virtual authenticator (../browser/account.mjs). The person
// holds three browsers' passkeys over the run, each its own context: the
// laptop's, the phone's and a new device's after the account is replaced.
// Each step is one row of the record; the proof fails when a row does not
// hold, and stops at the first row a later one rests on.
//
// The servers' part of a step (A's setup token, what A holds, the
// directory down on purpose, the tombstone) is run.sh's, asked for
// through OUT_DIR (`ask-N.json`, answered `answer-N.json`). The ask that
// carries the setup token is deleted once read.
//
// Usage: node proof.mjs HOMES_FILE OUT_DIR

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  createAccount, devicesPage, landing, passkeys, readLog, recoveryPage, signIn, usePasskey,
} from "../browser/account.mjs";
import {
  ask as askRunSh, askHome, launchBrowser, readHomes, redact as redactKnown, sleep, startProxy,
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
const A = homeNamed("a");
const NAME = "identity-a";
// How far past the bound an observation may fall: the browser asks A
// every two seconds, and each ask is a page load of its own.
const SLACK_S = 6;
const rows = [];
const record = {};
// Every recovery code, its secret and the setup token, so no page,
// address or record is shown to hold one.
const secrets = [];

function row(step, held, what, detail) {
  rows.push({ step, held: !!held, what, detail });
  console.log(`${held ? "held  " : "FAILED"} ${step}: ${what} — ${redact(JSON.stringify(detail)).slice(0, 2000)}`);
  return !!held;
}

const redact = (text) => redactKnown(text, secrets);

const ask = (request, options) => askRunSh(request, { outDir, timeoutMs: 300_000, refuseError: true, ...options });

// Where `page` is left at A by a page load of A's root: the path it lands
// on, `/login` once its session no longer stands.
async function atA(page) {
  await page.goto(`${A.origin}/`);
  await page.waitForLoadState("domcontentloaded");
  return new URL(page.url()).pathname;
}

// Seconds from now until a page load of A by `page` lands on `/login`,
// asked every two seconds, or null past `limitS`.
async function signedOutWithin(page, limitS) {
  const started = Date.now();
  while (Date.now() - started <= limitS * 1000) {
    if ((await atA(page)) === "/login") return Math.round((Date.now() - started) / 1000);
    await sleep(2_000);
  }
  return null;
}

// Every secret the proof handled that `page`'s storage or address, or any
// request the proxy saw since `mark`, holds: their count.
async function leaks(page, proxy, mark) {
  const stored = await page.evaluate(() => {
    const dump = (store) => {
      const out = [];
      for (let i = 0; i < store.length; i++) out.push(store.key(i), store.getItem(store.key(i)));
      return out.join("\n");
    };
    return `${dump(localStorage)}\n${dump(sessionStorage)}\n${location.href}`;
  });
  const requests = proxy.seen.slice(mark).map((r) => `${r.url} ${r.referer ?? ""} ${r.body ?? ""}`).join("\n");
  return secrets.filter((secret) => secret && (stored.includes(secret) || requests.includes(secret))).length;
}

const person = async (identifier) => {
  const { people } = await ask({ op: "people" });
  return { people, of: people.find((p) => p.identifier === identifier) || null };
};
const sessionKids = (of) => (of ? of.sessions.map((s) => s.kid).sort() : []);
const passkeyKids = (log) => log.keys.filter((k) => k.kind === "passkey").map((k) => k.kid);

// ---------------------------------------------------------------------------
// The steps
// ---------------------------------------------------------------------------

async function main(browser, proxy) {
  const bound = (await ask({ op: "bound" })).seconds;
  const laptopKeys = passkeys();
  const phoneKeys = passkeys();
  const newKeys = passkeys();
  const laptop = await (await browser.newContext()).newPage();
  const phone = await (await browser.newContext()).newPage();
  const fresh = await (await browser.newContext()).newPage();

  // account
  const mark = proxy.seen.length;
  const made = await createAccount(laptop, laptopKeys, { directory: DIR, name: NAME, secrets });
  const identifier = made.code?.identifier;
  const log = identifier ? await readLog(DIR, identifier) : null;
  const handle = await askHome(DIR, `/v1/handles/${NAME}`);
  let handleBody = null;
  try { handleBody = JSON.parse(handle.body); } catch { handleBody = null; }
  const held = await laptopKeys.list();
  const userHandle = held[0] ? Buffer.from(held[0].userHandle, "base64").toString("hex") : null;
  const leaked = await leaks(laptop, proxy, mark);
  record.account = {
    ended: made.section, error: made.error, identifier, log, handle: { status: handle.status, body: handleBody },
    credentials: held.map((c) => ({ rp: c.rpId, resident: c.isResidentCredential })), user_handle_names_account: !!identifier && userHandle === identifier.slice(4),
    leaked,
  };
  if (!row("account",
    made.section === "done" && log?.status === 200 && log.kinds.join() === "genesis,add_key" &&
      passkeyKids(log).length === 1 && log.recovery === 1 && handle.status === 200 &&
      handleBody?.identifier === identifier && handleBody?.directory === DIR.origin && held.length === 1 &&
      held[0].rpId === DIR.host && record.account.user_handle_names_account && leaked === 0,
    `@${NAME} made at ${DIR.host}'s pages: the code shown and saved before the passkey, the log a genesis and the passkey's add_key, ` +
      "the name the account's, the passkey's user handle the identifier, and neither the code nor its secret in storage, an address or a request",
    record.account)) return;
  const p1 = passkeyKids(log)[0];

  // sign_in
  const { token } = await ask({ op: "setup_token" }, { secret: true });
  secrets.push(token);
  await laptop.goto(`${A.origin}/setup#${token}`);
  await laptop.locator('[data-test="setup-sign-in"]').click({ timeout: 60_000 });
  const asked = await usePasskey(laptop, laptopKeys);
  const landed = asked.returned ? await landing(laptop, A) : { landed: false };
  const signedIn = await person(identifier);
  const cachedAtA = await ask({ op: "head", identifier });
  record.sign_in = { asked, landed, people: signedIn.people, head: cachedAtA };
  if (!row("sign_in",
    asked.what === `Sign in to ${A.origin}` && landed.landed && signedIn.people.length === 1 &&
      signedIn.of?.admission === "setup" && sessionKids(signedIn.of).join() === p1 && cachedAtA.head === log.head,
    "the person sets A up by signing in with their account: the sign page names A, A admits the account under its setup token and " +
      "binds the session to the passkey's key, and caches the account's head",
    record.sign_in)) return;

  // second_code
  const first = await recoveryPage(laptop, laptopKeys, { directory: DIR, code: made.code.code, identifier });
  const added = first.opened.section === "account" ? await first.addCode(secrets) : { code: null };
  const afterCode = await readLog(DIR, identifier);
  const second = await recoveryPage(phone, phoneKeys, { directory: DIR, code: added.code?.code ?? "", identifier });
  record.second_code = {
    opened: first.opened, added: { done: added.done, error: added.error, identifier: added.code?.identifier }, log: afterCode,
    second_opens: second.opened,
  };
  if (!row("second_code",
    added.done && added.code?.identifier === identifier && added.code.code !== made.code.code &&
      afterCode.kinds.at(-1) === "add_recovery" && afterCode.recovery === 2 && second.opened.section === "account",
    "the recovery page, opened with the first code, draws and shows a second code for the same account before it adds it; the second opens the page",
    record.second_code)) return;

  // remove_key: a passkey added on the phone with the second code signs
  // in at A; removed from the laptop's devices page, A retires what was
  // bound to it at its next refresh, within the bound.
  const addedPasskey = await second.addPasskey(NAME);
  const withPhone = await readLog(DIR, identifier);
  const p2 = passkeyKids(withPhone).find((kid) => kid !== p1);
  const phoneIn = await signIn(phone, phoneKeys, A);
  const both = await person(identifier);
  const devices = await devicesPage(laptop, laptopKeys, { directory: DIR, identifier });
  const removed = p2 ? await devices.removeKey(p2) : { done: false };
  const phoneOut = removed.done ? await signedOutWithin(phone, bound + SLACK_S + 30) : null;
  const laptopAt = await atA(laptop);
  const afterRemoval = await person(identifier);
  const clientsOfP2 = afterRemoval.of?.clients.filter((c) => c.kid === p2) ?? [];
  record.remove_key = {
    added: addedPasskey, phone_signed_in: phoneIn, sessions_before: sessionKids(both.of), listed: await devices.keys(),
    removed, phone_signed_out_after_s: phoneOut, bound, slack: SLACK_S, laptop_at: laptopAt,
    sessions_after: sessionKids(afterRemoval.of), p2_clients: clientsOfP2,
  };
  if (!row("remove_key",
    addedPasskey.done && !!p2 && phoneIn.landed && sessionKids(both.of).join() === [p1, p2].sort().join() && removed.done &&
      phoneOut !== null && phoneOut <= bound + SLACK_S && laptopAt !== "/login" &&
      sessionKids(afterRemoval.of).join() === p1 && clientsOfP2.every((c) => c.standing !== "active"),
    "a passkey removed from the account at the devices page ends the session it signed in at A within A's freshness bound, " +
      "and the laptop's passkey keeps its session",
    record.remove_key)) return;

  // recover
  const replacing = await recoveryPage(laptop, laptopKeys, { directory: DIR, code: added.code.code, identifier });
  const replaced = await replacing.replace(secrets);
  const afterRecover = await readLog(DIR, identifier);
  const laptopOut = replaced.done ? await signedOutWithin(laptop, bound + SLACK_S + 30) : null;
  const firstAgain = await recoveryPage(fresh, newKeys, { directory: DIR, code: made.code.code, identifier });
  const third = await recoveryPage(fresh, newKeys, { directory: DIR, code: replaced.code?.code ?? "", identifier });
  const p3Added = await third.addPasskey(NAME);
  const withP3 = await readLog(DIR, identifier);
  const p3 = passkeyKids(withP3)[0];
  const oldPasskey = await signIn(laptop, laptopKeys, A);
  const freshIn = await signIn(fresh, newKeys, A);
  const afterSignIn = await person(identifier);
  record.recover = {
    replaced: { done: replaced.done, error: replaced.error, identifier: replaced.code?.identifier }, log: afterRecover,
    laptop_signed_out_after_s: laptopOut, bound, first_code_after: firstAgain.opened, third_opens: third.opened,
    p3_added: p3Added, old_passkey: oldPasskey, fresh_sign_in: freshIn, sessions: sessionKids(afterSignIn.of),
    people: afterSignIn.people.length,
  };
  if (!row("recover",
    replaced.done && replaced.code?.identifier === identifier && afterRecover.kinds.at(-1) === "recover" &&
      afterRecover.keys.length === 0 && afterRecover.recovery === 1 && laptopOut !== null && laptopOut <= bound + SLACK_S &&
      firstAgain.opened.section !== "account" && third.opened.section === "account" && p3Added.done && !!p3 &&
      !oldPasskey.landed && freshIn.landed && sessionKids(afterSignIn.of).join() === p3 && afterSignIn.people.length === 1,
    "replacing everything with the second code leaves the account one new code and no key: A ends the laptop's session within its bound, " +
      "the old codes and passkey open nothing, and a passkey the new code adds signs in at A as the same person",
    record.recover)) return;

  // directory_down
  await ask({ op: "resolve", identifier });
  await ask({ op: "directory", mode: "down" });
  const within = await ask({ op: "fresh", identifier, tolerate: true });
  await sleep((bound + 3) * 1000);
  const past = await ask({ op: "fresh", identifier, tolerate: true });
  await ask({ op: "directory", mode: "none" });
  record.directory_down = { within, past, bound };
  if (!row("directory_down", within.head === withP3.head && past.refused === "identity_stale",
    "with the directory down, A serves the head it verified within its bound and pauses the person past it",
    record.directory_down)) return;

  // gone: the directory reachable again past the 15 seconds A leaves it
  // unread after finding it down, and the account read live, so the
  // session that ends below ends for the tombstone, not the outage.
  await sleep(16_000);
  const reread = await ask({ op: "resolve", identifier, tolerate: true });
  const beforeTombstone = await atA(fresh);
  const tombstoned = await ask({ op: "tombstone", identifier });
  const goneLog = await readLog(DIR, identifier);
  const freshOut = await signedOutWithin(fresh, bound + SLACK_S + 30);
  const freshAtA = await ask({ op: "fresh", identifier, tolerate: true });
  const headAtA = await ask({ op: "head", identifier });
  const again = await signIn(fresh, newKeys, A);
  const gonePerson = await person(identifier);
  record.gone = {
    reread, before_tombstone_at: beforeTombstone, tombstoned, log: { status: goneLog.status, error: goneLog.error }, signed_out_after_s: freshOut, bound,
    fresh: freshAtA, head: headAtA, again, sessions: sessionKids(gonePerson.of), status: gonePerson.of?.status,
  };
  row("gone",
    reread.head === withP3.head && beforeTombstone !== "/login" && !!tombstoned.tombstoned && goneLog.status === 410 && goneLog.error === "gone" && freshOut !== null &&
      freshOut <= bound + SLACK_S && freshAtA.refused === "identity_gone" && headAtA.gone === true && !again.landed &&
      sessionKids(gonePerson.of).length === 0,
    "the directory's tombstone answers gone for the account: A ends its last session within the bound, marks the account gone " +
      "and refuses its passkey's next sign-in",
    record.gone);
}

// ---------------------------------------------------------------------------

let proxy;
try {
  proxy = await startProxy({ homes, bodies: true });
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
    }
  }
} finally {
  await browser.close();
  proxy.close();
}

const STEPS = ["account", "sign_in", "second_code", "remove_key", "recover", "directory_down", "gone"];
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
