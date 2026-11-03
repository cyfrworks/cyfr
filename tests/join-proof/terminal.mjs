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
import {
  A, H, ask, closePrompt, confirmHere, layer, open, outDir, pressInLayer, record, row, secrets, sleep, waitFor,
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

export async function terminalStep(proxy, { home, hubPage, hubAthanor, identifier }) {
  const cliHome = mkdtempSync(join(tmpdir(), "cyfr-join-terminal-"));
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
    rmSync(cliHome, { recursive: true, force: true });
  }
}
