// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The pairing proof, run in the official Playwright image by run.sh against
// a `cyfr` release behind the harness's HTTPS front (README.md). One
// person, made by setup with a protected device, two Chromium contexts: the
// desktop and the phone, each signed in to Prism, the phone holding the
// person's passkey. A browser holds no device key: its device is its
// passkey. The devices that pair are a command line, the real `cyfr`
// binary run.sh built, and a test device (../browser/device.mjs), a client
// of the device channel this process drives frame by frame. Each step is
// one row of the record; the proof fails when a row does not hold.
//
//   passkey      the phone's first passkey, made by Chromium's virtual
//                authenticator and registered from its Settings page,
//                waits on the page's own confirmation, which the setup
//                device confirms (`device_confirm`)
//   pair         cyfr login shows its key's code; the desktop types it
//                under Devices and begins a pairing for it; the phone's
//                Prism, reading the preview (the code among it) and the
//                asker, confirms it with the passkey; the desktop shows the
//                pairing link and its QR beside the code
//   other_key    a command line on another machine, with a key of its own,
//                given the link: refused, it keeps no certificate, and the
//                link still pairs the first
//   command_line the link pasted pairs the command line that showed the
//                code, with the key it made, and its shell acts as the
//                person (and the renewal, terminal_confirm, open_ticket,
//                exit, pin and lost_answer steps after it: commandLine)
//   confirm      the desktop asks for a credential entry; the phone's
//                Prism shows the home's preview and the asker before the
//                proof, never the typed value, confirms it with the passkey,
//                and the desktop completes it
//   fresh        a second entry: the first assertion replayed and the
//                desktop's session repeating alone change nothing; the
//                phone's fresh assertion confirms it
//   intent       the device-intent measurement: one discrete intent
//                (`confirmation.pending`) admitted and dispatched over the
//                test device's channel and answered, sequentially, timed
//                from the frame it sends to the answer naming its id
//   sleep        the test device sleeps past its certificate's expiry: the
//                home ends its stream and closes its channel at the
//                expiry, its expired certificate opens nothing, it renews
//                on a new connection, its stream is granted anew, and a
//                request made while it slept is read
//   revoke       the desktop revokes the test device under Devices,
//                confirmed in the phone's Prism: the home ends its stream,
//                revokes it and closes the channel, Devices no longer lists
//                it, and its last certificate opens nothing
//   viewport     the phone's steps once more at the handheld's 720×720
//                touch viewport (../browser/handheld.mjs): a pairing's
//                consent, a credential entry's and a revocation's, each read
//                and confirmed in its Prism's system layer with the passkey,
//                each screen meeting the handheld's checks
//
// The home's part of a step — the setup device's confirmation, a replayed
// assertion through the console's adapter, the certificates' life and the
// names of the person's vault entries — is run.sh's, asked for through
// OUT_DIR (`ask-N.json`, answered `answer-N.json`).
//
// Usage: node proof.mjs HOMES_FILE SEGMENT DESKTOP_COOKIE PHONE_COOKIE OUT_DIR [CERT_SECONDS]
// (OUT_DIR/bin/cyfr is the command line run.sh built for the run)

import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { channel, connectDevice, keyDigest, newDevice, pair as pairDevice } from "../browser/device.mjs";
import { HANDHELD, measure as measureScreen, unmet } from "../browser/handheld.mjs";
import {
  ask as askRunSh, firstPasskey, launchBrowser, percentiles, readHomes, signedIn, sleep, startProxy, virtualAuthenticator,
  waitFor,
} from "../browser/lib.mjs";

const [homesFile, segment, desktopCookie, phoneCookie, outDir, certArg] = process.argv.slice(2);
// The life of a device certificate the run set (run.sh), restored after
// the command line's steps set their own.
const certSeconds = Number(certArg || 20);
if (!homesFile || !segment || !desktopCookie || !phoneCookie || !outDir) {
  console.error("usage: node proof.mjs HOMES_FILE SEGMENT DESKTOP_COOKIE PHONE_COOKIE OUT_DIR [CERT_SECONDS]");
  process.exit(64);
}
mkdirSync(outDir, { recursive: true });
const { homes } = readHomes(homesFile);
const home = homes[0];
const base = home.origin;
const shell = `${base}/a/${encodeURIComponent(segment)}/canvas`;
const vault = `${base}/a/${encodeURIComponent(segment)}/vault`;
const settings = `${base}/a/${encodeURIComponent(segment)}/settings`;
const MEASURED = 100;
const rows = [];
const record = {};
let proxy;

function row(step, held, what, detail) {
  rows.push({ step, held: !!held, what, detail });
  console.log(`${held ? "held  " : "FAILED"} ${step}: ${what} — ${JSON.stringify(detail).slice(0, 2000)}`);
  return !!held;
}

// The home's part of a step, asked of run.sh (lib.mjs `ask`).
const ask = (request, options) => askRunSh(request, { outDir, timeoutMs: 90_000, ...options });

// Before any script of the phone's pages: each WebAuthn result its system
// layer sends to the home for a confirmation (`webauthn_result`), as sent,
// kept in the page (`window.__assertions`), so the proof can replay one.
function instrumentAssertions() {
  window.__assertions = [];
  const send = WebSocket.prototype.send;
  WebSocket.prototype.send = function (data) {
    if (typeof data === "string" && data.includes('"webauthn_result"')) {
      try {
        const message = JSON.parse(data);
        const payload = message[4] || {};
        const value = payload.value || {};
        if (value.purpose === "confirmation") window.__assertions.push({ ref: value.id, credential: value.credential });
      } catch {}
    }
    return send.call(this, data);
  };
}
const assertionsSent = (page) => page.evaluate(() => window.__assertions.slice());

// ---------------------------------------------------------------------------
// Prism's side
// ---------------------------------------------------------------------------

const connected = (page) => page.waitForSelector(".phx-connected", { timeout: 30_000 });
const layer = "#system-layer-dialog";
// What a page's system layer says, for a failure's account.
const layerText = (page) => page.locator(layer).innerText({ timeout: 2_000 }).catch((error) => `unread: ${error.message.split("\n")[0]}`);

// A prompt the desktop's layer still shows — a request it completed stays
// until it is closed — is closed first: a modal prompt takes every click.
async function closePrompt(page) {
  const close = page.locator(`${layer}[open] [data-test="prompt-dismiss"]`);
  if (await close.count()) {
    await close.click();
    await page.waitForFunction(() => !document.getElementById("system-layer-dialog")?.open, null, { timeout: 30_000 });
  }
}

async function openDevices(desk) {
  await desk.goto(shell);
  await connected(desk);
  await closePrompt(desk);
  await desk.locator("#shell-devices").click();
  await desk.waitForSelector(`${layer} [data-test="pairing"]`, { timeout: 30_000 });
}

// A vault entry asked for on the desktop's vault page: the form typed, and
// the page's own request waiting on its confirmation.
async function askForEntry(desk, name, value) {
  if (!desk.url().startsWith(vault)) {
    await desk.goto(vault);
    await connected(desk);
  }
  await closePrompt(desk);
  if (!(await desk.locator("#vault-create-form").isVisible().catch(() => false))) {
    await desk.locator('button[phx-click="show_add"][phx-value-mode="fields"]').click();
  }
  const form = desk.locator("#vault-create-form");
  // An API key with no label: the form makes one whatever is installed.
  await form.locator('select[name="kind"]').selectOption("api_key", { timeout: 30_000 });
  await form.locator('input[name="name"]').fill(name);
  await form.locator('textarea[name="fields"]').fill(`API_KEY=${value}`);
  // Every entry names the hosts it may go to; nothing prefills them.
  await form.locator('input[name="destination_hosts"]').fill("fixture.test");
  await form.locator('button[type="submit"]').click();
  try {
    await desk.waitForSelector(`${layer} [data-test="confirmation"][data-own="true"] [data-status="waiting"]`, { timeout: 30_000 });
  } catch (error) {
    // A form the browser would not send asks nothing: name what it refused.
    const refused = await form.evaluate((f) => [...f.elements]
      .filter((e) => e.willValidate && !e.validity.valid).map((e) => `${e.name}: ${e.validationMessage}`)).catch(() => []);
    throw new Error(`the desktop's request for ${name} is not waiting on its confirmation: ${refused.length
      ? `the browser did not send the form (${refused.join("; ")})` : `desktop ${JSON.stringify(await layerText(desk))}`}`);
  }
}

// The phone's Prism, opened afresh, showing another client's request whose
// preview names `operation` (an operation, or an entry's name) from the
// home's record: the one whose ref `skip` does not
// name, with its preview, asker, whether it is restricted, and its text,
// before any proof. Another request still waiting (one asked while a
// device slept) is left as it is.
async function phonePrompt(phone, operation, skip = []) {
  await phone.goto(shell);
  await connected(phone);
  const other = `${layer} [data-test="confirmation"][data-own="false"]`;
  const ref = await waitFor(async () => {
    for (const panel of await phone.$$(other)) {
      const found = await panel.getAttribute("data-ref");
      const preview = await panel.$eval('[data-test="confirmation-preview"]', (e) => e.textContent).catch(() => "");
      if (found && !skip.includes(found) && preview.includes(operation)) return found;
    }
    return null;
  }, { timeoutMs: 30_000, what: `another client's ${operation} request in the phone's Prism` });
  const panel = `${other}[data-ref="${ref}"]`;
  const preview = (await phone.locator(`${panel} [data-test="confirmation-preview"]`).first().textContent()).trim();
  const asker = (await phone.locator(`${panel} [data-test="confirmation-asker"]`).textContent().catch(() => "")).trim();
  const restricted = await phone.locator(`${panel} [data-test="confirmation-restricted"]`).count();
  const text = await phone.locator(panel).innerText();
  return { ref, preview, asker, restricted, text };
}

// The request `ref` confirmed in the phone's Prism with its passkey, and
// whether its panel then leaves the phone's layer: the record confirmed.
async function confirmOnPhone(phone, ref) {
  const panel = `${layer} [data-test="confirmation"][data-ref="${ref}"]`;
  await phone.locator(`${panel} [data-test="confirm-passkey"]`).click({ timeout: 30_000 });
  return phone.waitForFunction((selector) => !document.querySelector(selector), panel, { timeout: 30_000 })
    .then(() => true).catch(() => false);
}

const vaultNames = async () => (await ask({ op: "vault_names" })).names || [];

// The code typed into the desktop's pairing prompt, and the pairing begun
// for it: its request waits on its confirmation.
async function beginFor(desk, code) {
  await openDevices(desk);
  await desk.locator(`${layer} [data-test="pairing-key-input"]`).fill(code);
  await desk.locator(`${layer} [data-test="pairing-begin"]`).click();
  await desk.waitForSelector(`${layer} [data-test="confirmation"][data-own="true"]`, { timeout: 30_000 });
}

// The Revoke of the client `client` names in the desktop's Devices, pressed
// until the desktop's own request for it waits: a press made while the
// layer is still settling may land elsewhere, and is made once more.
async function pressRevoke(desk, client) {
  const waiting = `${layer} [data-test="confirmation"][data-own="true"]`;
  for (let attempt = 0; attempt < 2; attempt++) {
    await desk.locator(`${client} [data-test="pairing-revoke"]`).click();
    if (await desk.waitForSelector(waiting, { timeout: 15_000 }).then(() => true).catch(() => false)) return;
  }
  throw new Error(`the desktop's revocation asked no confirmation: ${JSON.stringify(await layerText(desk))}`);
}

// The pairing link the desktop shows once its pairing for `code` is
// confirmed on the phone: its invitation's secret.
async function pairingFor(desk, phone, code) {
  await beginFor(desk, code);
  const prompt = await phonePrompt(phone, "pairing.begin");
  await confirmOnPhone(phone, prompt.ref);
  await desk.waitForSelector(`${layer} [data-test="pairing-link"]`, { timeout: 30_000 });
  const link = await desk.locator(`${layer} [data-test="pairing-link"]`).inputValue();
  return { link, secret: link.split("#code=")[1], prompt };
}

const spaced = (text) => text.replace(/\s+/g, " ");

// ---------------------------------------------------------------------------
// The steps
// ---------------------------------------------------------------------------

async function passkey(phone, authenticator) {
  await phone.goto(settings);
  await connected(phone);
  const registered = await firstPasskey(phone, { ask, layer, authenticator });
  const held = (await authenticator.credentials()).filter((c) => c.rpId === home.host).length;
  record.passkey = { ...registered, credentials_for_rp: held };
  return row("passkey", registered.ok && held === 1,
    "the phone's passkey, made by the virtual authenticator, waits on the page's own confirmation, which the setup device confirms, and is registered",
    record.passkey);
}

async function confirmEntry(desk, phone) {
  const name = "pairing-entry-1";
  await askForEntry(desk, name, "sk-pairing-1-not-shown");
  const shown = await phonePrompt(phone, name);
  const confirmed = await confirmOnPhone(phone, shown.ref);
  const completed = await waitFor(async () => (await vaultNames()).includes(name), { timeoutMs: 30_000, stepMs: 1_000, what: name }).catch(() => false);
  record.confirm = {
    ref: shown.ref, preview: shown.preview, asker: shown.asker,
    secret_shown: shown.text.includes("sk-pairing-1"), confirmed, completed,
  };
  return [row("confirm", /vault\.create/.test(shown.preview) && shown.preview.includes(name) &&
    /a browser signed in/.test(shown.asker) && !record.confirm.secret_shown && confirmed && completed,
    "the phone's Prism shows the desktop's request from the home's record, its preview and asker before the proof and never the typed value, confirms it with the passkey, and the desktop completes the entry",
    record.confirm), shown.ref];
}

// The command line run.sh built, run as a person runs it: a home of its own,
// the home reached through the run's proxy as the browsers reach it, and
// the run's authority trusted as the container's certificate bundle.
function cyfr(args, cliHome, extra = {}) {
  return spawn(join(outDir, "bin", "cyfr"), args, {
    env: {
      ...process.env,
      HOME: cliHome,
      HTTPS_PROXY: `http://127.0.0.1:${proxy.address().port}`,
      CYFR_NO_UPDATE_CHECK: "1",
      ...extra,
    },
  });
}

// Run the command line to its end: its exit code and what it printed.
function cyfrRun(args, cliHome, extra = {}) {
  return new Promise((resolve) => {
    const child = cyfr(args, cliHome, extra);
    let out = "";
    child.stdout.on("data", (chunk) => { out += chunk; });
    child.stderr.on("data", (chunk) => { out += chunk; });
    child.on("close", (code) => resolve({ code, out }));
  });
}

// The command line on a terminal of its own: cyfr login under script(1)'s
// pseudo-terminal, as a person runs it, its shell /bin/sh. `type` sends a
// line to whatever reads the terminal (cyfr login, then its shell);
// `until` waits for output matching a pattern after `from`.
function terminal(args, cliHome) {
  const command = [join(outDir, "bin", "cyfr"), ...args].map((a) => `'${a.replace(/'/g, "'\\''")}'`).join(" ");
  const child = spawn("script", ["-qfec", command, "/dev/null"], {
    env: {
      ...process.env,
      HOME: cliHome,
      SHELL: "/bin/sh",
      PS1: "$ ",
      // The shell finds the command line run.sh built, as a person's finds
      // their installed cyfr.
      PATH: `${join(outDir, "bin")}:${process.env.PATH}`,
      HTTPS_PROXY: `http://127.0.0.1:${proxy.address().port}`,
      CYFR_NO_UPDATE_CHECK: "1",
    },
  });
  const t = { out: "", exit: null };
  child.stdout.on("data", (chunk) => { t.out += chunk; });
  child.stderr.on("data", (chunk) => { t.out += chunk; });
  t.exited = new Promise((resolve) => child.on("close", (code) => { t.exit = code; resolve(code); }));
  t.type = (line) => child.stdin.write(`${line}\n`);
  t.until = (pattern, from = 0, timeoutMs = 60_000) => waitFor(() => {
    const m = t.out.slice(from).match(pattern);
    return m ? m : null;
  }, { timeoutMs, what: `the terminal to show ${pattern} (${JSON.stringify(t.out.slice(from).slice(-600))})` });
  t.kill = () => child.kill("SIGKILL");
  return t;
}

// The device record cyfr login keeps for the home, as one file.
const deviceRecords = (cliHome) => {
  const dir = join(cliHome, ".cyfr", "devices");
  try {
    return readdirSync(dir).filter((f) => f.endsWith(".json")).map((f) => join(dir, f));
  } catch {
    return [];
  }
};

// The command line, made a device of the person's (S2 of the devices
// plan), in steps of its own:
//   pair          cyfr login on a machine without a chip draws a six-word
//                 passphrase, writes its key before it shows anything, and
//                 shows its key's code and the approve address as a QR
//                 code; the desktop types the code under Devices (a
//                 machine without a camera), and the phone's Prism confirms
//                 the addition with its passkey
//   other_key     another machine's command line, given that link, is
//                 refused
//   command_line  the desktop's link, pasted into the terminal, pairs the
//                 command line with the key it made: unlocked, its shell's
//                 cyfr whoami names the person
//   renewal       with certificates living 75 s, the command line's
//                 certificate renews over its channel and its session stays
//                 alive past its first certificate's expiry
//   terminal_confirm  cyfr pair in that shell asks a change that needs a
//                 fresh confirmation: the home's preview is drawn, then the
//                 passphrase asked once, which confirms it on this command
//                 line, and the pairing link is printed
//   open_ticket   cyfr open in that shell opens the command line's own
//                 loopback page, whose Open CYFR signs a browser with no
//                 cookie in through the unlock's one-time ticket
//   exit          exiting the shell locks: cyfr login exits 0, the shell's
//                 session opens nothing and the browser's session ends
//   pin           (S3) cyfr login --pin on that machine, without a chip,
//                 at a home on another machine: unlocked by the passphrase,
//                 the new PIN typed twice, pin.enroll confirmed on this
//                 command line by the passphrase; the record then keeps the
//                 key under the PIN alone. Three wrong PINs are each
//                 counted, a try within the wait says the time of the next,
//                 the right PIN after it unlocks and a confirmation in its
//                 shell asks the PIN again; with the home out of reach, as
//                 after a reboot, the PIN opens nothing
//   lost_answer   a second machine holding the same key as it stood before
//                 the pairing's answer (its record copied then) finishes
//                 with the invitation's code typed and the passphrase: the
//                 home answers the client it committed for that key
async function commandLine(desk, phone) {
  const cliHome = mkdtempSync(join(tmpdir(), "cyfr-command-line-"));
  const lostHome = mkdtempSync(join(tmpdir(), "cyfr-command-line-lost-"));
  const rec = {};
  let login = null;
  let browserContext = null;
  try {
    const set = await ask({ op: "cert_seconds", value: "75" });
    const added = await cyfrRun(["context", "add", "proof", base], cliHome);
    login = terminal(["login", "--context", "proof"], cliHome);

    const drawn = await login.until(/Write it down:\s+([a-z]+(?: [a-z]+){5})\s/);
    const passphrase = drawn[1];
    await login.until(/The passphrase: /);
    login.type(passphrase);
    await login.until(/The passphrase again: /);
    login.type(passphrase);
    const shown = await login.until(/type:\s+((?:[A-Za-z0-9_-]{4} ){10}[A-Za-z0-9_-]{3})\s[\s\S]*Link or code: /);
    const code = shown[1];
    const approve = login.out.match(/open (https:\/\/\S+)\/devices\/add there/);
    const records = deviceRecords(cliHome);
    rec.key_written_before_code = records.length === 1;
    rec.qr_drawn = /[▀▄█]{20,}/.test(login.out);
    rec.approve_address = approve ? approve[1] === base : false;
    // The machine whose pairing answer is lost: the same key, as it stood.
    mkdirSync(join(lostHome, ".cyfr", "devices"), { recursive: true });
    copyFileSync(join(cliHome, ".cyfr", "config.json"), join(lostHome, ".cyfr", "config.json"));
    if (records.length === 1) copyFileSync(records[0], join(lostHome, ".cyfr", "devices", basename(records[0])));

    // No camera: the code typed on the desktop; the phone's Prism, a
    // passkey of the person's, reads the request from the home's record
    // and confirms it.
    await beginFor(desk, code);
    const prompt = await phonePrompt(phone, "pairing.begin");
    await confirmOnPhone(phone, prompt.ref);
    try {
      await desk.waitForSelector(`${layer} [data-test="pairing-link"]`, { timeout: 30_000 });
    } catch (error) {
      throw new Error(`the desktop showed no pairing link once the phone confirmed: phone ${
        JSON.stringify(await layerText(phone))}; desktop ${JSON.stringify(await layerText(desk))}`);
    }
    const link = await desk.locator(`${layer} [data-test="pairing-link"]`).inputValue();
    const qr = await desk.locator(`${layer} [data-test="pairing-qr"] svg`).count();
    const deskCode = (await desk.locator(`${layer} [data-test="pairing-key-code"]`).textContent()).trim();
    const bearer = (await layerText(desk)).includes("Whoever opens it");
    rec.pair_link = {
      code, preview: prompt.preview, asker: prompt.asker, restricted: prompt.restricted,
      link_shape: link.replace(/#code=.*/, "#code=…"), qr, desktop_code: deskCode, bearer_sentence: bearer,
    };
    row("pair", /pairing\.begin/.test(prompt.preview) && spaced(prompt.preview).includes(code) &&
      /a browser signed in/.test(prompt.asker) && prompt.restricted === 1 &&
      link.startsWith(`${base}/pair#code=`) && qr === 1 && deskCode === code && !bearer,
      "the command line shows its key's code; the desktop's pairing for that code, confirmed in the phone's Prism with its passkey after the home's preview (the code among it) and the asker, shows its link and QR beside the code",
      rec.pair_link);

    // Another machine, with a key of its own, given the same link: the
    // home refuses its key, it keeps no certificate, and the link still
    // pairs the command line that showed the code.
    rec.other_key = await otherMachine(link, code);
    row("other_key", rec.other_key.ok,
      "a command line on another machine, with its own key, given the link: refused as not the key the pairing was approved for, and it holds no certificate",
      rec.other_key);

    const at = login.out.length;
    login.type(link);
    await login.until(/Unlocked\. This shell holds your CYFR session/, at, 60_000);
    let mark = login.out.length;
    login.type("cyfr whoami --context proof; echo \"whoami=$?\"");
    const whoami = await login.until(/whoami=(\d+)/, mark);
    const named = login.out.slice(mark).includes("operator@example.com");
    const sessionFile = join(cliHome, "session");
    login.type(`printf %s "$CYFR_SESSION" > '${sessionFile}'; echo stored=$?`);
    await login.until(/stored=0/, mark);
    // The key that paired is the one whose code the command line showed.
    const held = deviceRecords(cliHome).map((f) => JSON.parse(readFileSync(f, "utf8")))[0] || {};
    const certified = held.certificate && held.certificate.device_key
      ? keyDigest(Buffer.from(held.certificate.device_key, "base64url")).match(/.{1,4}/g).join(" ") : null;
    rec.pair = { code, whoami_exit: Number(whoami[1]), names_person: named, certified_code_is_shown_code: certified === code,
      passphrase_echoed: login.out.split(passphrase).length - 1 };
    row("command_line",
      added.code === 0 && !!set.ok && rec.key_written_before_code && rec.qr_drawn && rec.approve_address &&
        rec.pair.whoami_exit === 0 && named && rec.pair.certified_code_is_shown_code && rec.pair.passphrase_echoed === 1,
      "cyfr login writes its key under the passphrase it shows once, shows its code and approve address as a QR code; the link pasted pairs it with the key whose code it showed, and its shell acts as the person",
      rec.pair);

    // Past its first certificate's life, on the channel's renewals.
    await sleep(85_000);
    mark = login.out.length;
    login.type("cyfr whoami --context proof; echo \"whoami=$?\"");
    const renewed = await login.until(/whoami=(\d+)/, mark);
    rec.renewal = { whoami_exit: Number(renewed[1]), waited_s: 85, cert_seconds: 75 };
    row("renewal", rec.renewal.whoami_exit === 0,
      "the command line's certificate renews over its channel and its session outlives its first certificate",
      rec.renewal);

    // A sensitive change asked in the shell and confirmed on this command
    // line: another device's addition, drawn before the passphrase.
    const otherDigest = createHash("sha256").update(randomBytes(32)).digest("base64url");
    mark = login.out.length;
    login.type(`cyfr pair ${otherDigest} --context proof; echo "pair=$?"`);
    const asked = await login.until(/PIN or passphrase; press Enter once you confirmed it elsewhere: /, mark);
    const before = login.out.slice(mark, mark + asked.index);
    login.type(passphrase);
    const paired = await login.until(/pair=(\d+)/, mark);
    const done = login.out.slice(mark);
    rec.terminal_confirm = {
      preview_before_secret: /pairing\.begin/.test(before) && spaced(before).includes(otherDigest.slice(0, 4)),
      secret_asked_once: (done.match(/PIN or passphrase/g) || []).length === 1,
      pair_exit: Number(paired[1]), link_printed: done.includes(`${base}/pair#code=`),
      passphrase_echoed: done.split(passphrase).length - 1,
    };
    row("terminal_confirm",
      rec.terminal_confirm.preview_before_secret && rec.terminal_confirm.secret_asked_once && rec.terminal_confirm.pair_exit === 0 &&
        rec.terminal_confirm.link_printed && rec.terminal_confirm.passphrase_echoed === 0,
      "a change asked in the shell (another device's addition) shows the home's preview, then asks the passphrase once, which confirms it on this command line",
      rec.terminal_confirm);

    // cyfr open in the shell: the command line's own page, then Open CYFR.
    mark = login.out.length;
    login.type("cyfr open --context proof; echo \"open=$?\"");
    await login.until(/open=\d+/, mark);
    const said = login.out.slice(mark);
    // The command line's page is on this machine's loopback, which the
    // run's proxy does not answer: this context reaches it directly, and
    // the home through the proxy as every other context does.
    browserContext = await desk.context().browser().newContext({
      proxy: { server: `http://127.0.0.1:${proxy.address().port}`, bypass: "127.0.0.1" },
    });
    const page = await browserContext.newPage();
    await page.goto("http://127.0.0.1:7340/");
    await page.locator('form[action="/open"] button').click();
    await page.waitForURL((url) => url.origin === base && !url.pathname.startsWith("/auth/device/complete"), { timeout: 30_000 });
    await page.goto(shell);
    await connected(page);
    const opened = page.url();
    const cookies = (await browserContext.cookies(base)).map((c) => c.name);
    rec.open = { said_page: said.includes("http://127.0.0.1:7340/"), landed: opened.replace(base, ""),
      ticket_in_address: /#|ticket/.test(opened), session_cookie: cookies.includes("_cyfr_key"), canvas: opened.startsWith(shell) };
    row("open_ticket", rec.open.said_page && !rec.open.ticket_in_address && rec.open.session_cookie && rec.open.canvas,
      "cyfr open in the shell opens the command line's own page, whose Open CYFR signs a browser with no cookie in through the unlock's one-time ticket",
      rec.open);

    // Exiting the shell locks the command line.
    login.type("exit");
    const exit = await Promise.race([login.exited, sleep(30_000).then(() => "still running")]);
    const token = readFileSync(sessionFile, "utf8");
    rmSync(sessionFile, { force: true });
    const after = await cyfrRun(["whoami", "--context", "proof"], cliHome, { CYFR_TOKEN: token });
    // The athanor's canvas, which only a session opens: the browser's is
    // gone with the command line's lock.
    await page.goto(shell);
    await page.waitForLoadState("load");
    const signedOut = !page.url().startsWith(shell);
    rec.exit = { login_exit: exit, said_locked: /Locked: this command line's CYFR session ended/.test(login.out),
      session_whoami_exit: after.code, browser_signed_out: signedOut, browser_at: page.url().replace(base, "") };
    row("exit", exit === 0 && rec.exit.said_locked && after.code !== 0 && signedOut,
      "exiting the shell locks the command line: cyfr login exits 0, its session opens nothing, and the browser it opened is signed out",
      rec.exit);

    rec.pin = await pinStep(cliHome, passphrase);
    row("pin", rec.pin.ok,
      "cyfr login --pin keeps the command line's key under a six-digit PIN its home counts, confirmed on the command line: each wrong PIN is counted, the wait is said, the right PIN unlocks and a confirmation asks it again, and with the home away nothing opens",
      rec.pin);

    // The machine whose answer was lost: the code typed, the same key.
    const lost = terminal(["login", "--context", "proof"], lostHome);
    login = lost;
    await lost.until(/Link or code: /);
    lost.type(link.split("#code=")[1]);
    await lost.until(/This command line's passphrase: /);
    lost.type(passphrase);
    await lost.until(/Unlocked\. This shell holds your CYFR session/, 0, 60_000);
    lost.type("exit");
    await Promise.race([lost.exited, sleep(30_000)]);
    const client = (path) => {
      try {
        return JSON.parse(readFileSync(path, "utf8")).client_id || null;
      } catch {
        return null;
      }
    };
    const first = deviceRecords(cliHome).map(client)[0] || null;
    const second = deviceRecords(lostHome).map(client)[0] || null;
    rec.lost_answer = { first_client: first, second_client: second, exit: lost.exit };
    row("lost_answer", first !== null && first === second && lost.exit === 0,
      "a machine holding the key as it stood before the pairing's answer finishes with the invitation's code typed: the home answers the client it committed",
      rec.lost_answer);
    return true;
  } catch (error) {
    record.command_line = { ...rec, failure: String(error).slice(0, 2000) };
    throw error;
  } finally {
    record.command_line = { ...rec, ...(record.command_line || {}) };
    if (login && login.exit === null) login.kill();
    if (browserContext) await browserContext.close().catch(() => {});
    await ask({ op: "cert_seconds", value: String(certSeconds) }).catch(() => {});
    rmSync(cliHome, { recursive: true, force: true });
    rmSync(lostHome, { recursive: true, force: true });
  }
}

// The S3 step of commandLine: the paired command line at cliHome switched
// to a six-digit PIN its home counts, then unlocked by it.
async function pinStep(cliHome, passphrase) {
  const pin = "314159";
  const wrong = "271828";
  const r = {};
  let t = terminal(["login", "--context", "proof", "--pin"], cliHome);
  try {
    await t.until(/Unlock this command line with its passphrase: /);
    t.type(passphrase);
    await t.until(/New PIN: /, 0, 60_000);
    t.type(pin);
    await t.until(/The same PIN again: /);
    t.type(pin);
    const confirm = await t.until(/CYFR asks to confirm (\S+):[\s\S]*type this command line's PIN or passphrase; press Enter once you confirmed it elsewhere: /, 0, 60_000);
    r.confirmed_operation = confirm[1];
    t.type(passphrase);
    await t.until(/now kept under your six-digit PIN[\s\S]*Unlocked\. This shell holds your CYFR session/, 0, 60_000);
    t.type("exit");
    await Promise.race([t.exited, sleep(30_000)]);
    const records = deviceRecords(cliHome);
    const stored = records.length === 1 ? JSON.parse(readFileSync(records[0], "utf8")) : {};
    const text = records.length === 1 ? readFileSync(records[0], "utf8") : "";
    r.record = { pin_blob: !!stored.pin, passphrase_blob: !!stored.software, kind: stored.kind,
      evaluator_shape: /^pev_[A-Za-z0-9_-]{43}$/.test(stored.pin?.evaluator || ""), pending: !!stored.pin?.pending, pin_on_disk: text.includes(pin) };
    r.enroll_exit = t.exit;

    // Three wrong PINs, each counted; the waits are 1 s and 2 s between.
    r.wrong = [];
    for (const pause of [0, 1_200, 2_200]) {
      await sleep(pause);
      t = terminal(["login", "--context", "proof"], cliHome);
      await t.until(/Unlock this command line with its PIN: /);
      t.type(wrong);
      await Promise.race([t.exited, sleep(30_000)]);
      r.wrong.push({ exit: t.exit, counted: /That is not this command line's PIN\. CYFR counted the try/.test(t.out) });
    }
    // Within the 4 s wait after the third: the one sentence, nothing opened.
    t = terminal(["login", "--context", "proof"], cliHome);
    await t.until(/Unlock this command line with its PIN: /);
    t.type(pin);
    await Promise.race([t.exited, sleep(30_000)]);
    const waited = t.out.match(/Too many wrong PINs: CYFR takes this command line's next try at (\d\d:\d\d:\d\d)\./);
    r.wait = { said: !!waited, at: waited ? waited[1] : null, exit: t.exit };

    // After the wait the right PIN unlocks, and a confirmation in the shell
    // asks the PIN again.
    await sleep(4_500);
    t = terminal(["login", "--context", "proof"], cliHome);
    await t.until(/Unlock this command line with its PIN: /);
    t.type(pin);
    await t.until(/Unlocked\. This shell holds your CYFR session/, 0, 60_000);
    const digest = createHash("sha256").update(randomBytes(32)).digest("base64url");
    let mark = t.out.length;
    t.type(`cyfr pair ${digest} --context proof; echo "pair=$?"`);
    await t.until(/PIN or passphrase; press Enter once you confirmed it elsewhere: /, mark);
    t.type(pin);
    const paired = await t.until(/pair=(\d+)/, mark);
    r.unlock = { unlocked: true, confirm_exit: Number(paired[1]), link_printed: t.out.slice(mark).includes(`${base}/pair#code=`) };
    t.type("exit");
    await Promise.race([t.exited, sleep(30_000)]);

    // As after a reboot, with the home out of reach: nothing opens.
    const away = spawn("script", ["-qfec", `'${join(outDir, "bin", "cyfr")}' login --context proof`, "/dev/null"], {
      env: { ...process.env, HOME: cliHome, SHELL: "/bin/sh", HTTPS_PROXY: "http://127.0.0.1:9", CYFR_NO_UPDATE_CHECK: "1" },
    });
    let awayOut = "";
    away.stdout.on("data", (c) => { awayOut += c; if (/its PIN: $/.test(awayOut)) away.stdin.write(`${pin}\n`); });
    const awayExit = await new Promise((resolve) => away.on("close", resolve));
    r.home_away = { exit: awayExit, unreachable: /could not be reached/.test(awayOut), unlocked: /Unlocked\./.test(awayOut) };

    r.ok = r.confirmed_operation === "pin.enroll" && r.enroll_exit === 0 && r.record.pin_blob && !r.record.passphrase_blob &&
      r.record.kind === "software" && r.record.evaluator_shape && !r.record.pending && !r.record.pin_on_disk &&
      r.wrong.every((w) => w.exit !== 0 && w.counted) && r.wait.said && r.wait.exit !== 0 &&
      r.unlock.confirm_exit === 0 && r.unlock.link_printed &&
      r.home_away.exit !== 0 && r.home_away.unreachable && !r.home_away.unlocked;
    return r;
  } catch (error) {
    // A command line that waits where it should not: Go's goroutine dump,
    // written to its terminal by SIGQUIT, says where (the record keeps it).
    for (const pid of readdirSync("/proc").filter((d) => /^\d+$/.test(d))) {
      try {
        const argv = readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\0");
        if (argv[0] === join(outDir, "bin", "cyfr")) process.kill(Number(pid), "SIGQUIT");
      } catch {}
    }
    await sleep(2_000);
    r.terminal = t ? t.out.slice(-20_000) : null;
    record.pin = r;
    throw error;
  } finally {
    if (t && t.exit === null) t.kill();
  }
}

// A command line on another machine, a home directory of its own and a key
// of its own, given the desktop's link for the first command line's code:
// the home refuses its key, the pairing does not finish, and its record
// keeps no certificate. Answers what it saw.
async function otherMachine(link, code) {
  const otherHome = mkdtempSync(join(tmpdir(), "cyfr-command-line-other-"));
  let t = null;
  try {
    await cyfrRun(["context", "add", "proof", base], otherHome);
    t = terminal(["login", "--context", "proof"], otherHome);
    const drawn = await t.until(/Write it down:\s+([a-z]+(?: [a-z]+){5})\s/);
    await t.until(/The passphrase: /);
    t.type(drawn[1]);
    await t.until(/The passphrase again: /);
    t.type(drawn[1]);
    const own = (await t.until(/type:\s+((?:[A-Za-z0-9_-]{4} ){10}[A-Za-z0-9_-]{3})\s[\s\S]*Link or code: /))[1];
    const at = t.out.length;
    t.type(link);
    await Promise.race([t.exited, sleep(60_000)]);
    const said = t.out.slice(at);
    const records = deviceRecords(otherHome).map((f) => JSON.parse(readFileSync(f, "utf8")));
    const r = {
      own_code_differs: own !== code, exit: t.exit,
      refused: /Pairing did not finish/.test(said), sentence: said.replace(/\s+/g, " ").trim().slice(0, 400),
      certified: records.some((rec) => !!rec.certificate), unlocked: /Unlocked\./.test(said),
    };
    r.ok = r.own_code_differs && r.refused && !r.certified && !r.unlocked && r.exit !== 0;
    return r;
  } finally {
    if (t && t.exit === null) t.kill();
    rmSync(otherHome, { recursive: true, force: true });
  }
}

async function fresh(desk, phone, firstRef) {
  const name = "pairing-entry-2";
  const [first] = (await assertionsSent(phone)).filter((a) => a.ref === firstRef);
  await askForEntry(desk, name, "sk-pairing-2-not-shown");
  const shown = await phonePrompt(phone, name, [firstRef]);

  // The first assertion, replayed against this record through the
  // console's adapter under the phone's session: refused.
  const replay = first ? await ask({ op: "replay_assertion", ref: shown.ref, credential: first.credential }) : { error: "none captured" };
  // The desktop's session alone, asking again: still waiting, nothing made.
  // (submitted behind the open prompt, which takes every click)
  await desk.locator("#vault-create-form").evaluate((form) => form.requestSubmit());
  await sleep(1_500);
  const waiting = await desk.locator(`${layer} [data-test="confirmation"][data-own="true"] [data-status="waiting"]`).count();
  const before = (await vaultNames()).includes(name);

  // A fresh assertion on the phone alone.
  const confirmed = await confirmOnPhone(phone, shown.ref);
  const completed = await waitFor(async () => (await vaultNames()).includes(name), { timeoutMs: 30_000, stepMs: 1_000, what: name }).catch(() => false);
  const second = (await assertionsSent(phone)).find((a) => a.ref === shown.ref);
  const freshAssertion = !!first && !!second &&
    second.credential.response.signature !== first.credential.response.signature &&
    second.credential.response.clientDataJSON !== first.credential.response.clientDataJSON;
  record.fresh = {
    replay: { refused: !replay.ok && !!replay.error, error: replay.error || null },
    waiting_after_session_repeat: waiting, made_before_proof: before, confirmed, fresh_assertion: freshAssertion, completed,
  };
  return row("fresh", record.fresh.replay.refused && waiting === 1 && !before && freshAssertion && confirmed && completed,
    "a second request: the first assertion replayed and the desktop's session alone change nothing; the phone's fresh assertion confirms it",
    record.fresh);
}

// The test device (../browser/device.mjs): its key made in this process,
// its code typed on the desktop, the pairing confirmed in the phone's
// Prism, the pairing completed with its key, and its channel connected
// under the certificate the home answered, its confirmations stream open.
async function testDevice(desk, phone) {
  const device = newDevice({ name: "pairing proof test device" });
  const { secret } = await pairingFor(desk, phone, device.code);
  const paired = await pairDevice(device, { proxyPort: proxy.address().port, base, secret });
  if (paired.error) throw new Error(`the test device did not pair: ${JSON.stringify(paired.error)}`);
  const opened = await connectDevice(device, { proxyPort: proxy.address().port, base });
  if (!opened.channel) throw new Error(`the test device's channel closed ${opened.code}`);
  const stream = await opened.channel.intent("streams.open", { stream: "confirmation.changes" });
  return { device, ch: opened.channel, stream };
}

async function measure(ch) {
  const samples = [];
  const refused = [];
  for (let i = 1; i <= MEASURED; i++) {
    const answered = await ch.intent("confirmation.pending", {});
    if (answered.ok) samples.push(answered.ms);
    else refused.push(answered.error);
  }
  const rounded = Object.fromEntries(Object.entries(percentiles(samples)).map(([k, v]) => [k, typeof v === "number" && k !== "n" ? Math.round(v * 10) / 10 : v]));
  record.intent = { operation: "confirmation.pending", sequential: true, ...rounded, refused: refused.length };
  return row("intent", samples.length === MEASURED,
    "one discrete intent admitted and dispatched over the test device's channel and answered, timed from its frame to its answer (ms)",
    record.intent);
}

// A connection of the test device's own under the certificate it holds
// now: `connect`, the challenge signed, and the code the home closed it
// with, or "open" when it stood.
async function connectAsHeld(device) {
  const ch = channel(device, { proxyPort: proxy.address().port, base, purpose: "connect" });
  const outcome = await Promise.race([ch.opened.then(() => "open"), ch.closed, sleep(20_000).then(() => "timed out")]);
  if (outcome === "open") ch.close();
  return { code: outcome, seen: ch.log.filter((e) => e.dir === "in").map((e) => e.type) };
}

async function sleepBeyondExpiry(desk, phone, test) {
  const { device, ch } = test;
  const grant = ch.log.findLast((e) => e.dir === "in" && e.type === "grant");
  const expiresAt = ch.standing && ch.standing.expires_at;
  ch.sleep();
  // Asleep past the expiry, while the desktop asks for something more.
  await askForEntry(desk, "pairing-entry-3", "sk-pairing-3-not-shown");
  await sleep(Math.max(0, expiresAt - Date.now()) + 4_000);
  ch.wake();
  const closed = await Promise.race([ch.closed, sleep(20_000).then(() => "not closed")]);
  const asleep = ch.log.slice(ch.log.findIndex((e) => e.event === "sleep"));
  const grantRevoked = asleep.some((e) => e.dir === "in" && e.type === "revoke" && grant && e.grant_id === grant.grant_id);
  // The expired certificate opens nothing; a renewal on a new connection
  // stands, under a replacement, and the stream is granted anew.
  const expired = await connectAsHeld(device);
  const before = device.certificate.expires_at;
  const renewed = await connectDevice(device, { proxyPort: proxy.address().port, base });
  const next = renewed.channel;
  const stream = next ? await next.intent("streams.open", { stream: "confirmation.changes" }) : null;
  const newGrant = next ? await waitFor(() => next.log.find((e) => e.dir === "in" && e.type === "grant") || null, { timeoutMs: 10_000, what: "the stream's grant" }).catch(() => null) : null;
  const pending = next ? await next.intent("confirmation.pending", {}) : null;
  const asked = pending && pending.ok && (pending.result.confirmations || []).some((c) => JSON.stringify(c.preview || {}).includes("pairing-entry-3"));
  record.sleep = {
    expires_at: expiresAt, woke_ms_past_expiry: Date.now() - expiresAt,
    old_channel: { grant_revoked: grantRevoked, close: closed },
    expired_certificate_connect: expired,
    renewed: { stood: !!next, first_sent: next ? next.log.find((e) => e.dir === "out").type : null,
      certificate_moved: device.certificate.expires_at > before, stream_ok: !!(stream && stream.ok),
      granted_anew: !!newGrant && (!grant || newGrant.grant_id !== grant.grant_id) },
    asked_while_asleep_read: !!asked,
  };
  test.ch = next;
  // The request asked while the device slept, read, is cancelled: the
  // desktop's next request is then the only one it waits on.
  const asleepRequest = await phonePrompt(phone, "pairing-entry-3").catch(() => null);
  if (asleepRequest) {
    await phone.locator(`${layer} [data-test="confirmation"][data-ref="${asleepRequest.ref}"] [data-test="confirm-cancel"]`).click().catch(() => null);
    await phone.waitForSelector(`${layer} [data-test="confirmation"][data-ref="${asleepRequest.ref}"]`, { state: "detached", timeout: 30_000 }).catch(() => null);
  }
  record.sleep.asleep_request_cancelled = !!asleepRequest;
  return row("sleep",
    grantRevoked && closed === 4408 && expired.code === 4408 && !!next && record.sleep.renewed.first_sent === "renew" &&
      record.sleep.renewed.certificate_moved && record.sleep.renewed.granted_anew && record.sleep.asked_while_asleep_read,
    "asleep past its certificate's expiry, the test device's stream ends and its channel closes at the expiry; its expired certificate opens nothing; it renews on a new connection, its stream is granted anew and the request made meanwhile is read",
    record.sleep);
}

async function revoke(desk, phone, test) {
  const { device, ch } = test;
  const grant = ch.log.findLast((e) => e.dir === "in" && e.type === "grant");
  const from = ch.log.length;
  await openDevices(desk);
  const client = `${layer} [data-test="pairing-client"][data-client="${device.clientId}"]`;
  await desk.waitForSelector(client, { timeout: 30_000 });
  await pressRevoke(desk, client);

  // Revoking needs a fresh confirmation: the phone's Prism gives it.
  const shown = await phonePrompt(phone, "pairing.revoke");
  const confirmed = await confirmOnPhone(phone, shown.ref);
  const closed = await Promise.race([ch.closed, sleep(30_000).then(() => "not closed")]);
  await desk.waitForSelector(client, { state: "detached", timeout: 30_000 }).catch(() => null);
  const listed = await desk.locator(client).count();
  const log = ch.log.slice(from);
  const grantRevoked = log.some((e) => e.dir === "in" && e.type === "revoke" && grant && e.grant_id === grant.grant_id);
  const clientRevoked = log.some((e) => e.dir === "in" && e.type === "revoke" && !e.grant_id);
  const revokedConnect = await connectAsHeld(device);
  record.revoke = {
    preview: shown.preview, confirmed, grant_revoked: grantRevoked, client_revoked: clientRevoked,
    close: closed, still_listed: listed, revoked_certificate_connect: revokedConnect,
  };
  return row("revoke",
    /pairing\.revoke/.test(shown.preview) && confirmed && grantRevoked && clientRevoked && closed === 4403 &&
      listed === 0 && revokedConnect.code === 4403,
    "revoked under Devices and confirmed in the phone's Prism: the test device's stream ends, it is told and closed, Devices no longer lists it, and its last certificate opens nothing",
    record.revoke);
}

// The phone's steps once more on the handheld (HANDHELD): the phone signed
// in again in a context of its own, its authenticator holding the person's
// passkey carried from the phone's. Its Prism reads and confirms in its
// system layer a pairing's consent (for a test device's code), a
// credential entry the desktop asks for, and that device's revocation;
// each prompt meets the handheld's checks. The Prism page around the
// prompt is measured and recorded, not held.
async function handheld(browser, desk, phoneAuthenticator) {
  const context = await browser.newContext(HANDHELD);
  await context.addCookies([{
    name: "_cyfr_key", value: phoneCookie, url: base, httpOnly: true, secure: true, sameSite: "Lax",
  }]);
  const hand = await context.newPage();
  const authenticator = await virtualAuthenticator(hand);
  for (const credential of await phoneAuthenticator.credentials()) await authenticator.add(credential);
  const measured = {};

  // A pairing begun on the desktop for a test device's code, its consent
  // read and confirmed in the handheld's Prism.
  const device = newDevice({ name: "pairing proof handheld test device" });
  await beginFor(desk, device.code);
  const consent = await phonePrompt(hand, "pairing.begin");
  measured.consent_prompt = await measureScreen(hand, layer);
  const prismPage = await measureScreen(hand);
  const consentConfirmed = await confirmOnPhone(hand, consent.ref);
  await desk.waitForSelector(`${layer} [data-test="pairing-link"]`, { timeout: 30_000 });
  const link = await desk.locator(`${layer} [data-test="pairing-link"]`).inputValue();
  const deskCode = (await desk.locator(`${layer} [data-test="pairing-key-code"]`).textContent()).trim();
  const paired = await pairDevice(device, { proxyPort: proxy.address().port, base, secret: link.split("#code=")[1] });

  // A credential entry read and confirmed there.
  const name = "pairing-entry-handheld";
  await askForEntry(desk, name, "sk-pairing-handheld-not-shown");
  const shown = await phonePrompt(hand, name);
  measured.entry_prompt = await measureScreen(hand, layer);
  const entryConfirmed = await confirmOnPhone(hand, shown.ref);
  const completed = await waitFor(async () => (await vaultNames()).includes(name), { timeoutMs: 30_000, stepMs: 1_000, what: name }).catch(() => false);

  // The test device's revocation, confirmed there.
  await openDevices(desk);
  const client = `${layer} [data-test="pairing-client"][data-client="${device.clientId}"]`;
  await desk.waitForSelector(client, { timeout: 30_000 });
  await pressRevoke(desk, client);
  const revoking = await phonePrompt(hand, "pairing.revoke");
  measured.revoke_prompt = await measureScreen(hand, layer);
  const revokeConfirmed = await confirmOnPhone(hand, revoking.ref);
  await desk.waitForSelector(client, { state: "detached", timeout: 30_000 }).catch(() => null);
  const listed = await desk.locator(client).count();
  await context.close();

  const failures = unmet(measured);
  record.viewport = {
    viewport: HANDHELD.viewport, code: device.code, desktop_code: deskCode, consent: consent.preview, paired: !paired.error,
    entry: { preview: shown.preview, confirmed: entryConfirmed, completed }, revoke_preview: revoking.preview,
    revoked: revokeConfirmed && listed === 0, measured, failures, finding_prism_page: prismPage,
  };
  return row("viewport",
    /pairing\.begin/.test(consent.preview) && consentConfirmed && deskCode === device.code && !paired.error &&
      /vault\.create/.test(shown.preview) && shown.preview.includes(name) && entryConfirmed && completed &&
      /pairing\.revoke/.test(revoking.preview) && revokeConfirmed && listed === 0 && failures.length === 0,
    "at 720×720: a pairing's consent, a credential entry and a revocation, each read and confirmed with the passkey in the Prism's system layer, every control 24×24 CSS px or more, text 12 px or more, nothing overflowing",
    record.viewport);
}

// ---------------------------------------------------------------------------

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
let desk = null;
let phone = null;
try {
  const desktop = await signedIn(browser, base, desktopCookie);
  const phoneContext = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  await phoneContext.addCookies([{
    name: "_cyfr_key", value: phoneCookie, url: base, httpOnly: true, secure: true, sameSite: "Lax",
  }]);
  await phoneContext.addInitScript(instrumentAssertions);
  desk = await desktop.newPage();
  phone = await phoneContext.newPage();
  const authenticator = await virtualAuthenticator(phone);

  if (await passkey(phone, authenticator) && await commandLine(desk, phone)) {
    const [confirmed, firstRef] = await confirmEntry(desk, phone);
    if (confirmed && await fresh(desk, phone, firstRef)) {
      const test = await testDevice(desk, phone);
      await measure(test.ch);
      if (await sleepBeyondExpiry(desk, phone, test)) await revoke(desk, phone, test);
      await handheld(browser, desk, authenticator);
    }
  }
} catch (error) {
  failure = error.stack || String(error);
  console.error(`FAIL: ${failure}`);
  // Where each page stood when it failed.
  for (const [name, page] of [["desktop", desk], ["phone", phone]]) {
    if (!page) continue;
    const url = page.url().replace(/#code=.*/, "#code=…");
    const text = await page.locator("body").innerText({ timeout: 2_000 }).catch(() => "unread");
    console.error(`  ${name} at ${url}: ${JSON.stringify(text.slice(0, 3000))}`);
  }
} finally {
  await browser.close();
  proxy.close();
}

const STEPS = ["passkey", "pair", "other_key", "command_line", "renewal", "terminal_confirm", "open_ticket", "exit", "pin", "lost_answer",
  "confirm", "fresh", "intent", "sleep", "revoke", "viewport"];
const outcome = (step) => {
  const found = rows.find((r) => r.step === step);
  return found ? (found.held ? "held" : "FAILED") : "not reached";
};
writeFileSync(join(outDir, "pairing-proof.json"), JSON.stringify({ chromium: version, home: home.host, rows, record, failure }, null, 2));
const table = [
  `| step | chromium ${version} |`,
  "|---|---|",
  ...STEPS.map((step) => `| ${step} | ${outcome(step)} |`),
  "",
  `Device intent (\`confirmation.pending\`, ${MEASURED} sequential, timed over the test device's channel): ` +
    (record.intent ? `p50 ${record.intent.p50} ms, p95 ${record.intent.p95} ms, p99 ${record.intent.p99} ms (n ${record.intent.n})` : "not measured"),
];
writeFileSync(join(outDir, "pairing-proof.md"), table.join("\n") + "\n");
console.log(table.join("\n"));
if (failure || STEPS.some((step) => outcome(step) !== "held")) {
  console.error("FAIL: a step of the pairing proof did not hold");
  process.exit(1);
}
console.log("ok: every step held");
