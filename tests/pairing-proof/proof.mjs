// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The pairing proof, run in the official Playwright image by run.sh against
// a `cyfr` release behind the harness's HTTPS front (README.md). One
// person, two Chromium contexts: the desktop, signed in to Prism, and the
// phone, signed in to Prism in a context of its own until it becomes the
// glass. Each step is one row of the record; the proof fails when a row
// does not hold.
//
//   passkey      the phone registers its passkey, made by Chromium's
//                virtual authenticator, as the person's first method
//   pair         the phone opens this home's /pair page, which makes its
//                device key and shows the key's code; the desktop types that
//                code under Devices and begins a pairing for it; the phone's
//                Prism, reading the preview (the code among it) and the
//                asker, confirms it with that passkey; the desktop shows the
//                pairing link and its QR beside the code
//   other_key    a browser context of its own, which made its own key on
//                /pair, opens the desktop's link: refused, it holds no
//                device, and the link still pairs the phone
//   glass        the phone, the browser that showed the code, opens the
//                desktop's link and becomes the glass with the key it made:
//                the code leaves the address, and the device channel stands
//   confirm      the desktop asks for a credential entry; the glass shows
//                the home's preview and the asker before the proof, confirms
//                it with the passkey and says so, and the desktop completes
//                it
//   fresh        a second entry: a replayed assertion and the desktop's
//                session repeating alone change nothing; the glass's fresh
//                assertion confirms it and the desktop completes it
//   command_line the real cyfr binary run.sh built, run beside the
//                browsers and reaching the home through the same proxy,
//                runs cyfr login: it prints a link and a code; the desktop
//                opens the link, which leaves the address, shows the same
//                code and approves; the glass confirms with the passkey;
//                the binary saves its session, and cyfr whoami names the
//                person; Devices on the desktop lists the command line and
//                revokes it, after which its session opens nothing
//   intent       the device-intent measurement: one discrete intent
//                (`confirmation.pending`) admitted and dispatched over the
//                device channel and answered, sequentially, timed in the
//                glass's own page
//   sleep        the glass sleeps past its certificate's expiry: the home
//                ends the stream and closes the channel at the expiry; on
//                waking the glass renews before it sends anything, the
//                stream is granted anew, a request made while it slept is
//                shown, and the expired certificate opens nothing
//   revoke       the desktop revokes the glass under Devices, confirmed on
//                the glass: the home ends its stream, revokes it and closes
//                the channel; the glass forgets its key and certificate, and
//                its last certificate opens nothing
//   viewport     the glass's steps once more at the proposed handheld's
//                720×720 touch viewport (../browser/handheld.mjs): its key's
//                code typed on the desktop, a pairing's consent in the
//                Prism's system layer, the glass,
//                a confirmation on it, its reconnection and its revocation,
//                each screen meeting the handheld's checks
//
// The home's part of a step — the passkey's registration through the
// console's adapter, and the names of the person's vault entries — is
// run.sh's, asked for through OUT_DIR (`ask-N.json`, answered
// `answer-N.json`).
//
// Usage: node proof.mjs HOMES_FILE SEGMENT DESKTOP_COOKIE PHONE_COOKIE OUT_DIR
// (OUT_DIR/bin/cyfr is the command line run.sh built for the run)

import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HANDHELD, measure as measureScreen, unmet } from "../browser/handheld.mjs";
import {
  ask as askRunSh, launchBrowser, percentiles, readHomes, signedIn, sleep, startProxy, virtualAuthenticator, waitFor,
} from "../browser/lib.mjs";

const [homesFile, segment, desktopCookie, phoneCookie, outDir] = process.argv.slice(2);
if (!homesFile || !segment || !desktopCookie || !phoneCookie || !outDir) {
  console.error("usage: node proof.mjs HOMES_FILE SEGMENT DESKTOP_COOKIE PHONE_COOKIE OUT_DIR");
  process.exit(64);
}
mkdirSync(outDir, { recursive: true });

const { homes } = readHomes(homesFile);
const home = homes[0];
const base = home.origin;
const shell = `${base}/a/${encodeURIComponent(segment)}/tinctures`;
const vault = `${base}/a/${encodeURIComponent(segment)}/vault`;
const MEASURED = 100;
const rows = [];
const record = {};

function row(step, held, what, detail) {
  rows.push({ step, held: !!held, what, detail });
  console.log(`${held ? "held  " : "FAILED"} ${step}: ${what} — ${JSON.stringify(detail).slice(0, 2000)}`);
  return !!held;
}

// The home's part of a step, asked of run.sh (lib.mjs `ask`).
const ask = (request, options) => askRunSh(request, { outDir, timeoutMs: 90_000, ...options });

// ---------------------------------------------------------------------------
// The glass's device channel, watched from inside its own page
// ---------------------------------------------------------------------------

// Before any script of the phone's pages: every device-channel socket is
// one this records — each frame either way, by type, id and grant, with
// the page's own clock, and each close with its code — and through which
// the proof can speak as the glass (`window.__device.send`). Asleep
// (`window.__device.sleep()`), the glass sends nothing and hears nothing:
// what it sends is dropped, and what reaches it waits until it wakes
// (`wake()`), as a device's suspended page does.
//
// Every outcome the glass draws under a prompt is recorded as it is drawn
// (`window.__device.outcomes`): a confirmed record leaves the pending list
// at the glass's next read, taking its prompt and outcome with it, often
// within the frame that drew them, so the outcome is read as the page
// draws it rather than waited for.
function instrumentDevice() {
  const Native = window.WebSocket;
  const device = {
    log: [], sockets: 0, socket: null, asleep: false, held: [], outcomes: [],
    sleep() { this.asleep = true; this.log.push({ at: performance.now(), event: "sleep" }); },
    wake() {
      this.asleep = false;
      this.log.push({ at: performance.now(), event: "wake" });
      const held = this.held.splice(0);
      for (const deliver of held) deliver();
      window.dispatchEvent(new Event("online"));
    },
    send(map) { if (this.socket) Native.prototype.send.call(this.socket, JSON.stringify(map)); },
  };
  window.__device = device;
  const outcome = '[data-test="glass-outcome"]';
  new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        if (node.nodeType !== Node.ELEMENT_NODE) continue;
        for (const drawn of node.matches(outcome) ? [node] : node.querySelectorAll(outcome)) {
          const prompt = drawn.closest('[data-test="glass-prompt"]');
          device.outcomes.push({
            at: performance.now(), ref: prompt && prompt.getAttribute("data-ref"), ok: drawn.getAttribute("data-ok"),
            text: drawn.textContent,
          });
        }
      }
    }
  }).observe(document, { childList: true, subtree: true });
  const describe = (data) => {
    try {
      const map = JSON.parse(data);
      return {
        type: map.type, id: map.id, operation: map.operation, grant_id: map.grant_id, stream: map.stream,
        error: map.error ? (map.error.class || map.error.message || "error") : undefined,
        ok: map.type === "answer" ? !map.error : undefined,
      };
    } catch {
      return { type: "unreadable" };
    }
  };
  class Watched extends Native {
    constructor(url, protocols) {
      super(url, protocols);
      this.__device = /\/device\/websocket/.test(String(url));
      if (!this.__device) return;
      this.__serial = ++device.sockets;
      device.socket = this;
      device.log.push({ at: performance.now(), socket: this.__serial, event: "socket" });
      super.addEventListener("message", (event) =>
        device.log.push({ at: performance.now(), socket: this.__serial, dir: "in", ...describe(event.data), raw: event.data }));
      super.addEventListener("close", (event) =>
        device.log.push({ at: performance.now(), socket: this.__serial, event: "close", code: event.code, reason: event.reason }));
    }
    send(data) {
      if (!this.__device) return super.send(data);
      const described = describe(data);
      if (device.asleep) {
        device.log.push({ at: performance.now(), socket: this.__serial, dir: "dropped", ...described });
        return undefined;
      }
      device.log.push({ at: performance.now(), socket: this.__serial, dir: "out", ...described, raw: data });
      return super.send(data);
    }
    set onmessage(handler) { super.onmessage = this.__gate(handler); }
    get onmessage() { return super.onmessage; }
    set onclose(handler) { super.onclose = this.__gate(handler); }
    get onclose() { return super.onclose; }
    __gate(handler) {
      if (!this.__device || typeof handler !== "function") return handler;
      const socket = this;
      return function (event) {
        if (device.asleep) device.held.push(() => handler.call(socket, event));
        else handler.call(socket, event);
      };
    }
  }
  window.WebSocket = Watched;
}

// The glass's stored device, read from its own store in the page: its key
// (usable, never exportable), client id and certificate.
const storedDevice = (page) => page.evaluate(() => new Promise((resolve, reject) => {
  const open = indexedDB.open("cyfr-glass", 1);
  open.onupgradeneeded = () => open.result.createObjectStore("glass");
  open.onerror = () => reject(open.error);
  open.onsuccess = () => {
    const tx = open.result.transaction("glass", "readonly");
    const read = tx.objectStore("glass").get("device");
    read.onsuccess = () => {
      window.__heldDevice = read.result || null;
      resolve(read.result ? { clientId: read.result.clientId, certificate: read.result.certificate } : null);
    };
    read.onerror = () => reject(read.error);
  };
}));

// A connection of its own, from the glass's page, under the device it held
// last (`storedDevice`): `connect`, the challenge signed with the device
// key, and how the home closed it.
const connectAsHeld = (page) => page.evaluate(async () => {
  const held = window.__heldDevice;
  if (!held) return { error: "no device held" };
  const b64url = (buffer) => btoa(String.fromCharCode(...new Uint8Array(buffer)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const jcs = (value) => value === null || typeof value !== "object"
    ? JSON.stringify(value)
    : Array.isArray(value)
      ? `[${value.map(jcs).join(",")}]`
      : `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${jcs(value[k])}`).join(",")}}`;
  const url = `wss://${location.host}/device/websocket`;
  const Native = Object.getPrototypeOf(window.WebSocket.prototype).constructor;
  return new Promise((resolve) => {
    const seen = [];
    const ws = new Native(url);
    const done = setTimeout(() => { ws.close(); resolve({ seen, code: null, timedOut: true }); }, 20_000);
    ws.onopen = () => ws.send(JSON.stringify({
      protocol: "cyfr-device/v1", type: "connect", client_id: held.clientId, certificate: held.certificate,
    }));
    ws.onmessage = async (event) => {
      const map = JSON.parse(event.data);
      seen.push(map.type);
      if (map.type === "challenge") {
        const { sig: _sig, ...fields } = map.challenge;
        const sig = await crypto.subtle.sign({ name: "Ed25519" }, held.privateKey, new TextEncoder().encode(jcs(fields)));
        ws.send(JSON.stringify({ protocol: "cyfr-device/v1", type: "proof", proof: { ...fields, sig: b64url(sig) } }));
      }
    };
    ws.onclose = (event) => { clearTimeout(done); resolve({ seen, code: event.code, reason: event.reason }); };
  });
});

const deviceLog = (page) => page.evaluate(() => window.__device.log.map(({ raw: _raw, ...entry }) => entry));
const rawSent = (page, operation) => page.evaluate((op) => window.__device.log
  .filter((e) => e.dir === "out" && e.operation === op).map((e) => JSON.parse(e.raw)), operation);

// One intent spoken as the glass, and its answer: the time between them in
// the glass's page.
const intent = (page, id, operation, args) => page.evaluate(async ([intentId, op, intentArgs]) => {
  const device = window.__device;
  const from = device.log.length;
  const started = performance.now();
  device.send({ protocol: "cyfr-device/v1", type: "intent", id: intentId, operation: op, args: intentArgs });
  const deadline = started + 20_000;
  while (performance.now() < deadline) {
    const answer = device.log.slice(from).find((e) => e.dir === "in" && e.type === "answer" && e.id === intentId);
    if (answer) return { ok: answer.ok, error: answer.error, ms: answer.at - started };
    await new Promise((r) => setTimeout(r, 1));
  }
  return { ok: false, error: "no answer" };
}, [id, operation, args]);

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
// the page's own request waiting on its confirmation. Returns the provider
// it chose.
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
  // Every entry meets a need of the athanor's components, chosen by
  // provider; the browser sends no form without one. The proof's entry is
  // for no provider in particular, so it takes the first the form offers.
  const need = form.locator('select[name="need"] option:not([value=""])').first();
  const provider = (await need.textContent({ timeout: 30_000 })).trim();
  await form.locator('select[name="need"]').selectOption(await need.getAttribute("value"));
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
  return provider;
}

// The glass's prompt for the one record it shows that `skip` does not
// name: its ref, preview and asker as the glass drew them.
async function glassPrompt(phone, skip = []) {
  const handle = await waitFor(async () => {
    const prompts = await phone.$$('[data-test="glass-prompt"]');
    for (const prompt of prompts) {
      const ref = await prompt.getAttribute("data-ref");
      if (!skip.includes(ref)) return { prompt, ref };
    }
    return null;
  }, { timeoutMs: 30_000, what: "the glass's prompt" });
  const preview = await handle.prompt.$eval('[data-test="glass-preview"]', (e) => e.textContent);
  const asker = await handle.prompt.$eval('[data-test="glass-asker"]', (e) => e.textContent);
  return { ref: handle.ref, preview, asker, text: await handle.prompt.textContent() };
}

const glassButton = (phone, ref, test) => phone.locator(`[data-test="glass-prompt"][data-ref="${ref}"] [data-test="${test}"]`);

// The first outcome the glass drew under its prompt for `ref`, as
// `instrumentDevice` recorded it, or null when it drew none.
const glassOutcome = (phone, ref) => waitFor(
  () => phone.evaluate((shown) => window.__device.outcomes.find((o) => o.ref === shown) || null, ref),
  { timeoutMs: 30_000, stepMs: 100, what: `the glass's outcome for ${ref}` },
).then(({ ok, text }) => ({ ok, text })).catch(() => null);

const vaultNames = async () => (await ask({ op: "vault_names" })).names || [];

// The glass's page opened with no device and no link: it makes its device
// key and shows the key's code. Answers the code as the page shows it.
async function shownCode(page) {
  await page.goto(`${base}/pair`);
  const code = page.locator('[data-test="pair-key-code"]');
  await code.waitFor({ timeout: 30_000 });
  return (await code.textContent()).trim();
}

// The code typed into the desktop's pairing prompt, and the pairing begun
// for it: its request waits on its confirmation.
async function beginFor(desk, code) {
  await openDevices(desk);
  await desk.locator(`${layer} [data-test="pairing-key-input"]`).fill(code);
  await desk.locator(`${layer} [data-test="pairing-begin"]`).click();
  await desk.waitForSelector(`${layer} [data-test="confirmation"][data-own="true"]`, { timeout: 30_000 });
}

// The key digest the paired device's certificate names, as its code: the
// SHA-256 of the key's raw bytes, unpadded base64url, in groups of four.
const certifiedCode = (page, certificate) => page.evaluate(async (deviceKey) => {
  const base64 = deviceKey.replace(/-/g, "+").replace(/_/g, "/");
  const raw = Uint8Array.from(atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4)), (c) => c.charCodeAt(0));
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", raw));
  const b64url = btoa(String.fromCharCode(...digest)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return b64url.match(/.{1,4}/g).join(" ");
}, certificate.device_key);

const spaced = (text) => text.replace(/\s+/g, " ");

// ---------------------------------------------------------------------------
// The steps
// ---------------------------------------------------------------------------

async function passkey(phone, authenticator) {
  await phone.goto(shell);
  await connected(phone);
  const options = await ask({ op: "passkey_options" });
  const begun = options.ok;
  const credential = await phone.evaluate(async ({ public_key: json, registration }) => {
    const toBytes = (text) => {
      const base64 = text.replace(/-/g, "+").replace(/_/g, "/");
      const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
      return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0)).buffer;
    };
    const b64url = (buffer) => btoa(String.fromCharCode(...new Uint8Array(buffer)))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    const created = await navigator.credentials.create({
      publicKey: {
        ...json,
        challenge: toBytes(json.challenge),
        user: { ...json.user, id: toBytes(json.user.id) },
        excludeCredentials: (json.excludeCredentials || []).map((d) => ({ ...d, id: toBytes(d.id) })),
      },
    });
    return {
      id: created.id, rawId: b64url(created.rawId), type: created.type, registration,
      response: {
        clientDataJSON: b64url(created.response.clientDataJSON),
        attestationObject: b64url(created.response.attestationObject),
        transports: created.response.getTransports ? created.response.getTransports() : [],
      },
    };
  }, begun);
  const registered = await ask({ op: "passkey_register", credential });
  const held = (await authenticator.credentials()).filter((c) => c.rpId === home.host).length;
  record.passkey = { registered: registered.ok ? Object.keys(registered.ok) : registered, credentials_for_rp: held };
  return row("passkey", !!registered.ok && held === 1,
    "the phone's passkey, made by the virtual authenticator, is registered as the person's first method",
    record.passkey);
}

async function pair(desk, phone) {
  // The phone makes its key first, on this home's /pair page, and shows
  // its code; the desktop begins a pairing for that code.
  const code = await shownCode(phone);
  const unpaired = await phone.locator('[data-test="glass-status"]').getAttribute("data-state");
  await beginFor(desk, code);

  // The phone's Prism shows the request from the home's record, before
  // any proof, and confirms it with the passkey.
  await phone.goto(shell);
  await connected(phone);
  const prompt = `${layer} [data-test="confirmation"][data-own="false"]`;
  await phone.waitForSelector(prompt, { timeout: 30_000 });
  const preview = await phone.locator(`${prompt} [data-test="confirmation-preview"]`).first().textContent();
  const asker = await phone.locator(`${prompt} [data-test="confirmation-asker"]`).textContent();
  const restricted = await phone.locator(`${prompt} [data-test="confirmation-restricted"]`).count();
  await phone.locator(`${prompt} [data-test="confirm-passkey"]`).click();

  // Confirmed there, the desktop's pairing goes on: its link appears.
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
  record.pair = {
    code, phone_before: unpaired, preview: preview.trim(), asker: asker.trim(), restricted,
    link_shape: link.replace(/#code=.*/, "#code=…"), qr, desktop_code: deskCode, bearer_sentence: bearer,
  };
  return [row("pair", /pairing\.begin/.test(preview) && spaced(preview).includes(code) && /a browser signed in/.test(asker) &&
    link.startsWith(`${base}/pair#code=`) && qr === 1 && deskCode === code && !bearer,
    "the phone's /pair page shows its key's code; the desktop's pairing for that code, confirmed on the phone's Prism after its preview (the code among it) and asker, shows its link and QR beside the code",
    record.pair), link, code];
}

// A browser of its own, holding no session: it makes its own key on /pair,
// then opens the link the desktop's pairing gave for the phone's code. The
// home refuses its key, it is paired nothing, and the link still pairs the
// phone (the glass step, after this one).
async function otherKey(browser, link, code) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  try {
    const other = await context.newPage();
    const own = await shownCode(other);
    await other.goto(link);
    // A pairing that went through draws no error: what the page shows then
    // is recorded, and the row fails.
    const error = other.locator('[data-test="glass-error"]');
    const refused = await error.waitFor({ timeout: 30_000 }).then(() => error.textContent(), () => null);
    const status = await other.locator('[data-test="glass-status"]').getAttribute("data-state").catch(() => null);
    const address = await other.evaluate(() => location.href);
    const held = await storedDevice(other);
    record.other_key = {
      own_code_differs: own !== code, refused: refused && refused.trim(), status, address, holds_device: held !== null,
    };
    return row("other_key",
      own.length > 0 && own !== code && /not the one the pairing was approved for/.test(refused || "") &&
        address === `${base}/pair` && held === null,
      "a browser context that made its own key opens the link: refused, and it holds no device",
      record.other_key);
  } finally {
    await context.close();
  }
}

async function glass(phone, link, code, authenticator) {
  await phone.goto(link);
  await phone.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });
  const address = await phone.evaluate(() => location.href);
  const log = await deviceLog(phone);
  const opened = log.filter((e) => e.dir === "out").map((e) => e.type);
  const credentials = (await authenticator.credentials()).length;
  // The key that paired is the one whose code the phone showed.
  const held = await storedDevice(phone);
  const pairedCode = held ? await certifiedCode(phone, held.certificate) : null;
  record.glass = { address, sent: opened.slice(0, 4), credentials, paired_code_is_shown_code: pairedCode === code };
  return row("glass", address === `${base}/pair` && opened[0] === "connect" && opened.includes("proof") && credentials === 1 &&
    pairedCode === code,
    "the desktop's link opens the glass on the phone that showed the code, with the key it made: the code leaves the address and the device channel stands",
    record.glass);
}

async function confirmEntry(desk, phone) {
  const name = "pairing-entry-1";
  const provider = await askForEntry(desk, name, "sk-pairing-1-not-shown");
  const shown = await glassPrompt(phone);
  await glassButton(phone, shown.ref, "glass-passkey").click();
  const outcome = await glassOutcome(phone, shown.ref);
  const completed = await waitFor(async () => (await vaultNames()).includes(name), { timeoutMs: 30_000, stepMs: 1_000, what: name }).catch(() => false);
  record.confirm = {
    provider, ref: shown.ref, preview: shown.preview, asker: shown.asker,
    secret_shown: shown.text.includes("sk-pairing-1"), outcome, completed,
  };
  return [row("confirm", /vault\.create/.test(shown.preview) && shown.preview.includes(name) &&
    /a browser signed in/.test(shown.asker) && !record.confirm.secret_shown && outcome !== null && outcome.ok === "true" &&
    completed,
    "the glass shows the home's preview and the asker before the proof, confirms with the passkey and says so, and the desktop completes the entry",
    record.confirm), shown.ref];
}

// The command line run.sh built, run as a person runs it: a home of its own,
// the home reached through the run's proxy as the browsers reach it, and
// the run's authority trusted as the container's certificate bundle.
function cyfr(args, cliHome) {
  return spawn(join(outDir, "bin", "cyfr"), args, {
    env: {
      ...process.env,
      HOME: cliHome,
      HTTPS_PROXY: `http://127.0.0.1:${proxy.address().port}`,
      CYFR_NO_UPDATE_CHECK: "1",
    },
  });
}

// Run the command line to its end: its exit code and what it printed.
function cyfrRun(args, cliHome) {
  return new Promise((resolve) => {
    const child = cyfr(args, cliHome);
    let out = "";
    child.stdout.on("data", (chunk) => { out += chunk; });
    child.stderr.on("data", (chunk) => { out += chunk; });
    child.on("close", (code) => resolve({ code, out }));
  });
}

async function commandLine(desk, phone) {
  const cliHome = mkdtempSync(join(tmpdir(), "cyfr-command-line-"));
  try {
    const added = await cyfrRun(["context", "add", "proof", base], cliHome);
    const login = cyfr(["login", "--context", "proof"], cliHome);
    let out = "";
    login.stdout.on("data", (chunk) => { out += chunk; });
    login.stderr.on("data", (chunk) => { out += chunk; });
    const exited = new Promise((resolve) => login.on("close", (code) => resolve(code)));

    const printed = await waitFor(() => {
      const link = out.match(/(https:\/\/\S+\/cli#code=[A-Za-z0-9_-]{22})/);
      const code = out.match(/shows the code ([0-9A-Z]{4}-[0-9A-Z]{4})/);
      return link && code ? { link: link[1], code: code[1] } : null;
    }, { timeoutMs: 30_000, what: `cyfr login's link and code (${JSON.stringify(out)})` });

    await desk.goto(printed.link);
    await connected(desk);
    await desk.waitForSelector('[data-test="cli-code"]', { timeout: 30_000 });
    const shownCode = (await desk.locator('[data-test="cli-code"]').textContent()).trim();
    const left = !desk.url().includes("#code=");
    await desk.locator('[data-test="cli-approve"]').click();

    // Approving issues a session that outlives the desktop's: the glass
    // confirms it with the passkey.
    const shown = await glassPrompt(phone);
    await glassButton(phone, shown.ref, "glass-passkey").click();
    const exit = await Promise.race([exited, sleep(60_000).then(() => "still waiting")]);
    const saved = (() => {
      try {
        return !!JSON.parse(readFileSync(join(cliHome, ".cyfr", "config.json"), "utf8")).contexts.proof.token;
      } catch {
        return false;
      }
    })();
    const whoami = await cyfrRun(["whoami", "--context", "proof"], cliHome);

    await openDevices(desk);
    await desk.waitForSelector(`${layer} [data-test="command-line"]`, { timeout: 30_000 });
    const listed = await desk.locator(`${layer} [data-test="command-line"]`).first().textContent();
    await desk.locator(`${layer} [data-test="command-line-revoke"]`).first().click();
    await desk.waitForSelector(`${layer} [data-test="command-lines-none"]`, { timeout: 30_000 });
    const revoked = await cyfrRun(["whoami", "--context", "proof"], cliHome);

    record.command_line = {
      code: printed.code, shown_code: shownCode, link_left_address: left, preview: shown.preview,
      asker: shown.asker, login_exit: exit, signed_in: /Signed in as operator@example\.com/.test(out),
      saved, whoami_exit: whoami.code, whoami_names_person: whoami.out.includes("operator@example.com"),
      listed: spaced(listed).trim(), revoked_whoami_exit: revoked.code,
    };
    return row("command_line",
      added.code === 0 && shownCode === printed.code && left && /session\.cli_approve/.test(shown.preview) &&
        shown.preview.includes(printed.code) && exit === 0 && record.command_line.signed_in && saved &&
        whoami.code === 0 && record.command_line.whoami_names_person && /Command line on/.test(listed) &&
        revoked.code !== 0,
      "cyfr login's link, opened on the desktop, shows the code it printed; approved there and confirmed on the glass, the binary holds the person's session, listed under Devices, where revoking it ends it",
      record.command_line);
  } finally {
    rmSync(cliHome, { recursive: true, force: true });
  }
}

async function fresh(desk, phone, firstRef) {
  const name = "pairing-entry-2";
  const [first] = await rawSent(phone, "confirmation.confirm");
  await askForEntry(desk, name, "sk-pairing-2-not-shown");
  const shown = await glassPrompt(phone, [firstRef]);

  // The first assertion, replayed against this record: refused.
  const replay = await intent(phone, "replay_1", "confirmation.confirm", { ref: shown.ref, assertion: first.args.assertion });
  // The desktop's session alone, asking again: still waiting, nothing made.
  // (submitted behind the open prompt, which takes every click)
  await desk.locator("#vault-create-form").evaluate((form) => form.requestSubmit());
  await sleep(1_500);
  const waiting = await desk.locator(`${layer} [data-test="confirmation"][data-own="true"] [data-status="waiting"]`).count();
  const before = (await vaultNames()).includes(name);

  // A fresh assertion on the glass alone.
  await glassButton(phone, shown.ref, "glass-passkey").click();
  const completed = await waitFor(async () => (await vaultNames()).includes(name), { timeoutMs: 30_000, stepMs: 1_000, what: name }).catch(() => false);
  const second = (await rawSent(phone, "confirmation.confirm")).find((m) => m.args.ref === shown.ref && m.id !== "replay_1");
  const freshAssertion = !!second && second.args.assertion.response.signature !== first.args.assertion.response.signature &&
    second.args.assertion.response.clientDataJSON !== first.args.assertion.response.clientDataJSON;
  record.fresh = { replay, waiting_after_session_repeat: waiting, made_before_proof: before, fresh_assertion: freshAssertion, completed };
  return row("fresh", replay.ok === false && waiting === 1 && !before && freshAssertion && completed,
    "a second request: a replayed assertion and the desktop's session alone change nothing; the glass's fresh assertion confirms it",
    record.fresh);
}

async function measure(phone) {
  const samples = [];
  const refused = [];
  for (let i = 1; i <= MEASURED; i++) {
    const answered = await intent(phone, `measure_${i}`, "confirmation.pending", {});
    if (answered.ok) samples.push(answered.ms);
    else refused.push(answered.error);
  }
  const rounded = Object.fromEntries(Object.entries(percentiles(samples)).map(([k, v]) => [k, typeof v === "number" && k !== "n" ? Math.round(v * 10) / 10 : v]));
  record.intent = { operation: "confirmation.pending", sequential: true, ...rounded, refused: refused.length };
  return row("intent", samples.length === MEASURED,
    "one discrete intent admitted and dispatched over the device channel and answered, timed in the glass's page (ms)",
    record.intent);
}

async function sleepBeyondExpiry(desk, phone) {
  const before = await storedDevice(phone);
  const expires = before.certificate.expires_at;
  const expiresMs = expires < 1e12 ? expires * 1000 : expires;
  const from = (await deviceLog(phone)).length;
  const oldSocket = await phone.evaluate(() => window.__device.sockets);
  const oldGrant = (await deviceLog(phone)).filter((e) => e.dir === "in" && e.type === "grant").at(-1);

  await phone.evaluate(() => window.__device.sleep());
  // Asleep past the expiry, while the desktop asks for something more.
  await askForEntry(desk, "pairing-entry-3", "sk-pairing-3-not-shown");
  await sleep(Math.max(0, expiresMs - Date.now()) + 4_000);
  const wokeAt = Date.now();
  await phone.evaluate(() => window.__device.wake());
  await phone.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });
  const shown = await glassPrompt(phone).catch(() => null);

  const log = (await deviceLog(phone)).slice(from);
  const onOld = log.filter((e) => e.socket === oldSocket);
  const closed = onOld.find((e) => e.event === "close");
  const grantRevoked = onOld.some((e) => e.dir === "in" && e.type === "revoke" && e.grant_id === (oldGrant && oldGrant.grant_id));
  const dropped = log.filter((e) => e.dir === "dropped").map((e) => e.type);
  const next = log.filter((e) => e.socket > oldSocket);
  const sentNext = next.filter((e) => e.dir === "out");
  const standingAt = next.findIndex((e) => e.dir === "in" && e.type === "standing");
  const beforeStanding = standingAt < 0 ? next : next.slice(0, standingAt);
  const intentBeforeStanding = beforeStanding.some((e) => e.dir === "out" && e.type === "intent");
  const newGrant = next.find((e) => e.dir === "in" && e.type === "grant");
  const expired = await connectAsHeld(phone);
  record.sleep = {
    woke_seconds_past_expiry: Math.round((wokeAt - expiresMs) / 1000),
    dropped_while_asleep: dropped,
    old_channel: { grant_revoked: grantRevoked, close: closed ? closed.code : null },
    first_sent_after_wake: sentNext[0] ? sentNext[0].type : null,
    intent_before_standing: intentBeforeStanding,
    stream_granted_anew: !!newGrant && (!oldGrant || newGrant.grant_id !== oldGrant.grant_id),
    asked_while_asleep_shown: !!(shown && shown.preview.includes("pairing-entry-3")),
    expired_certificate_connect: expired,
  };
  if (shown) await glassButton(phone, shown.ref, "glass-cancel").click().catch(() => null);
  return row("sleep",
    grantRevoked && closed && closed.code === 4408 && record.sleep.first_sent_after_wake === "renew" &&
      !intentBeforeStanding && record.sleep.stream_granted_anew && record.sleep.asked_while_asleep_shown &&
      expired.code === 4408,
    "asleep past its certificate's expiry, the glass's stream ends and its channel closes at the expiry; awake, it renews before anything else, and the expired certificate opens nothing",
    record.sleep);
}

async function revoke(desk, phone) {
  const held = await storedDevice(phone);
  const from = (await deviceLog(phone)).length;
  const socket = await phone.evaluate(() => window.__device.sockets);
  await openDevices(desk);
  await desk.waitForSelector(`${layer} [data-test="pairing-client"][data-client="${held.clientId}"]`, { timeout: 30_000 });
  await desk.locator(`${layer} [data-test="pairing-client"][data-client="${held.clientId}"] [data-test="pairing-revoke"]`).click();

  // Revoking needs a fresh confirmation: the glass gives it.
  const shown = await glassPrompt(phone);
  await glassButton(phone, shown.ref, "glass-passkey").click();
  await phone.waitForSelector('[data-test="glass-status"][data-state="revoked"]', { timeout: 60_000 });
  await desk.waitForSelector(`${layer} [data-test="pairing-none"]`, { timeout: 30_000 }).catch(() => null);
  const listed = await desk.locator(`${layer} [data-test="pairing-client"][data-client="${held.clientId}"]`).count();

  const log = (await deviceLog(phone)).slice(from).filter((e) => e.socket === socket);
  const grantRevoked = log.some((e) => e.dir === "in" && e.type === "revoke" && e.grant_id);
  const clientRevoked = log.some((e) => e.dir === "in" && e.type === "revoke" && !e.grant_id);
  const closed = log.find((e) => e.event === "close");
  const stored = await phone.evaluate(() => new Promise((resolve) => {
    const open = indexedDB.open("cyfr-glass", 1);
    open.onsuccess = () => {
      const read = open.result.transaction("glass", "readonly").objectStore("glass").get("device");
      read.onsuccess = () => resolve(!!read.result);
      read.onerror = () => resolve(null);
    };
    open.onerror = () => resolve(null);
  }));
  const revokedConnect = await connectAsHeld(phone);
  record.revoke = {
    preview: shown.preview, grant_revoked: grantRevoked, client_revoked: clientRevoked,
    close: closed ? closed.code : null, still_listed: listed, glass_keeps_device: stored,
    revoked_certificate_connect: revokedConnect,
  };
  return row("revoke",
    /pairing\.revoke/.test(shown.preview) && grantRevoked && clientRevoked && closed && closed.code === 4403 &&
      listed === 0 && stored === false && revokedConnect.code === 4403,
    "revoked under Devices and confirmed on the glass: its stream ends, it is told and closed, it forgets its key and certificate, and its last certificate opens nothing",
    record.revoke);
}

// The glass's steps once more on the proposed handheld (HANDHELD): the
// phone signed in again in a context of its own, its authenticator holding
// the person's passkey carried from the phone's. Its Prism reads and
// confirms a pairing in the system layer; it becomes the glass, confirms a
// credential entry, reconnects and is revoked there, and each of those
// screens meets the handheld's checks. The Prism page around the prompt is
// measured and recorded, not held.
async function handheld(browser, desk, phoneAuthenticator) {
  const context = await browser.newContext(HANDHELD);
  await context.addCookies([{
    name: "_cyfr_key", value: phoneCookie, url: base, httpOnly: true, secure: true, sameSite: "Lax",
  }]);
  await context.addInitScript(instrumentDevice);
  const hand = await context.newPage();
  const authenticator = await virtualAuthenticator(hand);
  for (const credential of await phoneAuthenticator.credentials()) await authenticator.add(credential);
  const measured = {};

  // Its key made first, and its code shown, measured and recorded; then a
  // pairing begun on the desktop for that code, its consent read and
  // confirmed in the Prism's system layer.
  const code = await shownCode(hand);
  const codeScreen = await measureScreen(hand);
  await beginFor(desk, code);
  await hand.goto(shell);
  await connected(hand);
  const prompt = `${layer} [data-test="confirmation"][data-own="false"]`;
  await hand.waitForSelector(`${prompt} [data-test="confirm-passkey"]`, { timeout: 30_000 });
  const consent = (await hand.locator(`${prompt} [data-test="confirmation-preview"]`).first().textContent()).trim();
  measured.consent_prompt = await measureScreen(hand, layer);
  const prismPage = await measureScreen(hand);
  await hand.locator(`${prompt} [data-test="confirm-passkey"]`).click();
  await desk.waitForSelector(`${layer} [data-test="pairing-link"]`, { timeout: 30_000 });
  const link = await desk.locator(`${layer} [data-test="pairing-link"]`).inputValue();
  const deskCode = (await desk.locator(`${layer} [data-test="pairing-key-code"]`).textContent()).trim();

  // The glass.
  await hand.goto(link);
  await hand.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });
  measured.glass_ready = await measureScreen(hand, "#glass");
  const held = await storedDevice(hand);

  // A credential entry read and confirmed on the glass.
  const name = "pairing-entry-handheld";
  await askForEntry(desk, name, "sk-pairing-handheld-not-shown");
  const shown = await glassPrompt(hand);
  measured.glass_prompt = await measureScreen(hand, "#glass");
  await glassButton(hand, shown.ref, "glass-passkey").click();
  const outcome = await glassOutcome(hand, shown.ref);
  const completed = await waitFor(async () => (await vaultNames()).includes(name), { timeoutMs: 30_000, stepMs: 1_000, what: name }).catch(() => false);

  // Reconnecting: the glass's page opened again connects under the device
  // it holds.
  await hand.goto(`${base}/pair`);
  await hand.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });
  measured.reconnected = await measureScreen(hand, "#glass");

  // Revocation, confirmed on the glass.
  await openDevices(desk);
  const client = `${layer} [data-test="pairing-client"][data-client="${held.clientId}"]`;
  await desk.waitForSelector(client, { timeout: 30_000 });
  await desk.locator(`${client} [data-test="pairing-revoke"]`).click();
  const revoking = await glassPrompt(hand);
  measured.revoke_prompt = await measureScreen(hand, "#glass");
  await glassButton(hand, revoking.ref, "glass-passkey").click();
  await hand.waitForSelector('[data-test="glass-status"][data-state="revoked"]', { timeout: 60_000 });
  measured.revoked = await measureScreen(hand, "#glass");
  await context.close();

  const failures = unmet(measured);
  record.viewport = {
    viewport: HANDHELD.viewport, code, desktop_code: deskCode, consent, entry: { preview: shown.preview, outcome, completed },
    revoke_preview: revoking.preview, measured, failures, finding_prism_page: prismPage, finding_code_screen: codeScreen,
  };
  return row("viewport",
    /pairing\.begin/.test(consent) && deskCode === code && link.startsWith(`${base}/pair#code=`) && !!held &&
      /vault\.create/.test(shown.preview) && shown.preview.includes(name) && outcome !== null && outcome.ok === "true" &&
      completed && /pairing\.revoke/.test(revoking.preview) && failures.length === 0,
    "at 720×720: its key's code typed on the desktop, a pairing's consent read and confirmed in the Prism's system layer, the glass, a credential entry confirmed on it, its reconnection and its revocation, every control 24×24 CSS px or more, text 12 px or more, nothing overflowing",
    record.viewport);
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
let desk = null;
let phone = null;
try {
  const desktop = await signedIn(browser, base, desktopCookie);
  const phoneContext = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  await phoneContext.addCookies([{
    name: "_cyfr_key", value: phoneCookie, url: base, httpOnly: true, secure: true, sameSite: "Lax",
  }]);
  await phoneContext.addInitScript(instrumentDevice);
  desk = await desktop.newPage();
  phone = await phoneContext.newPage();
  const authenticator = await virtualAuthenticator(phone);

  if (await passkey(phone, authenticator)) {
    const [paired, link, code] = await pair(desk, phone);
    if (paired) await otherKey(browser, link, code);
    if (paired && await glass(phone, link, code, authenticator)) {
      const [confirmed, firstRef] = await confirmEntry(desk, phone);
      if (confirmed && await fresh(desk, phone, firstRef)) {
        await commandLine(desk, phone);
        await measure(phone);
        await sleepBeyondExpiry(desk, phone);
        await revoke(desk, phone);
        await handheld(browser, desk, authenticator);
      }
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
  if (phone) {
    const log = await phone.evaluate(() => window.__device ? window.__device.log.slice(-40).map(({ raw: _raw, ...e }) => e) : null).catch(() => null);
    console.error(`  the glass's last frames: ${JSON.stringify(log)}`);
  }
} finally {
  await browser.close();
  proxy.close();
}

const STEPS = ["passkey", "pair", "other_key", "glass", "confirm", "fresh", "command_line", "intent", "sleep", "revoke", "viewport"];
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
  `Device intent (\`confirmation.pending\`, ${MEASURED} sequential, timed in the glass's page): ` +
    (record.intent ? `p50 ${record.intent.p50} ms, p95 ${record.intent.p95} ms, p99 ${record.intent.p99} ms (n ${record.intent.n})` : "not measured"),
];
writeFileSync(join(outDir, "pairing-proof.md"), table.join("\n") + "\n");
console.log(table.join("\n"));
if (failure || STEPS.some((step) => outcome(step) !== "held")) {
  console.error("FAIL: a step of the pairing proof did not hold");
  process.exit(1);
}
console.log("ok: every step held");
