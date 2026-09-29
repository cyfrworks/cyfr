#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The multi-home smoke (tests/browser/README.md): two `cyfr` releases on
# SQLite cells of their own, the homes alpha.test and beta.test, started as
# the browser harness starts a home (tests/browser/harness.sh) behind its
# HTTPS front, and in every browser of the harness's matrix:
#
#   home        each home's own page answers over HTTPS under the run's
#               authority, is a secure context whose `crypto.subtle`
#               digests, joins its LiveView through the front, and is
#               framed by nothing
#   unsigned    two names the run's authority did not sign, one signed by
#               a stranger and one presenting a home's certificate, are
#               refused
#   cookies     no cookie a home sets, by its answer or by its script, and
#               none set for all of `.test`, reaches the other home
#   framed      a framed request to either home, from either, is refused
#               (403) before the session, and sets no cookie
#   fragment    the harness's fragment fixture carries 16 KiB from one home
#               to the other and back by top-level navigations, intact, and
#               never sends it
#   passkey     Chromium alone: its virtual authenticator makes and uses a
#               passkey on each home, and refuses a home's page a passkey
#               for the other
#
# Usage: tests/multi-home-smoke/run.sh
# Writes multi-home-smoke.json and multi-home-smoke.md into PROOF_OUT
# (default: the scratch directory, kept with RELEASE_BOOT_KEEP=1) and prints
# the table. Set RELEASE_BOOT_SKIP_BUILD=1 to reuse a release a previous run
# built. MULTI_HOME_SMOKE_FAULT breaks the run on purpose, to show its
# failures: `unsigned` has the stranger sign beta.test, so every browser
# refuses beta and the smoke fails; `silent` stops beta's server before the
# browsers start, so the run fails naming the cell.
set -euo pipefail

FAULT="${MULTI_HOME_SMOKE_FAULT:-}"
case "$FAULT" in
  "" | unsigned | silent) ;;
  *)
    echo "MULTI_HOME_SMOKE_FAULT is unsigned or silent, not '$FAULT'" >&2
    exit 64
    ;;
esac

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-multi-home-smoke-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
OUT="${PROOF_OUT:-$WORK/out}"

# The scratch directory holds the run's authority key, so it goes even when
# a stop fails.
cleanup() {
  server_stop || :
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

release_build

step "the run's authority, the homes alpha.test and beta.test, and two names it did not sign"
browser_authority
browser_home "$WORK/alpha" alpha.test
browser_home "$WORK/beta" beta.test
browser_unsigned stranger.test "$WORK/alpha" stranger
browser_unsigned misnamed.test "$WORK/alpha" misnamed
if [ "$FAULT" = unsigned ]; then
  step "the fault: the stranger, not the run's authority, signs beta.test"
  browser_certificate beta.test stranger
fi

step "starting alpha.test and beta.test, each on a fresh SQLite cell of its own"
server_start "$WORK/alpha"
server_start "$WORK/beta"
if [ "$FAULT" = silent ]; then
  step "the fault: beta's server stops before the browsers start"
  server_stop "$WORK/beta"
fi

# The browser side: the lib's checks, run in each browser against both homes.
read -r -d '' SMOKE <<'JS' || true
import { randomBytes } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  BROWSERS, HARNESS, crossedCookies, framedRequest, launchBrowser, readHomes, roundTripFragment,
  secureContext, startProxy, virtualAuthenticator,
} from "../browser/lib.mjs";

const [homesFile, outDir] = process.argv.slice(1);
const { homes, unsigned } = readHomes(homesFile);
const [alpha, beta] = homes;
const pairs = [[alpha, beta], [beta, alpha]];
mkdirSync(outDir, { recursive: true });

// A browser's refusal of a certificate, as each names it.
const CERTIFICATE_REFUSED = /ERR_CERT_|SEC_ERROR_|SSL_ERROR_|TLS certificate/;
const rows = [];

// An error's first line, without the fragment a navigation carried.
const firstLine = (error) => error.message.split("\n")[0].replace(/#[\w-]{32,}/g, "#…").slice(0, 400);

// One check in a page of its own, so a check that fails leaves the next
// nothing: `body(page)` answers [held, detail].
async function attempt(context, browser, check, subject, body) {
  let held = false;
  let detail;
  const page = await context.newPage();
  try {
    [held, detail] = await body(page);
  } catch (error) {
    detail = { error: firstLine(error) };
  } finally {
    await page.close();
  }
  rows.push({ browser, check, subject, held: !!held, detail });
  console.log(`${held ? "held  " : "FAILED"} ${browser} ${check} ${subject}: ${JSON.stringify(detail)}`);
}

const settle = (page, url) => page.waitForURL(url, { timeout: 30_000 });
// A top-level navigation the page makes itself, after the evaluation returns.
const navigate = (page, url) => page.evaluate((to) => setTimeout(() => location.assign(to), 0), url);

async function home(page, proxy, site) {
  const url = `${site.origin}/login`;
  const response = await page.goto(url);
  await page.waitForSelector(".phx-connected", { timeout: 30_000 });
  const facts = await secureContext(page);
  const seen = proxy.seen.findLast((r) => r.url === url && r.fetch?.dest === "document");
  const policy = seen?.answered?.policy ?? "";
  const framedByNothing = policy.includes("frame-ancestors 'none'") && seen?.answered?.frameOptions === "DENY";
  return [
    response.status() === 200 && facts.protocol === "https:" && facts.secure && facts.subtle && facts.digest &&
      framedByNothing,
    { status: response.status(), ...facts, framed_by_nothing: framedByNothing },
  ];
}

async function refused(page, site) {
  try {
    await page.goto(`${site.origin}/login`, { timeout: 20_000 });
    return [false, { loaded: page.url() }];
  } catch (error) {
    return [CERTIFICATE_REFUSED.test(firstLine(error)), { refused: firstLine(error) }];
  }
}

// In a context of its own, so every cookie it holds was set here.
async function cookies(browser, proxy) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const mark = proxy.seen.length;
  const scripted = [];
  for (const site of homes) {
    // The home's answer sets its session cookie; its script sets one for
    // itself and asks for one for the whole of `.test`.
    await page.goto(`${site.origin}/login`);
    await page.goto(`${site.origin}${HARNESS}/page`);
    const value = randomBytes(12).toString("hex");
    const name = `harness_${site.name}`;
    await page.evaluate(([n, v]) => {
      document.cookie = `${n}=${v}; Secure; SameSite=None; Path=/`;
      document.cookie = `${n}_wide=${v}; Domain=test; Secure; SameSite=None; Path=/`;
    }, [name, value]);
    scripted.push({ host: site.host, name, value }, { host: site.host, name: `${name}_wide`, value });
  }
  for (const [from, to] of pairs) {
    // From the one home's page: a request of the other, and a navigation to it.
    await page.goto(`${from.origin}${HARNESS}/page`);
    await page.evaluate(async (url) => {
      try {
        await fetch(url, { mode: "no-cors", credentials: "include" });
      } catch {
        // Refused or not, what reached the network is the proxy's account.
      }
    }, `${to.origin}${HARNESS}/page?from=${from.name}`);
    await navigate(page, `${to.origin}/login`);
    await settle(page, `${to.origin}/login`);
  }
  const since = proxy.seen.slice(mark);
  const crossed = crossedCookies(since, scripted);
  const wide = (await context.cookies()).filter((c) => c.domain.replace(/^\./, "") === "test").map((c) => c.name);
  await context.close();
  // The check means something only if each home set its session cookie
  // and had it back.
  const sessions = homes.map((site) => ({
    host: site.host,
    set: since.some((r) => r.host === site.host && (r.setCookies ?? []).some(([n]) => n === "_cyfr_key")),
    returned: since.some((r) => r.host === site.host && (r.cookies ?? []).some(([n]) => n === "_cyfr_key")),
  }));
  return [
    crossed.length === 0 && wide.length === 0 && sessions.every((s) => s.set && s.returned),
    { crossed, stored_for_all_of_test: wide, sessions },
  ];
}

async function framed(page, proxy, parent, target) {
  const seen = await framedRequest(page, proxy, parent, target, "/login", { timeoutMs: 15_000 });
  return [seen.dest === "iframe" && seen.status === 403 && seen.sets.length === 0, seen];
}

async function passkey(page, site, other) {
  const authenticator = await virtualAuthenticator(page);
  try {
    await page.goto(`${site.origin}${HARNESS}/page`);
    const outcome = await page.evaluate(async ([rpId, foreign]) => {
      const random = (n) => crypto.getRandomValues(new Uint8Array(n));
      const created = await navigator.credentials.create({
        publicKey: {
          rp: { id: rpId, name: rpId },
          user: { id: random(16), name: "harness", displayName: "harness" },
          challenge: random(32),
          pubKeyCredParams: [{ type: "public-key", alg: -7 }],
          authenticatorSelection: { residentKey: "required", userVerification: "required" },
        },
      });
      const asserted = await navigator.credentials.get({
        publicKey: {
          rpId, challenge: random(32), userVerification: "required",
          allowCredentials: [{ type: "public-key", id: created.rawId }],
        },
      });
      let foreignRefused = null;
      try {
        await navigator.credentials.create({
          publicKey: {
            rp: { id: foreign, name: foreign },
            user: { id: random(16), name: "harness", displayName: "harness" },
            challenge: random(32),
            pubKeyCredParams: [{ type: "public-key", alg: -7 }],
          },
        });
        foreignRefused = false;
      } catch (error) {
        foreignRefused = error.name;
      }
      return { created: created.type, asserted: asserted.id === created.id, foreign_refused: foreignRefused };
    }, [site.host, other.host]);
    const held = (await authenticator.credentials()).filter((c) => c.rpId === site.host).length;
    return [
      outcome.created === "public-key" && outcome.asserted && outcome.foreign_refused === "SecurityError" && held === 1,
      { ...outcome, credentials_for_rp: held },
    ];
  } finally {
    await authenticator.remove();
  }
}

let proxy;
try {
  proxy = await startProxy(null, { homes, unsigned });
} catch (error) {
  console.error(`FAIL: ${firstLine(error)}`);
  process.exit(1);
}
const versions = {};
for (const name of BROWSERS) {
  const browser = await launchBrowser(name, proxy);
  versions[name] = browser.version();
  console.log(`== ${name} ${versions[name]}`);
  try {
    const context = await browser.newContext();
    const run = (check, subject, body) => attempt(context, name, check, subject, body);
    for (const site of homes) await run("home", site.host, (page) => home(page, proxy, site));
    for (const site of unsigned) await run("unsigned", site.host, (page) => refused(page, site));
    await run("cookies", "both homes", () => cookies(browser, proxy));
    for (const [parent, target] of [...pairs, [alpha, alpha], [beta, beta]]) {
      await run("framed", `${target.host} in ${parent.host}`, (page) => framed(page, proxy, parent, target));
    }
    for (const [from, to] of pairs) {
      await run("fragment", `${from.host} to ${to.host} and back`, async (page) => {
        const trip = await roundTripFragment(page, proxy, from, to);
        return [trip.intact && !trip.leaked && trip.hops.length === 3, trip];
      });
    }
    if (name === "chromium") {
      for (const [site, other] of pairs) await run("passkey", site.host, (page) => passkey(page, site, other));
    }
    await context.close();
  } finally {
    await browser.close();
  }
}
proxy.close();

const failed = rows.filter((r) => !r.held);
writeFileSync(join(outDir, "multi-home-smoke.json"),
  JSON.stringify({ versions, homes, unsigned, rows, refusals: proxy.refusals }, null, 2));
const subjects = [...new Set(rows.map((r) => `${r.check}|${r.subject}`))];
const cell = (browser, key) => {
  const row = rows.find((r) => r.browser === browser && `${r.check}|${r.subject}` === key);
  return row ? (row.held ? "held" : "FAILED") : "not offered";
};
const table = [
  `| check | subject | ${BROWSERS.map((b) => `${b} ${versions[b]}`).join(" | ")} |`,
  `|---|---|${BROWSERS.map(() => "---|").join("")}`,
  ...subjects.map((key) => `| ${key.split("|").join(" | ")} | ${BROWSERS.map((b) => cell(b, key)).join(" | ")} |`),
];
writeFileSync(join(outDir, "multi-home-smoke.md"), table.join("\n") + "\n");
console.log(table.join("\n"));
if (failed.length) {
  console.error(`FAIL: ${failed.length} check(s) did not hold`);
  for (const r of failed) console.error(`  ${r.browser} ${r.check} ${r.subject}: ${JSON.stringify(r.detail)}`);
  process.exit(1);
}
JS

step "the multi-home smoke in $PLAYWRIGHT_IMAGE"
playwright_run multi-home-smoke --input-type=module --eval "$SMOKE" /authority/homes.json /out ||
  fail "the multi-home smoke failed: the lines above name each check, browser and cell"

echo "the record: $OUT/multi-home-smoke.json and $OUT/multi-home-smoke.md"
