// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The join proof, run in the official Playwright image by run.sh against
// `cyfr` releases behind the harness's HTTPS front (README.md): the
// directory dir.test, which serves the account pages, and h.test, the
// CYFR people join. Chromium alone, since a passkey is made and used by
// its virtual authenticator (../browser/account.mjs); the device that
// joins by its hello is a test device (../browser/device.mjs) this process
// drives. Each step is one row of the record; the proof fails when a row
// does not hold, and stops at the first row a later one rests on.
//
// H's part of a step (its setup token, the people it holds) is run.sh's,
// asked for through OUT_DIR (`ask-N.json`, answered `answer-N.json`). The
// ask that carries the setup token is deleted once read.
//
// Usage: node proof.mjs HOMES_FILE OUT_DIR

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  addDevice, confirmInTab, continueToCyfr, createAccount, landing, passkeys, readLog, usePasskey,
} from "../browser/account.mjs";
import { helloDevice, newDevice } from "../browser/device.mjs";
import { ask as askRunSh, launchBrowser, readHomes, redact as redactKnown, startProxy } from "../browser/lib.mjs";

const [homesFile, outDir] = process.argv.slice(2);
if (!homesFile || !outDir) {
  console.error("usage: node proof.mjs HOMES_FILE OUT_DIR");
  process.exit(64);
}
mkdirSync(outDir, { recursive: true });

const { homes } = readHomes(homesFile);
const homeNamed = (name) => homes.find((home) => home.name === name) || (() => { throw new Error(`no home ${name}`); })();
const DIR = homeNamed("dir");
const H = homeNamed("h");
const layer = "#system-layer-dialog";
const rows = [];
const record = {};
// Every recovery code, its secret, the setup token and each invitation's
// code, so no record is shown to hold one.
const secrets = [];

function row(step, held, what, detail) {
  rows.push({ step, held: !!held, what, detail });
  console.log(`${held ? "held  " : "FAILED"} ${step}: ${what} — ${redact(JSON.stringify(detail)).slice(0, 2000)}`);
  return !!held;
}

const redact = (text) => redactKnown(text, secrets);

const ask = (request, options) => askRunSh(request, { outDir, timeoutMs: 300_000, refuseError: true, ...options });

const atH = async (identifier) => (await ask({ op: "people" })).people.find((p) => p.identifier === identifier) || null;

// An invitation the operator makes on H's Settings page: the link it shows
// once, its code joined to the secrets.
async function invite(page, segment) {
  await page.goto(`${H.origin}/a/${encodeURIComponent(segment)}/settings`);
  await page.waitForSelector(".phx-connected", { timeout: 60_000 });
  await page.locator('[data-test="invitation-create"]').click();
  const link = (await page.locator('[data-test="invitation-link"]').textContent({ timeout: 30_000 })).trim();
  secrets.push(new URL(link).hash.slice(1));
  return link;
}

// The invitation page at `link`, once it has read the code: what it says.
async function openInvitation(page, link) {
  await page.goto(link);
  await page.waitForSelector('[data-test="invite-create"], [data-test="invite-refused"], [data-test="invite-error"]',
    { timeout: 60_000 });
  return {
    refused: (await page.locator('[data-test="invite-refused"]').count()) > 0,
    from: (await page.locator('[data-test="invite-from"]').textContent().catch(() => null))?.trim() ?? null,
    text: await page.locator("body").innerText(),
  };
}

// ---------------------------------------------------------------------------
// The steps
// ---------------------------------------------------------------------------

async function main(browser, proxy) {
  const opKeys = passkeys();
  const personKeys = passkeys();
  const deviceOwnerKeys = passkeys();
  const op = await (await browser.newContext()).newPage();
  const person = await (await browser.newContext()).newPage();

  // operator
  const opAccount = await createAccount(op, opKeys, { directory: DIR, name: "join-op", secrets });
  const { token } = await ask({ op: "setup_token" }, { secret: true });
  secrets.push(token);
  await op.goto(`${H.origin}/setup#${token}`);
  await op.locator('[data-test="setup-sign-in"]').click({ timeout: 60_000 });
  const opAsked = await usePasskey(op, opKeys);
  const opLanded = opAsked.returned ? await landing(op, H) : { landed: false };
  const operator = await atH(opAccount.code?.identifier);
  record.operator = { account: opAccount.section, asked: opAsked, landed: opLanded, at_h: operator };
  if (!row("operator", opAccount.section === "done" && opLanded.landed && operator?.admission === "setup",
    "H's operator makes their account at the pages and sets H up by signing in with it", record.operator)) return;

  // invited: a newcomer with no account yet opens the operator's link,
  // creates their account through H's request, and H admits them under
  // the invitation.
  const link = await invite(op, operator.segment);
  const opened = await openInvitation(person, link);
  await person.locator('[data-test="invite-create"]').click();
  const made = await createAccount(person, personKeys, { name: "join-b", secrets });
  const returned = made.section === "done-return" ? await continueToCyfr(person, personKeys, H) : { left: false };
  const personLanded = returned.left ? await landing(person, H) : { landed: false };
  const identifier = made.code?.identifier;
  const joined = await atH(identifier);
  const personLog = identifier ? await readLog(DIR, identifier) : null;
  record.invited = {
    opened: { refused: opened.refused, from: opened.from, shows_code: secrets.some((s) => opened.text.includes(s)) },
    made: made.section, returned, landed: personLanded, at_h: joined, log: personLog,
  };
  if (!row("invited",
    !opened.refused && !record.invited.opened.shows_code && made.section === "done-return" &&
      returned.label === `Continue to ${H.origin}` && personLanded.landed && joined?.admission === "invitation" &&
      joined.sessions.length === 1 && personLog?.kinds.join() === "genesis,add_key",
    "an invitation link, opened by a newcomer, sends them to the account pages with H's request: they create their account there, " +
      "the page signs H's request with the new passkey, and H admits the account under the invitation and signs them in",
    record.invited)) return;

  // spent
  const again = await openInvitation(await (await browser.newContext()).newPage(), link);
  record.spent = { refused: again.refused };
  if (!row("spent", again.refused, "the invitation link a second time says it can no longer be used", record.spent)) return;

  // confirm: an API key the person asks for at H waits on a fresh
  // confirmation, given with their passkey at the sign page in a new tab.
  await person.goto(`${H.origin}/a/${encodeURIComponent(joined.segment)}/api-keys`);
  await person.waitForSelector(".phx-connected", { timeout: 60_000 });
  await person.locator("button", { hasText: "Create Key" }).click();
  await person.locator('#api-key-form input[name="name"]').fill("join-proof");
  await person.locator('#api-key-form button[type="submit"]').click();
  const own = `${layer} [data-test="confirmation"][data-own="true"] [data-test="confirm-passkey"]`;
  await person.waitForSelector(own, { timeout: 30_000 });
  const confirmed = await confirmInTab(person, personKeys, H, () => person.locator(own).click());
  const shown = await person.waitForFunction(() => document.body.innerText.includes("It will not be shown again"), null,
    { timeout: 30_000 }).then(() => true).catch(() => false);
  record.confirm = { confirmed, key_shown: shown };
  if (!row("confirm",
    confirmed.what === `Confirm a change at ${H.origin}` && confirmed.landed && shown,
    "an API key the person asks for at H waits on a fresh confirmation; the sign page asks to confirm a change at H, the passkey " +
      "signs it, and the waiting page makes the key",
    record.confirm)) return;

  // device: an account whose only key is a device added at the pages; the
  // device's hello at H brings an invitation's code, and H admits the
  // account and the device on that one connection.
  const deviceLink = await invite(op, operator.segment);
  const owner = await (await browser.newContext()).newPage();
  const ownerAccount = await createAccount(owner, deviceOwnerKeys, { directory: DIR, name: "join-d", secrets });
  const ownerIdentifier = ownerAccount.code?.identifier;
  const device = newDevice({ name: "join proof device" });
  const added = await addDevice(owner, deviceOwnerKeys, { directory: DIR, device });
  const ownerLog = ownerIdentifier ? await readLog(DIR, ownerIdentifier) : null;
  const hello = await helloDevice(device, {
    identifier: ownerIdentifier, admission: { invitation: new URL(deviceLink).hash.slice(1) },
    proxyPort: proxy.address().port, base: H.origin,
  });
  const standing = hello.channel?.standing ?? null;
  hello.channel?.close();
  const deviceAtH = await atH(ownerIdentifier);
  const client = deviceAtH?.clients.find((c) => c.kid === device.kid) ?? null;
  const spentAgain = await openInvitation(await (await browser.newContext()).newPage(), deviceLink);
  record.device = {
    added: { section: added.section, shown: added.shown, error: added.error }, log: ownerLog,
    hello: hello.channel ? { standing: !!standing, certificate_audience: device.certificate?.audience } : { code: hello.code, log: hello.log },
    at_h: deviceAtH, client, link_spent: spentAgain.refused,
  };
  row("device",
    added.section === "added" && ownerLog?.keys.some((k) => k.kid === device.kid && k.kind === "device") && !!hello.channel &&
      !!standing && deviceAtH?.admission === "invitation" && client?.standing === "active" && spentAgain.refused,
    "a device added to its account at /account/add says hello at H with an invitation's code: H admits the account under it, " +
      "issues the device its certificate and stands its channel on the same connection, and the code is spent",
    record.device);
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
    }
  }
} finally {
  await browser.close();
  proxy.close();
}

const STEPS = ["operator", "invited", "spent", "confirm", "device"];
const outcome = (step) => {
  const found = rows.find((r) => r.step === step);
  return found ? (found.held ? "held" : "FAILED") : "not reached";
};
writeFileSync(join(outDir, "join-proof.json"), redact(JSON.stringify({ chromium: version, rows, record, failure }, null, 2)));
const table = [`| step | chromium ${version} |`, "|---|---|", ...STEPS.map((step) => `| ${step} | ${outcome(step)} |`)];
writeFileSync(join(outDir, "join-proof.md"), table.join("\n") + "\n");
console.log(table.join("\n"));
if (failure || STEPS.some((step) => outcome(step) !== "held")) {
  console.error("FAIL: a step of the join proof did not hold");
  process.exit(1);
}
console.log("ok: every step held");
