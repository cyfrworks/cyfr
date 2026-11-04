// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The join proof's terminal step (README.md, `terminal`): the person's
// command line, a device of theirs at A, pairs at H, which keeps none of
// their keys, by a certification it obtains at A in the terminal, with no
// browser; then it confirms a change at H on itself. The command line is
// the real cyfr binary run.sh builds into the output directory's bin/,
// run on a pseudo-terminal of its own (script(1)) beside the browsers,
// reaching the homes through the run's proxy.

import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { measure } from "../browser/handheld.mjs";
import {
  A, H, ask, authenticatorWith, closePrompt, confirmHere, connected, credentialsFor, layer, open, outDir, passkeySignIn,
  pressInLayer, record, row, secrets, sleep, waitFor,
} from "./common.mjs";

const shellAt = (base, slug) => `${base}/a/${encodeURIComponent(slug)}/canvas`;
const DRAWN = /Write it down:\s+([a-z]+(?: [a-z]+){5})\s/;
const CODE = /type:\s+((?:[A-Za-z0-9_-]{4} ){10}[A-Za-z0-9_-]{3})\s[\s\S]*Link or code: /;
const UNLOCKED = /Unlocked\. This shell holds your CYFR session/;
const CONFIRM_HERE = /PIN or passphrase; press Enter once you confirmed it elsewhere: /;
const spaced = (text) => text.replace(/\s+/g, "");

// cyfr login under script(1)'s pseudo-terminal, as a person runs it, its
// shell /bin/sh: `type` sends a line to whatever reads the terminal,
// `until` waits for output matching a pattern after `from`.
function terminal(args, cliHome, proxy) {
  const command = [join(outDir, "bin", "cyfr"), ...args].map((a) => `'${a.replace(/'/g, "'\\''")}'`).join(" ");
  const child = spawn("script", ["-qfec", command, "/dev/null"], {
    env: {
      ...process.env,
      HOME: cliHome,
      SHELL: "/bin/sh",
      PS1: "$ ",
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
  t.until = (pattern, from = 0, timeoutMs = 60_000) => waitFor(() => t.out.slice(from).match(pattern), {
    timeoutMs, what: `the terminal to show ${pattern} (${JSON.stringify(t.out.slice(from).slice(-600))})`,
  });
  t.kill = () => child.kill("SIGKILL");
  t.end = async () => {
    t.type("exit");
    return Promise.race([t.exited, sleep(30_000).then(() => "still running")]);
  };
  return t;
}

// The new command line's key made under the passphrase it shows, typed
// twice; answers that passphrase and the key's code.
async function madeKey(t) {
  const pass = (await t.until(DRAWN))[1];
  secrets.push(pass);
  await t.until(/The passphrase: /);
  t.type(pass);
  await t.until(/The passphrase again: /);
  t.type(pass);
  return { pass, code: (await t.until(CODE))[1] };
}

// The code typed under a home's Devices on a page signed in there, the
// addition confirmed with that page's passkey; answers the link and the
// preview confirmed.
async function approve(page, url, code) {
  await open(page, url);
  await page.locator("#shell-devices").click();
  await page.waitForSelector(`${layer} [data-test="pairing"]`, { timeout: 30_000 });
  await page.locator(`${layer} [data-test="pairing-key-input"]`).fill(code);
  const press = await pressInLayer(page, '[data-test="pairing-begin"]');
  const preview = await confirmHere(page);
  await page.waitForSelector(`${layer} [data-test="pairing-link"]`, { timeout: 30_000 });
  const link = await page.locator(`${layer} [data-test="pairing-link"]`).inputValue();
  await closePrompt(page);
  secrets.push(link.split("#code=")[1]);
  return { link, preview, press };
}

// The certificate the command line's record for base keeps.
function heldCertificate(cliHome, base) {
  const dir = join(cliHome, ".cyfr", "devices");
  for (const file of readdirSync(dir)) {
    const rec = JSON.parse(readFileSync(join(dir, file), "utf8"));
    if (rec.home === base && rec.certificate) return rec.certificate;
  }
  return null;
}

// The command line's home directory, kept for the steps after the
// terminal's (renewal and recertify), and removed when the proof ends.
let kept = null;
process.on("exit", () => { if (kept) rmSync(kept, { recursive: true, force: true }); });

export async function terminalStep(proxy, state) {
  const { home, hubPage, hubAthanor, identifier } = state;
  const cliHome = mkdtempSync(join(tmpdir(), "cyfr-join-terminal-"));
  kept = cliHome;
  const rec = {};
  let t = null;
  try {
    // A device of the person's at A first, approved at A.
    t = terminal(["login", "--url", A], cliHome, proxy);
    const atA = await madeKey(t);
    const approvedA = await approve(home.desk, shellAt(A, home.segment), atA.code);
    let mark = t.out.length;
    t.type(approvedA.link);
    await t.until(UNLOCKED, mark, 60_000);
    rec.at_a = { exit: await t.end() };

    // At H, which keeps none of their keys: the code approved there, the
    // link pasted, and the certification asked at A in this terminal.
    t = terminal(["login", "--url", H], cliHome, proxy);
    const atH = await madeKey(t);
    const approvedH = await approve(hubPage, shellAt(H, hubAthanor), atH.code);
    const seenFrom = proxy.seen.length;
    mark = t.out.length;
    t.type(approvedH.link);
    await t.until(/Your own CYFR's address: /, mark);
    t.type(A);
    await t.until(/Unlock this command line at \S+ with its passphrase: /, mark);
    t.type(atA.pass);
    const asked = await t.until(CONFIRM_HERE, mark, 90_000);
    const before = t.out.slice(mark, mark + asked.index);
    t.type(atA.pass);
    await t.until(UNLOCKED, mark, 90_000);
    const certifying = t.out.slice(mark);
    const atAHost = new URL(A).host;
    const fromA = proxy.seen.slice(seenFrom).filter((r) => r.host === atAHost && r.method !== "CONNECT");
    const cert = heldCertificate(cliHome, H);
    const certifications = (await ask({ op: "certifications", cell: "a" })).certifications;
    const clients = (await ask({ op: "paired", cell: "h", identifier })).paired;
    rec.certified = {
      preview_before_secret: /person\.certify/.test(before) && before.includes(H),
      secret_asked_once: (certifying.match(/PIN or passphrase/g) || []).length === 1,
      passphrase_echoed: certifying.split(atA.pass).length - 1,
      issuer: cert && cert.issuer, audience: cert && cert.audience, subject: cert && cert.subject && cert.subject.kind,
      at_a: certifications.filter((c) => c.audience === H && cert && c.client_id === cert.client_id).map((c) => c.state),
      at_h: clients.filter((c) => cert && c.id === cert.client_id).map((c) => c.standing),
      a_requests: fromA.length,
      a_from_a_browser: fromA.filter((r) => r.fetch && (r.fetch.site || r.fetch.mode) || r.cookie || /\/carry/.test(r.url)).length,
    };
    mark = t.out.length;
    t.type(`cyfr whoami --url ${H}; echo "whoami=$?"`);
    rec.certified.whoami_exit = Number((await t.until(/whoami=(\d+)/, mark))[1]);

    // A change at H confirmed on this command line, certified by A:
    // another device's addition, its preview drawn before the passphrase.
    const digest = createHash("sha256").update(randomBytes(32)).digest("base64url");
    mark = t.out.length;
    t.type(`cyfr pair ${digest} --url ${H}; echo "pair=$?"`);
    const confirm = await t.until(CONFIRM_HERE, mark, 90_000);
    const drawn = t.out.slice(mark, mark + confirm.index);
    t.type(atH.pass);
    const paired = await t.until(/pair=(\d+)/, mark, 90_000);
    const done = t.out.slice(mark);
    rec.confirmed = {
      preview_before_secret: /pairing\.begin/.test(drawn) && spaced(drawn).includes(digest.slice(0, 4)),
      secret_asked_once: (done.match(/PIN or passphrase/g) || []).length === 1,
      pair_exit: Number(paired[1]), link_printed: done.includes(`${H}/pair#code=`),
      passphrase_echoed: done.split(atH.pass).length - 1,
    };
    rec.exit = await t.end();
    record.terminal = rec;
    state.terminal = { cliHome, passA: atA.pass, passH: atH.pass, clientId: cert && cert.client_id };
    const c = rec.certified;
    const k = rec.confirmed;
    return row("terminal", "chromium",
      rec.at_a.exit === 0 && c.preview_before_secret && c.secret_asked_once && c.passphrase_echoed === 0 &&
        c.issuer === A && c.audience === H && c.subject === "identity" && c.at_a.length === 1 && c.at_a[0] === "active" &&
        c.at_h.length === 1 && c.at_h[0] === "active" && c.a_requests > 0 && c.a_from_a_browser === 0 && c.whoami_exit === 0 &&
        k.preview_before_secret && k.secret_asked_once && k.pair_exit === 0 && k.link_printed && k.passphrase_echoed === 0 &&
        rec.exit === 0,
      "a command line that is the person's device at A pairs at H by a certification it obtains at A in the terminal, unlocked afresh there and confirmed over A's preview, with no browser; then it confirms a change at H on itself",
      rec);
  } catch (error) {
    record.terminal = { ...rec, error: String(error && error.message), out: t && t.out.slice(-2000) };
    return row("terminal", "chromium", false, "the terminal step ran to its end", record.terminal);
  } finally {
    if (t && t.exit === null) t.kill();
  }
}

// ---------------------------------------------------------------------------
// A remote person's confirmation, given at their own CYFR
// ---------------------------------------------------------------------------

// The request `ref` that `page`'s Prism at H shows (its own, or another
// client's) confirmed through the person's own CYFR `home`: the panel's
// "Confirm at your CYFR" with `home` typed, the link it then offers opened
// in a tab of the same browser, `home`'s /carry#confirm= page showing the
// change, confirmed there with a fresh passkey proof, and the browser sent
// back to H's /confirm#home_assertion=, which confirms the record under the
// person's head read fresh from their directory. With `hold`, H's /confirm
// page is answered by the proof instead, so the assertion is captured and
// H never receives it. `measured` gathers the screens on the way. Answers
// what each page showed and the assertion's fragment.
export async function confirmAtHome(page, ref, home, { hold = false, measured = null } = {}) {
  const panel = `${layer} [data-test="confirmation"][data-ref="${ref}"]`;
  await page.waitForSelector(`${panel} [data-test="confirm-at-home"]`, { timeout: 30_000 });
  if (measured) measured.request = await measure(page, layer);
  await page.locator(`${panel} [data-test="confirm-at-home-address"]`).fill(home);
  await page.locator(`${panel} [data-test="confirm-at-home-submit"]`).click();
  const link = page.locator(`${panel} [data-test="confirm-at-home-open"]`);
  await link.waitFor({ timeout: 30_000 });
  const href = await link.getAttribute("href");
  const tab = await page.context().newPage();
  // A virtual authenticator is a page's: the tab is given the passkeys the
  // page holds for the person's own CYFR, as a synced passkey reaches it.
  await authenticatorWith(tab, await credentialsFor(page, new URL(home).host));
  const urls = [];
  tab.on("framenavigated", (frame) => { if (frame === tab.mainFrame()) urls.push(frame.url()); });
  if (hold) {
    await tab.route(`${H}/confirm*`, (route) =>
      route.fulfill({ status: 200, contentType: "text/html", body: "<!doctype html><title>held by the proof</title>" }));
  }
  try {
    await tab.goto(href);
    await tab.waitForURL((url) => url.origin === home, { timeout: 60_000 });
    await connected(tab);
    if (new URL(tab.url()).pathname === "/login") {
      await passkeySignIn(tab, home);
      await tab.waitForURL((url) => url.origin === home && url.pathname === "/carry", { timeout: 60_000 });
    }
    await tab.waitForSelector('[data-test="carry-confirm"]', { timeout: 60_000 });
    const preview = (await tab.locator('[data-test="carry-confirm-preview"]').innerText()).replace(/\s+/g, " ").trim();
    if (measured) measured.home_confirm = await measure(tab, '[data-test="carry-confirm"]');
    await tab.locator('[data-test="confirm-continue"]').click();
    if (measured) {
      await tab.waitForSelector(`${layer} [data-test="confirmation"][data-own="true"] [data-test="confirm-passkey"]`, { timeout: 30_000 });
      measured.home_prompt = await measure(tab, layer);
    }
    const atHome = await confirmHere(tab);
    await tab.waitForURL((url) => url.origin === H && url.pathname === "/confirm", { timeout: 60_000 });
    const sent = urls.find((u) => u.startsWith(`${H}/confirm#home_assertion=`)) || null;
    const assertion = sent ? sent.split("#home_assertion=")[1] : null;
    if (assertion) secrets.push(assertion);
    let done = null;
    if (!hold) {
      done = await Promise.race([
        tab.waitForSelector('[data-test="home-confirm-done"]', { timeout: 60_000 }).then(() => "confirmed"),
        tab.waitForSelector('[data-test="home-confirm-error"]', { timeout: 60_000 }).then(async () =>
          `refused: ${(await tab.locator('[data-test="home-confirm-error"]').innerText()).trim()}`),
      ]).catch(() => null);
      if (measured) measured.back = await measure(tab);
    }
    return {
      home_origin: new URL(href).origin, carried_in_fragment: href.includes("/carry#confirm="), preview,
      at_home_prompt: (atHome || "").replace(/\s+/g, " ").slice(0, 300), assertion, done,
      fragment_cleared: hold ? null : !new URL(tab.url()).hash,
    };
  } finally {
    await tab.close();
  }
}

// A home assertion presented at H's /confirm in a tab of the person's own
// browser, as their CYFR sends one: what the page said.
export async function presentAssertion(page, assertion) {
  const tab = await page.context().newPage();
  try {
    await tab.goto(`${H}/confirm#home_assertion=${assertion}`);
    return await Promise.race([
      tab.waitForSelector('[data-test="home-confirm-done"]', { timeout: 60_000 }).then(() => "confirmed"),
      tab.waitForSelector('[data-test="home-confirm-error"]', { timeout: 60_000 }).then(async () =>
        `refused: ${(await tab.locator('[data-test="home-confirm-error"]').innerText()).trim()}`),
    ]).catch(() => "neither");
  } finally {
    await tab.close();
  }
}

// The request the hub page shows for another of the person's clients:
// its ref, once one appears.
async function otherRequest(page, url) {
  await open(page, url, { close: false });
  const other = `${layer} [data-test="confirmation"][data-own="false"]`;
  return waitFor(async () => {
    for (const el of await page.$$(other)) {
      const ref = await el.getAttribute("data-ref");
      if (ref) return { ref, preview: (await el.innerText()).replace(/\s+/g, " ").slice(0, 400) };
    }
    return null;
  }, { timeoutMs: 60_000, what: "the command line's request in the hub page's Prism" });
}

// The `phone` row: the command line paired at H asks a change there
// (another device's addition) and waits; the person's browser at H shows
// that request from H's record and confirms it through their own CYFR, A,
// by a home assertion; the command line's request completes, H records the
// proof as `home`, and the same assertion presented again confirms nothing.
export async function crossDevice(proxy, state) {
  const { hubPage, hubAthanor, identifier } = state;
  const rec = {};
  let t = null;
  try {
    t = terminal(["login", "--url", H], state.terminal.cliHome, proxy);
    await t.until(/Unlock this command line with its passphrase: /);
    t.type(state.terminal.passH);
    await t.until(UNLOCKED, 0, 90_000);
    const digest = createHash("sha256").update(randomBytes(32)).digest("base64url");
    let mark = t.out.length;
    t.type(`cyfr pair ${digest} --url ${H}; echo "pair=$?"`);
    await t.until(CONFIRM_HERE, mark, 90_000);
    const shown = await otherRequest(hubPage, shellAt(H, hubAthanor));
    const confirmed = await confirmAtHome(hubPage, shown.ref, A);
    // Confirmed elsewhere: Enter repeats the command line's request, which
    // only it can, and it completes.
    t.type("");
    const paired = await t.until(/pair=(\d+)/, mark, 90_000);
    const done = t.out.slice(mark);
    const confirmations = (await ask({ op: "confirmations", cell: "h", identifier })).confirmations;
    const replayed = confirmed.assertion ? await presentAssertion(hubPage, confirmed.assertion) : null;
    rec.request = shown.preview;
    rec.confirmed = { ...confirmed, assertion: !!confirmed.assertion };
    rec.terminal = { pair_exit: Number(paired[1]), link_printed: done.includes(`${H}/pair#code=`) };
    rec.home_proofs = confirmations.filter((c) => c.operation === "pairing.begin" && c.proof === "home").length;
    rec.replayed = replayed;
    rec.exit = await t.end();
    record.phone = rec;
    return row("phone", "chromium",
      /pairing\.begin/.test(shown.preview) && confirmed.home_origin === A && confirmed.carried_in_fragment &&
        /pairing\.begin/.test(confirmed.preview) && confirmed.done === "confirmed" && confirmed.fragment_cleared &&
        rec.terminal.pair_exit === 0 && rec.terminal.link_printed && rec.home_proofs >= 1 &&
        /^refused/.test(replayed || "") && rec.exit === 0,
      "a change the command line at H asks for is shown in the person's browser at H and confirmed at their own CYFR, A, with a fresh passkey proof there; H takes A's assertion, the command line's request completes, and the assertion presented again confirms nothing",
      rec);
  } catch (error) {
    record.phone = { ...rec, error: String(error && error.message), out: t && t.out.slice(-2000) };
    return row("phone", "chromium", false, "the cross-device confirmation ran to its end", record.phone);
  } finally {
    if (t && t.exit === null) t.kill();
  }
}

// The `renewal` row: past its first certificate's life, A's certificate
// for the command line is renewed at A when it unlocks at H again, by a
// proof of its device key, with no cookie, no browser and no confirmation,
// and the command line acts at H under the replacement.
export async function terminalRenewal(proxy, state) {
  const rec = {};
  let t = null;
  try {
    const issued = heldCertificate(state.terminal.cliHome, H);
    await sleep(Math.max(0, issued.expires_at - Date.now()) + 2_000);
    const from = proxy.seen.length;
    t = terminal(["login", "--url", H], state.terminal.cliHome, proxy);
    await t.until(/Unlock this command line with its passphrase: /);
    t.type(state.terminal.passH);
    await t.until(UNLOCKED, 0, 90_000);
    const mark = t.out.length;
    t.type(`cyfr whoami --url ${H}; echo "whoami=$?"`);
    rec.whoami_exit = Number((await t.until(/whoami=(\d+)/, mark))[1]);
    rec.exit = await t.end();
    const renewal = proxy.seen.slice(from).filter((r) => r.host === new URL(A).host && new URL(r.url).pathname === "/certify/v1/renew");
    const renewed = heldCertificate(state.terminal.cliHome, H);
    rec.posts = renewal.filter((r) => r.method === "POST").map((r) => ({ status: r.status, cookie: r.cookie, origin: r.origin, site: r.fetch && r.fetch.site }));
    rec.replaced = renewed.expires_at > issued.expires_at && renewed.issuer === A && renewed.subject.key_epoch === issued.subject.key_epoch;
    record.renewal = rec;
    return row("renewal", "chromium",
      rec.posts.length >= 2 && rec.posts.every((p) => p.status === 200 && !p.cookie && !p.origin && !p.site) &&
        rec.replaced && rec.whoami_exit === 0 && rec.exit === 0,
      "past its first certificate's life, the command line renews at A by a proof of its key, with no cookie, no browser and no confirmation, and acts at H under the replacement",
      rec);
  } catch (error) {
    record.renewal = { ...rec, error: String(error && error.message), out: t && t.out.slice(-2000) };
    return row("renewal", "chromium", false, "the command line's renewal ran to its end", record.renewal);
  } finally {
    if (t && t.exit === null) t.kill();
  }
}

// A credential entry the person's page at H asks for: its own request,
// waiting on its confirmation. Answers its ref.
async function askEntry(hubPage, hubAthanor, name) {
  await open(hubPage, `${H}/a/${encodeURIComponent(hubAthanor)}/vault`);
  if (!(await hubPage.locator("#vault-create-form").isVisible().catch(() => false))) {
    await hubPage.locator('button[phx-click="show_add"][phx-value-mode="fields"]').click();
  }
  const form = hubPage.locator("#vault-create-form");
  await form.locator('select[name="kind"]').selectOption("api_key", { timeout: 30_000 });
  await form.locator('input[name="name"]').fill(name);
  await form.locator('textarea[name="fields"]').fill(`API_KEY=${name}-not-shown`);
  await form.locator('input[name="destination_hosts"]').fill("fixture.test");
  await form.locator('button[type="submit"]').click();
  const own = `${layer} [data-test="confirmation"][data-own="true"]`;
  return (await hubPage.waitForSelector(own, { timeout: 30_000 })).getAttribute("data-ref");
}

// Before A rotates: a change the person's page at H asks for (a credential
// entry), confirmed at A, whose assertion the proof keeps and H never
// receives. Answers the request's ref and the assertion.
export async function holdAssertion(state) {
  const ref = await askEntry(state.hubPage, state.hubAthanor, "join-held-entry");
  const held = await confirmAtHome(state.hubPage, ref, A, { hold: true });
  return { ref, assertion: held.assertion, preview: held.preview };
}

// The `recertify` row, once A rotated: the assertion A made before the
// rotation, presented at H now, confirms nothing, as H checks it against
// the person's head read fresh; a request confirmed at A now goes through. The command line's certification ended with the old key: its
// renewal at A is refused, and it is certified again there in the
// terminal, A's address offered, A's own device unlocked afresh and the
// certification confirmed over A's preview, naming A's new key_epoch.
export async function recertify(proxy, state) {
  const { hubPage } = state;
  const rec = {};
  let t = null;
  try {
    const held = state.heldAssertion;
    rec.stale = held && held.assertion ? await presentAssertion(hubPage, held.assertion) : "none held";
    rec.fresh = await confirmAtHome(hubPage, await askEntry(hubPage, state.hubAthanor, "join-fresh-entry"), A);

    const head = await ask({ op: "a_head" });
    const before = heldCertificate(state.terminal.cliHome, H);
    t = terminal(["login", "--url", H], state.terminal.cliHome, proxy);
    await t.until(/Unlock this command line with its passphrase: /);
    t.type(state.terminal.passH);
    const offered = await t.until(/Your own CYFR's address \(Enter for (\S+)\): /, 0, 90_000);
    t.type("");
    await t.until(/Unlock this command line at \S+ with its passphrase: /);
    t.type(state.terminal.passA);
    await t.until(CONFIRM_HERE, 0, 90_000);
    t.type(state.terminal.passA);
    await t.until(UNLOCKED, 0, 90_000);
    rec.exit = await t.end();
    const after = heldCertificate(state.terminal.cliHome, H);
    rec.terminal = {
      offered: offered[1], certify_preview_first: /person\.certify/.test(t.out),
      key_epoch_current: after.subject.key_epoch === head.head, moved: after.subject.key_epoch !== before.subject.key_epoch,
      ended_said: /ended this command line's certification|certifies this command line/.test(t.out),
    };
    record.recertify = { ...rec, fresh: rec.fresh && { ...rec.fresh, assertion: !!rec.fresh.assertion } };
    return row("recertify", "chromium",
      /^refused/.test(rec.stale) && rec.fresh && rec.fresh.done === "confirmed" &&
        rec.terminal.offered === A && rec.terminal.certify_preview_first && rec.terminal.key_epoch_current &&
        rec.terminal.moved && rec.exit === 0,
      "after A's rotation: an assertion A made under the old key confirms nothing at H, a fresh one confirms a request; the command line's renewal is refused, and it is certified again at A in the terminal, naming A's new key_epoch",
      record.recertify);
  } catch (error) {
    record.recertify = { ...rec, error: String(error && error.message), out: t && t.out.slice(-2000) };
    return row("recertify", "chromium", false, "the re-certification ran to its end", record.recertify);
  } finally {
    if (t && t.exit === null) t.kill();
  }
}
