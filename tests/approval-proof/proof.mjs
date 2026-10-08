// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The approval proof, run in the official Playwright image by run.sh
// against a `cyfr` release behind the harness's HTTPS front (README.md).
// One person, in Chromium, grants the tincture approval-probe on the
// Components page, in the system layer's grant prompt. Each step is one
// row of the record; the proof fails when a row does not hold, and stops
// at the first row a later one rests on.
//
//   provided_preview    the first grant shows the Grok dependency's key as
//                       the publisher's configuration and its destination,
//                       and asks nothing for it; committed, the loader
//                       admits the root and the loaded edge carries
//                       exactly the provided configuration, used only
//                       within its destination
//   account_choices     two OpenAI entries, one made through "Connect your
//                       openai.com account" and one on the Vault page, and
//                       one Anthropic entry; the app's own calls take the
//                       first and the OpenAI dependency's edge the second,
//                       the one Anthropic entry chosen with no picker
//   commit_bindings     the same bindings re-granted with their own
//                       lifetimes, standing, once and five minutes, and the
//                       OpenAI dependency narrowed to GET only
//   lifetime_decisions  the use path admits the once binding for one root
//                       and refuses another, admits the five-minute binding
//                       and, after a real wait past its instant, refuses
//                       it; the loaded edge grants GET alone
//   named_prompt        the grant prompt a launch naming an unbound account
//                       opens, raised by the event a turn would announce,
//                       with no turn: the account is bound and the new
//                       revision holds it
//   revocation          the entry the app's own calls use is revoked on the
//                       Vault page, and its next use is refused
//
// The home's part of a step — installing the tincture, a read of what was
// committed, an admission, a use decision, the announcement — is run.sh's,
// asked for through OUT_DIR (`ask-N.json`, answered `answer-N.json`) and
// done by fixture.exs, which returns bounded facts and never material. No
// request is sent anywhere and no execution or turn exists.
//
// Usage: node proof.mjs HOMES_FILE SEGMENT COOKIE OUT_DIR VIEWPORT

import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { launchBrowser, readHomes, sleep, startProxy, virtualAuthenticator, waitFor } from "../browser/lib.mjs";
// The grant proof's redaction, read where the harness mounts the tree.
import { MARKER, pageTokens, recordText, redact, redactFrames } from "/tests/grant-proof/redact.mjs";

const [homesFile, segment, cookie, outDir, viewportName] = process.argv.slice(2);
if (!homesFile || !segment || !cookie || !outDir || !viewportName) {
  console.error("usage: node proof.mjs HOMES_FILE SEGMENT COOKIE OUT_DIR VIEWPORT");
  process.exit(64);
}

// VAULT_PROOF_VIEWPORT, as run.sh validated it.
const VIEWPORTS = { desktop: { width: 1280, height: 900 }, "720x720": { width: 720, height: 720 } };
const viewport = VIEWPORTS[viewportName];
if (!viewport) {
  console.error("the viewport is desktop or 720x720");
  process.exit(64);
}
mkdirSync(outDir, { recursive: true });

const STEPS = [
  "provided_preview", "account_choices", "commit_bindings", "lifetime_decisions", "named_prompt", "revocation",
];
const { homes } = readHomes(homesFile);
const base = homes[0].origin;
const layer = "#system-layer-dialog";
const rows = [];
const record = { viewport: { name: viewportName, ...viewport } };

// ---------------------------------------------------------------------------
// The tincture and the person's entries
// ---------------------------------------------------------------------------

const NAME = "approval-probe";
const APP = `tincture:local.${NAME}`;
const OPENAI = "catalyst:local.openai";
const CLAUDE = "catalyst:local.claude";
const GROK = "catalyst:local.grok";
const BEARER = { in: "header", name: "Authorization", template: "Bearer {value}" };

// What the publisher provides the Grok catalyst's one need: a destination
// and a public value, attached by Grok's own rule.
const PROVIDED = {
  destination: { hosts: ["api.x.ai"], methods: ["GET", "POST"], paths: ["/v1/"] },
  values: { GROK_API_KEY: "xai-approval-probe-public-value" },
};

// The tincture run.sh installs: one attached need of its own, on the same
// provider as the shipped OpenAI catalyst's, and the shipped OpenAI, Claude
// and Grok catalysts as dependencies, Grok's need provided.
const MANIFEST = {
  name: NAME,
  type: "tincture",
  version: "1.0.0",
  publisher: "local",
  description: "The approval proof's tincture: its own OpenAI need, and three catalysts, one provided.",
  needs: {
    openai: {
      type: "api_key:openai.com",
      reason: "to call the OpenAI API for the probe's own requests",
      required: true,
      fields: ["OPENAI_API_KEY"],
      attach: BEARER,
      hosts: ["api.openai.com"],
    },
  },
  dependencies: {
    static: [
      { ref: OPENAI, reason: "the probe's chat model" },
      { ref: CLAUDE, reason: "the probe's second model" },
      { ref: GROK, reason: "the probe's third model, on the publisher's own key" },
    ],
  },
  provides: { [GROK]: { api_key: PROVIDED } },
  // The host its own need names lies inside its own network ask, as the
  // registry requires.
  caps: { egress: { domains: ["api.openai.com"], methods: ["GET", "POST"] } },
  tincture: { entry: "index.html" },
};
const INDEX = "<!doctype html>\n<html><head><title>approval-probe</title></head><body>approval-probe</body></html>\n";

// The person's entries. Each key is this run's own, typed in the browser
// and nowhere else; no page, answer or record may hold one.
const hex = () => randomBytes(12).toString("hex");
const WORK = {
  name: "OpenAI Work", provider: "openai.com", field: "OPENAI_API_KEY", host: "api.openai.com", key: `sk-work-${hex()}`,
};
const HOME = {
  name: "OpenAI Home", provider: "openai.com", field: "OPENAI_API_KEY", host: "api.openai.com", key: `sk-home-${hex()}`,
};
const ANTHROPIC = {
  name: "Anthropic", provider: "anthropic.com", field: "ANTHROPIC_API_KEY", host: "api.anthropic.com",
  key: `sk-ant-${hex()}`,
};
const ENTRIES = [WORK, HOME, ANTHROPIC];
const KEYS = ENTRIES.map((e) => e.key);
// The account a launch names that the app's own calls do not bind yet.
const ACCOUNT = "Personal";

// Each binding's key, `<source node>|<edge key>|<slot>`: the app's own
// calls on its ingress, a dependency's edge by the dependency's reference.
const KEY = {
  own: `${APP}|@ingress|default`,
  personal: `${APP}|@ingress|name:${ACCOUNT}`,
  openai: `${APP}|${OPENAI}|default`,
  claude: `${APP}|${CLAUDE}|default`,
  grok: `${APP}|${GROK}|default`,
};

// The OpenAI catalyst's network row narrowed to GET only, as the sheet
// shows it: its host given, GET given and POST not, the row narrowed, and
// the control pressed and named by the method it keeps.
const GET_ONLY_SHOWN = {
  node: OPENAI,
  narrowed: true,
  domains: [{ value: "api.openai.com", granted: true }],
  methods: [{ value: "GET", granted: true }, { value: "POST", granted: false }],
  narrowing: { label: "GET only", pressed: true },
};

// The OpenAI catalyst's network grant as its loaded edge holds it: the
// host it asks, over the https its ask names by default, no private
// range, and GET alone of the GET and POST it asks.
const GET_ONLY_GRANT = { domains: ["api.openai.com"], methods: ["GET"], schemes: ["https"], private_ips: [] };

// Root execution ids the proof names for the use decisions. No
// execution exists for either.
const ROOT_A = `exec_approval-proof-a-${hex()}`;
const ROOT_B = `exec_approval-proof-b-${hex()}`;
const ROOT_C = `exec_approval-proof-c-${hex()}`;

const sha256 = (text) => createHash("sha256").update(text).digest("hex");
// The digest of the payload document an entry holds for what the person
// typed, as its owner encodes one (`Sanctum.Vault.Payload`: version 3, the
// one field), in its canonical text; the fixture compares the stored
// payload with it. Neither it nor a digest of a key may reach a page, an
// answer or the record.
const typedDigest = (spec) => sha256(JSON.stringify(canonical({ v: 3, fields: { [spec.field]: spec.key } })));

// ---------------------------------------------------------------------------
// Whole objects
// ---------------------------------------------------------------------------
//
// A claim about something the home committed compares the whole committed
// object with the whole object the proof expects, as one equality, after
// the same canonical ordering on both sides: object members by name. A list
// keeps its order on both sides, so an item in another place fails, except
// where its owner defines it as a set: those lists, and only those, are
// named in SETS with the reason, and their items are ordered by their own
// canonical text on both sides.

// The lists compared as sets, by their path from the compared object's
// root, each with the owner that makes it one.
const SETS = {
  "state.entries": "a table's rows: `fixture.exs` `state` reads `vault_entries` with no order, and SQL answers a " +
    "table's rows in none",
  "state.defaults": "a table's rows: `vault_defaults`, read with no order",
  "state.profiles": "a table's rows: `profiles`, read with no order",
  "state.consents": "a table's rows: `consents`, read with no order",
  "state.refs": "a table's rows: `consent_vault_refs`, read with no order",
  "state.turns": "a table's rows: `turns`, read with no order",
  "state.executions": "a table's rows: `executions`, read with no order",
};

function canonical(value, path = "") {
  if (Array.isArray(value)) {
    const items = value.map((item) => canonical(item, `${path}[]`));
    if (!Object.hasOwn(SETS, path)) return items;
    return items.map((item) => [JSON.stringify(item), item])
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([, item]) => item);
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort()
      .map((key) => [key, canonical(value[key], path === "" ? key : `${path}.${key}`)]));
  }
  return value;
}

// `root` names what is compared, for SETS: "state" for the named state.
const same = (stored, expected, root = "") =>
  JSON.stringify(canonical(stored, root)) === JSON.stringify(canonical(expected, root));
const compared = (stored, expected, root = "") =>
  ({ stored: canonical(stored, root), expected: canonical(expected, root) });

// The destination the person sent for an entry: the host the form held
// when it was sent, over https, nothing else typed.
const sentDestination = (hosts) => ({ hosts: hosts.split(/[\s,]+/).filter(Boolean).map((h) => h.toLowerCase()), scheme: "https" });

// ---------------------------------------------------------------------------
// Every field, classified
// ---------------------------------------------------------------------------
//
// No field of the named state is left out of the comparison. Each is in one
// of three classes, declared in the one table below, which the README
// mirrors:
//
//   exact    compared exactly with the model;
//   derived  compared with a value derived independently of the row, which
//            the model holds: what an entry's request implies the owner
//            stores (`requested`), what a commit of the person's decisions
//            writes (`derived`), the payload she typed, or the until the
//            preview showed her;
//   bound    a clock or server-minted value, held to the bound the table
//            states.
//
// Before the one comparison every field goes through its class: an exact
// or derived field stays as stored, unless its class reads it (the payload,
// an until), and a bound field becomes what the model holds when the bound
// holds. A field the table does not name becomes `{unclassified: true}` and
// a named field a row lacks `{missing: true}`; the model never holds
// either, so either fails the step, and the step's record names the field.
// Turns and executions are none at every step, so a row of either fails
// whole and their columns need no class.

const IN_WINDOW = "inside the run's window";

// Microseconds since the epoch of a UTC time as the home writes it
// (`2026-10-06T10:00:00.123456Z`, the fraction optional), or null.
function micros(text) {
  const m = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,6}))?Z$/.exec(String(text));
  if (!m) return null;
  const seconds = Date.parse(`${m[1]}Z`);
  return Number.isNaN(seconds) ? null : BigInt(seconds) * 1000n + BigInt((m[2] || "").padEnd(6, "0"));
}

// Whether `value` lies in the run's window: from the database's time at the
// run's start to its time at the end of the read that returned it.
function inWindow(value, read) {
  const [at, from, to] = [micros(value), micros(read.start), micros(read.now)];
  return at !== null && from !== null && to !== null && from <= at && at <= to;
}

// An instant as one comparable text, whatever fraction it is spelled with.
const instant = (text) => {
  const at = micros(text);
  return at === null ? { unreadable_instant: text } : `instant ${at}`;
};

const exact = { class: "exact" };
const derived = (from) => ({ class: "derived", from });
// A server-minted id: the model holds the id its source showed, so it
// stays as stored and the comparison holds it to that one.
const minted = (source) => ({ class: "bound", bound: `equal to the id ${source}`, check: (value) => value });
// A time the clock sets: none where the model holds none, else inside the
// run's window.
const clock = {
  class: "bound",
  bound: "none where the model holds none; otherwise inside the run's window, from the database's time at " +
    "the run's start to its time at the end of the read",
  check: (value, read) => (value === null ? null : inWindow(value, read) ? IN_WINDOW : { outside_window: value }),
};
// A default's own id names nothing a person acts on: the default is found
// by its athanor and provider.
const DEFAULT_ID = "a default's own id";
const defaultId = {
  class: "bound",
  bound: "a server-minted id of the `vdf_` form; it names nothing a person acts on, since a default is found by " +
    "its athanor and provider",
  check: (value) => (/^vdf_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(String(value))
    ? DEFAULT_ID : { not_a_default_id: value }),
};
// An until binding's instant: the one the preview row showed the person,
// which the step that chose it holds to the moment she chose it.
const shownUntil = {
  class: "derived",
  from: "the until the preview row showed her when she chose five minutes",
  check: (value) => (value === null ? null : instant(value)),
};
// The sealed payload, compared inside the fixture: the proof passes the
// digest of the payload document the person typed, the fixture unseals the
// stored payload as its owner does and answers only the outcome, so neither
// the material nor anything derived from it reaches the proof. Each outcome
// but a match is its own sentence.
const TYPED = "the value she typed";
const PAYLOAD_OUTCOMES = {
  matches: TYPED,
  differs: "the stored payload unseals to another value than she typed",
  does_not_unseal: "the stored payload does not unseal",
  absent: "no payload is stored where she typed one",
};
const typedPayload = {
  class: "derived",
  from: "the digest of the payload document she typed, compared inside the fixture",
  check: (value) => PAYLOAD_OUTCOMES[value] || { unexpected_payload_answer: typeof value },
};

const VAULT_PAGE = "the Vault page lists for it";
const SIGN_IN = "her sign-in named";
const ADMISSION = "the loader's admission named after the commit that wrote it";
const REQUESTED = "requested, from what she sent for the entry";
const DERIVED = "derived, built by the owner's builders from the installed components and her decisions";

const FIELDS = {
  vault_entries: {
    id: minted(VAULT_PAGE),
    athanor_id: minted(SIGN_IN),
    name: exact,
    provider_hint: exact,
    kind: exact,
    provenance: exact,
    field_names: exact,
    binding_digest: derived(REQUESTED),
    oauth_endpoints: exact,
    oauth_scopes: exact,
    destination: derived(REQUESTED),
    attach_only: exact,
    status: exact,
    payload_rev: exact,
    sealed_payload: typedPayload,
    last_used_at: clock,
    inserted_at: clock,
    updated_at: clock,
  },
  vault_defaults: {
    id: defaultId,
    athanor_id: minted(SIGN_IN),
    provider_hint: exact,
    vault_entry_id: minted(VAULT_PAGE),
    instance_entry_id: exact,
    inserted_at: clock,
    updated_at: clock,
  },
  profiles: {
    id: minted(ADMISSION),
    athanor_id: minted(SIGN_IN),
    source_ref: exact,
    kind: exact,
    label: exact,
    status: exact,
    head_consent_id: minted(ADMISSION),
    inserted_at: clock,
    updated_at: clock,
  },
  consents: {
    id: minted(ADMISSION),
    athanor_id: minted(SIGN_IN),
    profile_id: minted(ADMISSION),
    revision: exact,
    scope: exact,
    pinned_version: exact,
    invoke_mode: exact,
    shape_digest: derived(DERIVED),
    commit_digest: derived(DERIVED),
    blob_digest: derived(DERIVED),
    resolved_policy: derived(DERIVED),
    activation: derived(DERIVED),
    granted_by: minted(SIGN_IN),
    granted_via: exact,
    granted_at: clock,
    supersedes_id: exact,
    admitted_origins: exact,
  },
  consent_vault_refs: {
    consent_id: minted(ADMISSION),
    athanor_id: minted(SIGN_IN),
    binding_key: exact,
    scope: exact,
    vault_entry_id: minted(VAULT_PAGE),
    instance_entry_id: exact,
    via_label: exact,
    binding_digest: derived(REQUESTED),
    lifetime_kind: exact,
    expires_at: shownUntil,
    consumed_by_root: exact,
  },
};

// One stored row of `table`, each field through its class; `problems`
// collects each unclassified or missing field.
function classified(table, row, read, problems) {
  if (!row || typeof row !== "object") return row;
  const fields = FIELDS[table];
  const out = {};
  for (const [name, value] of Object.entries(row)) {
    const spec = Object.hasOwn(fields, name) ? fields[name] : null;
    if (!spec) problems.push(`${table}.${name}: unclassified`);
    out[name] = !spec ? { unclassified: true } : spec.check ? spec.check(value, read) : value;
  }
  for (const name of Object.keys(fields)) {
    if (!Object.hasOwn(row, name)) {
      problems.push(`${table}.${name}: missing`);
      out[name] = { missing: true };
    }
  }
  return out;
}

// Everything the README names, as the home holds it (`fixture.exs`
// `state`), every field through its class, shaped for the one comparison.
function storedState(state, read, problems) {
  const each = (table, list) => (Array.isArray(list) ? list.map((r) => classified(table, r, read, problems)) : list);
  const s = state || {};
  return {
    entries: each("vault_entries", s.entries),
    defaults: each("vault_defaults", s.defaults),
    profiles: each("profiles", s.profiles),
    consents: each("consents", s.consents),
    refs: each("consent_vault_refs", s.refs),
    turns: s.turns,
    executions: s.executions,
  };
}

// ---------------------------------------------------------------------------
// Asking the home
// ---------------------------------------------------------------------------

function row(step, held, what, detail) {
  rows.push({ step, held: !!held, what, detail });
  console.log(outputText(`${held ? "held  " : "FAILED"} ${step}: ${what} — ${JSON.stringify(detail)}`).slice(0, 2000));
  return !!held;
}

const answers = [];
let asked = 0;
async function ask(request, timeoutMs = 240_000) {
  const id = ++asked;
  const answer = join(outDir, `answer-${id}.json`);
  writeFileSync(join(outDir, `ask-${id}.part`), JSON.stringify(request));
  renameSync(join(outDir, `ask-${id}.part`), join(outDir, `ask-${id}.json`));
  const deadline = Date.now() + timeoutMs;
  while (!existsSync(answer)) {
    if (Date.now() > deadline) throw new Error(`run.sh never answered ${request.op}`);
    await sleep(100);
  }
  const text = readFileSync(answer, "utf8");
  answers.push(text);
  return JSON.parse(text);
}

const MATERIAL = () => [...KEYS, ...KEYS.map(sha256), ...ENTRIES.map(typedDigest)];
const holdsKey = (text) => MATERIAL().some((secret) => String(text).includes(secret));
// Every textual writer uses the same known values. Comparisons and material
// detection keep the original values in memory; redaction only changes output.
const knownPageTokens = new Set();
const outputSecrets = () => [cookie, ...MATERIAL(), ...knownPageTokens];
const outputText = (text) => redact(text, outputSecrets());
const pagePath = (suffix) => `${base}/a/${encodeURIComponent(segment)}${suffix}`;

// ---------------------------------------------------------------------------
// The browser
// ---------------------------------------------------------------------------

async function signedIn(browser) {
  const context = await browser.newContext({ viewport });
  await context.addCookies([{
    name: "_cyfr_key", value: cookie, url: base, httpOnly: true, secure: true, sameSite: "Lax",
  }]);
  return context;
}

async function open(page, url) {
  await page.goto(url);
  await page.waitForSelector(".phx-connected", { timeout: 30_000 });
}

// Words the page shows, a flash among them.
const told = (page, words, timeout = 30_000) =>
  page.getByText(words, { exact: false }).first().waitFor({ timeout }).then(() => true).catch(() => false);

// The page's own confirm for a control marked data-confirm (app.js
// `showConfirmDialog`), agreed to.
async function agree(page) {
  const confirm = page.locator("div.fixed.inset-0 button", { hasText: /^Confirm$/ });
  await confirm.waitFor({ timeout: 30_000 });
  await confirm.click();
}

// The person's first passkey, made by the virtual authenticator and
// registered from the Settings page through the system layer's ceremony,
// within the first-method window of the sign-in: every entry she makes is
// a sensitive change she confirms with it.
async function registerPasskey(page) {
  const authenticator = await virtualAuthenticator(page);
  await open(page, pagePath("/settings"));
  await page.locator('[data-test="passkey-register"]').click({ timeout: 30_000 });
  const active = await page.waitForSelector('[data-test="passkey"][data-state="active"]', { timeout: 30_000 })
    .then(() => true).catch(() => false);
  const held = (await authenticator.credentials()).length;
  return { active, held };
}

// The grant prompt for the tincture, opened from its Components row.
async function openGrant(page) {
  await open(page, pagePath("/components"));
  await page.locator(`[phx-click="toggle_expand"][phx-value-ref="${APP}"]`).first().click({ timeout: 30_000 });
  await page.locator('[phx-click="open_consent"]').click({ timeout: 30_000 });
  await granting(page);
}

// The grant prompt shown, its preview read.
async function granting(page) {
  await page.waitForSelector(`${layer}[open] [data-kind="grant"] [data-test="grant-rows"]`, { timeout: 60_000 });
  await page.waitForSelector(`${layer} [data-test="prompt-confirm"]:not([disabled])`, { timeout: 60_000 });
}

// What the open prompt shows, every part the proof reads: its kind and
// title; each need of the app and of each dependency, with its provided
// configuration, the entries offered and the one pressed, the controls it
// offers, and its accounts; each previewed credential row with its
// binding, its sentence and its lifetime; each network row's methods and
// the "GET only" control; what the grant removes and admits; and any
// refusal shown.
function sheet(page) {
  return page.evaluate((dialog) => {
    const root = document.querySelector(dialog);
    const text = (el) => (el ? el.textContent.replace(/\s+/g, " ").trim() : null);
    const pressed = (el) => el.getAttribute("aria-pressed") === "true";
    const pick = (b) => ({
      text: text(b), entry_id: b.getAttribute("phx-value-entry_id"), pressed: pressed(b),
    });
    const lifetimes = (scope) => [...scope.querySelectorAll("button[data-lifetime]")]
      .map((b) => ({ value: b.getAttribute("data-lifetime"), pressed: pressed(b) }));
    const need = (el) => ({
      need: el.getAttribute("data-need"),
      provided: text(el.querySelector(':scope > [data-test="grant-provided"]')),
      picks: [...el.querySelectorAll(':scope > .consent-sheet__choices [data-test="grant-pick"]')].map(pick),
      change: !!el.querySelector(':scope > .consent-sheet__choices [data-test="grant-change"]'),
      connect: !!el.querySelector(':scope > [data-test="grant-connect"]'),
      add_account: !!el.querySelector(':scope > [data-test="grant-add-account"]'),
      pending: el.querySelector(':scope > [data-test="grant-lifetime-pending"]')
        ? { text: text(el.querySelector(':scope > [data-test="grant-lifetime-pending"] span')),
          lifetimes: lifetimes(el.querySelector(':scope > [data-test="grant-lifetime-pending"]')) }
        : null,
      accounts: [...el.querySelectorAll(':scope > [data-test="grant-account"]')].map((a) => ({
        account: a.getAttribute("data-account"),
        fixed: !!a.querySelector('span[data-test="grant-account-name"]'),
        picks: [...a.querySelectorAll('[data-test="grant-account-pick"]')].map(pick),
        lifetimes: lifetimes(a.querySelector('[data-test="grant-account-lifetime"]') || a),
      })),
    });
    if (!root || !root.open) return { open: false };
    const kind = root.querySelector("[data-kind]");
    const needs = root.querySelector('[data-test="grant-needs"]');
    const credentials = [...root.querySelectorAll('[data-row="credential"]')].map((r) => {
      const lines = [...r.children].map(text);
      const binding = (lines.find((l) => l && l.startsWith("Binding: ")) || "").slice("Binding: ".length);
      const lifetime = (lines.find((l) => l && l.startsWith("Lifetime: ")) || "").slice("Lifetime: ".length);
      const controls = r.querySelector('[data-test="grant-lifetime"]');
      return {
        node: r.getAttribute("data-node"),
        binding,
        sentence: text(r.querySelector(".consent-sheet__sentence")),
        lifetime,
        lifetimes: controls ? lifetimes(controls) : [],
        renew: r.querySelector('[data-test="grant-renew"]')
          ? pressed(r.querySelector('[data-test="grant-renew"]')) : null,
      };
    });
    // A network row lists every value asked, each with whether the grant
    // gives it: its box ticked, or, where the row offers no control, as
    // listed.
    const egress = [...root.querySelectorAll('[data-row="egress"]')].map((r) => {
      const values = (field) => [...r.querySelectorAll(`[data-field="${field}"] label.consent-sheet__value`)]
        .map((l) => {
          const box = l.querySelector('input[type="checkbox"]');
          return { value: text(l.querySelector("span.font-mono")), granted: box ? box.checked : true };
        });
      const only = r.querySelector('[data-test="grant-get-head-only"]');
      return {
        node: r.getAttribute("data-node"),
        narrowed: /narrowed by you/.test(text(r.querySelector("span.text-xs")) || ""),
        domains: values("domains"),
        methods: values("methods"),
        narrowing: only ? { label: text(only), pressed: pressed(only) } : null,
      };
    });
    return {
      open: true,
      kind: kind && kind.getAttribute("data-kind"),
      title: text(root.querySelector("h2")),
      own: needs ? [...needs.querySelectorAll(':scope > [data-test="grant-need"]')].map(need) : [],
      deps: needs ? [...needs.querySelectorAll(":scope > div[data-dep]")].map((d) => ({
        dep: d.getAttribute("data-dep"), from: d.getAttribute("data-from"),
        needs: [...d.querySelectorAll(':scope > [data-test="grant-need"]')].map(need),
      })) : [],
      credentials,
      egress,
      removed: [...root.querySelectorAll('[data-test="grant-removed"] [data-binding]')]
        .map((r) => r.getAttribute("data-binding")),
      admits: text(root.querySelector('[data-test="grant-admits"]')),
      delta: text(root.querySelector('[data-test="grant-delta"]')),
      refusals: [...root.querySelectorAll('[data-test="grant-refusal"], [role="alert"]')].map(text).filter(Boolean),
      confirmable: !!root.querySelector('[data-test="prompt-confirm"]:not([disabled])'),
    };
  }, layer);
}

// The sheet once `check` holds of it, read again until it does.
const settled = (page, check, what, timeoutMs = 30_000) =>
  waitFor(async () => {
    const shown = await sheet(page);
    return shown.open && check(shown) ? shown : null;
  }, { timeoutMs, stepMs: 100, what });

const ownNeed = (shown, name) => (shown.own || []).find((n) => n.need === name);
const depNeed = (shown, dep) => {
  const row = (shown.deps || []).find((d) => d.dep === dep && d.from === APP);
  return row && row.needs.length === 1 ? row.needs[0] : null;
};
const credential = (shown, key) => (shown.credentials || []).find((c) => c.binding === key);
// Every previewed credential row's lifetime, by the binding the row shows,
// and how many rows there are: a lifetime is compared on its own row's
// key, never by its place among the rows.
const lifetimesOf = (shown) => ({
  rows: (shown.credentials || []).length,
  by_binding: Object.fromEntries((shown.credentials || []).map((c) => [c.binding, c.lifetime])),
});
// The lifetimes the proof expects, by binding.
const lifetimesExpected = (byBinding) => ({ rows: Object.keys(byBinding).length, by_binding: byBinding });
const STANDING = "until revoked";
const egressOf = (shown, node) => (shown.egress || []).find((e) => e.node === node);
// The entries shown for a need: each one's name and whether it is pressed.
const shownPicks = (block) => (block ? block.picks.map((p) => ({ name: nameOf(p.text), pressed: p.pressed })) : null);
const nameOf = (label) => ENTRIES.map((e) => e.name).find((n) => String(label).startsWith(n)) || label;

// The need block's selector in the open prompt: the app's own need, or a
// dependency's one need.
const ownSelector = (name) => `${layer} [data-test="grant-needs"] > [data-test="grant-need"][data-need="${name}"]`;
const depSelector = (dep) =>
  `${layer} [data-test="grant-needs"] > div[data-dep="${dep}"][data-from="${APP}"] > [data-test="grant-need"]`;
// The previewed credential row of the binding `key`, by the key it shows.
const credentialRow = (page, key) =>
  page.locator(`${layer} [data-row="credential"]`).filter({ has: page.getByText(`Binding: ${key}`, { exact: true }) });

// "Connect your <provider> account" on the need `block`: the
// credential-entry prompt in front of the grant, its name and key typed,
// the entry it saves confirmed with the passkey, then the grant back.
// Whether the page may show secret material the proof typed into it. The
// proof types a key in two places alone: the credential prompt's value
// field (`#system-layer-secret`, which "Connect your <provider> account"
// opens), for OpenAI Work and Anthropic, and the Vault page create form's
// fields (`textarea[name="fields"]`, `FIELD=value`), for OpenAI Home. It is
// set before each key is filled in, and cleared only once the page is read
// to hold the key nowhere: in no field's value and in none of its text.
let secretOnPage = false;

// Whether the page holds any typed key anywhere it could show it: a field's value or
// the page's text. A page that cannot be read is taken to hold it.
const pageHolds = (page) => page.evaluate((keys) => keys.some((k) =>
  [...document.querySelectorAll("input, textarea")].some((el) => String(el.value || "").includes(k)) ||
    document.body.innerText.includes(k)), KEYS).catch(() => true);

// The key read gone from the page, bounded; the flag is cleared only then.
async function typedAway(page) {
  const gone = await waitFor(async () => !(await pageHolds(page)),
    { timeoutMs: 30_000, stepMs: 200, what: "every typed key gone from the page" }).then(() => true).catch(() => false);
  if (gone) secretOnPage = false;
  return gone;
}

// Keep complete confirmation text for material detection. A raw length bound
// can cut a known value into an unrecognizable fragment before redaction.
async function connect(page, block, spec) {
  await page.locator(`${block} [data-test="grant-connect"]`).click({ timeout: 30_000 });
  const form = `${layer}[open] [data-kind="credential_entry"] form#system-layer-credential`;
  await page.waitForSelector(form, { timeout: 30_000 });
  const title = await page.locator(`${layer} h2`).innerText();
  const prefilled = {
    name: await page.locator("#system-layer-entry-name").inputValue(),
    hosts: await page.locator("#system-layer-destination-hosts").inputValue(),
  };
  await page.locator("#system-layer-entry-name").fill(spec.name);
  secretOnPage = true;
  await page.locator("#system-layer-secret").fill(spec.key);
  const sent = { hosts: await page.locator("#system-layer-destination-hosts").inputValue() };
  await page.locator(`${layer} [data-test="credential-submit"]`).click();
  const panel = `${layer} [data-test="confirmation"][data-own="true"]`;
  const confirmation = await page.waitForSelector(panel, { timeout: 30_000 })
    .then((el) => el.innerText()).catch(() => "");
  await page.locator(`${panel} [data-test="confirm-passkey"]`).click({ timeout: 30_000 });
  await granting(page);
  const cleared = await typedAway(page);
  return { title, prefilled, sent, cleared, confirmation: confirmation.replace(/\s+/g, " ") };
}

// Each entry's id by its name, as the Vault page lists them: a row of its
// entries' table shows the name and, beneath it, the id.
async function vaultIds(page) {
  await open(page, pagePath("/vault"));
  await page.waitForSelector("table tbody tr div.font-mono", { timeout: 30_000 });
  const listed = await page.$$eval("table tbody tr", (trs) => trs.map((tr) => [
    (tr.querySelector("td span.font-medium") || { textContent: "" }).textContent.trim(),
    (tr.querySelector("td div.font-mono") || { textContent: "" }).textContent.trim(),
  ]).filter(([name, id]) => name && /^vlt_/.test(id)));
  return Object.fromEntries(listed);
}

// An entry made on the Vault page's form: its name, the provider choice
// that names the need it meets, its one field as FIELD=value and its host,
// the save confirmed with the passkey.
async function createOnVault(page, spec) {
  await open(page, pagePath("/vault"));
  await page.locator('button[phx-click="show_add"][phx-value-mode="fields"]').click({ timeout: 30_000 });
  const form = page.locator("#vault-create-form");
  await form.waitFor({ timeout: 30_000 });
  // The form's one provider choice, each need of the athanor's components
  // labelled "<provider> (<kind>)".
  const choice = `${spec.provider} (api_key)`;
  const select = form.locator('select[name="need"]');
  const offered = (await select.locator("option").allInnerTexts().catch(() => [])).map((t) => t.trim());
  await select.selectOption({ label: choice });
  await form.locator('input[name="name"]').fill(spec.name);
  secretOnPage = true;
  await form.locator('textarea[name="fields"]').fill(`${spec.field}=${spec.key}`);
  await form.locator('input[name="destination_hosts"]').fill(spec.host);
  const sent = { hosts: await form.locator('input[name="destination_hosts"]').inputValue() };
  await form.locator('button[type="submit"]').click();
  const panel = `${layer} [data-test="confirmation"][data-own="true"]`;
  const confirmation = await page.waitForSelector(panel, { timeout: 30_000 })
    .then((el) => el.innerText()).catch(() => "");
  await page.locator(`${panel} [data-test="confirm-passkey"]`).click({ timeout: 30_000 });
  const created = await told(page, "Entry created.");
  const cleared = await typedAway(page);
  return {
    offered, choice, sent, created, cleared, confirmation: confirmation.replace(/\s+/g, " "),
  };
}

// The grant committed: confirmed, and the prompt gone.
async function confirmGrant(page) {
  await page.locator(`${layer} [data-test="prompt-confirm"]`).click({ timeout: 30_000 });
  return page.waitForFunction(() => !document.getElementById("system-layer-dialog")?.open, null, {
    timeout: 60_000,
  }).then(() => true).catch(() => false);
}

// What a page shows when a step does not hold: a screenshot beside the
// record, taken only while the page holds no key the proof typed
// (`secretOnPage` clear). While it may hold one, no screenshot is taken and
// the record says it was withheld.
async function diagnose(page, name) {
  await page.screenshot({ path: join(outDir, `${name}.png`), fullPage: true }).catch(() => null);
}

async function main() {
  const proxy = await startProxy(null, readHomes(homesFile));
  const browser = await launchBrowser("chromium", proxy);
  record.browser = browser.version();
  const page = await (await signedIn(browser)).newPage();
  const frames = [];
  page.on("websocket", (ws) => {
    ws.on("framesent", (f) => frames.push({ dir: "out", data: outputText(f.payload).slice(0, 600) }));
    ws.on("framereceived", (f) => frames.push({ dir: "in", data: outputText(f.payload).slice(0, 600) }));
  });

  try {
    // The proof's own model of everything the README names, changed at each
    // step only by what that step did: the athanor's entries and defaults,
    // the app's profiles, their consents and binding rows, and its turns
    // and executions, of which there are none. After every step the whole
    // of it is compared with the whole of what the home holds, in one read,
    // every field through its class: a change behind the browser to any of
    // it fails the next step, whichever step that is.
    const model = { entries: [], defaults: [], profiles: [], consents: [], refs: [], turns: [], executions: [] };
    const person = await ask({ op: "person" });
    // The database's time as the run starts: the window every stored time
    // is held to opens here, before anything the proof names is made.
    const run = { start: (await ask({ op: "clock" })).now };
    record.run_start = run.start;
    const ids = {};
    const sent = {};
    let implied = {};
    let profileId;

    const stateHolds = async () => {
      const payloads = Object.fromEntries(ENTRIES.filter((e) => ids[e.name]).map((e) => [ids[e.name], typedDigest(e)]));
      const state = await ask({ op: "state", payloads });
      const read = { start: run.start, now: state && state.now };
      const problems = [];
      const stored = storedState(state, read, problems);
      return {
        held: problems.length === 0 && same(stored, model, "state"),
        compared: { read, fields: problems, ...compared(stored, model, "state") },
      };
    };

    // An entry row as the model holds it: its id as the Vault page lists
    // it, what she sent, what the request implies the owner stores, the
    // state a new entry starts in, the payload she typed and its clock's
    // times; `over` is what a later step changed.
    const entryRow = (spec, over = {}) => ({
      id: ids[spec.name],
      athanor_id: person.athanor_id,
      name: spec.name,
      provider_hint: spec.provider,
      kind: "api_key",
      provenance: "user",
      field_names: JSON.stringify([spec.field]),
      binding_digest: implied[spec.name].binding_digest,
      oauth_endpoints: null,
      oauth_scopes: null,
      destination: implied[spec.name].destination,
      attach_only: true,
      status: "active",
      payload_rev: 0,
      sealed_payload: TYPED,
      last_used_at: null,
      inserted_at: IN_WINDOW,
      updated_at: IN_WINDOW,
      ...over,
    });
    const entryOver = {};
    const setEntries = (specs) => {
      model.entries = specs.map((s) => entryRow(s, entryOver[s.name] || {}));
    };
    const defaultRow = (provider, spec) => ({
      id: DEFAULT_ID, athanor_id: person.athanor_id, provider_hint: provider, vault_entry_id: ids[spec.name],
      instance_entry_id: null, inserted_at: IN_WINDOW, updated_at: IN_WINDOW,
    });
    const profileRow = (head) => ({
      id: profileId, athanor_id: person.athanor_id, source_ref: APP, kind: "owner", label: "default", status: "active",
      head_consent_id: head, inserted_at: IN_WINDOW, updated_at: IN_WINDOW,
    });
    // A consent row as the model holds it: the revision a commit of her
    // decisions writes, with what the owner's builders derive for them. No
    // writer sets `supersedes_id`; a revision follows the one before by
    // its number and the profile's head.
    const consentRow = (id, revision, made) => ({
      id, athanor_id: person.athanor_id, profile_id: profileId, revision, scope: "versionless", pinned_version: "",
      invoke_mode: "open_inert", shape_digest: made.shape_digest, commit_digest: made.commit_digest,
      blob_digest: made.blob_digest, resolved_policy: made.resolved_policy, activation: made.activation,
      granted_by: person.user_id, granted_via: "interactive", granted_at: IN_WINDOW, supersedes_id: null,
      admitted_origins: JSON.stringify(["interactive"]),
    });
    // A binding row: the entry the key binds, at the digest its request
    // implies, with its lifetime.
    const bindingRow = (consentId, key, spec, kind = "standing", expires = null, consumed = null) => ({
      consent_id: consentId, athanor_id: person.athanor_id, binding_key: key, scope: "athanor",
      vault_entry_id: ids[spec.name], instance_entry_id: null, via_label: null,
      binding_digest: implied[spec.name].binding_digest, lifetime_kind: kind, expires_at: expires,
      consumed_by_root: consumed,
    });
    // An entry as the decisions name it: its id, and the request she made
    // for it.
    const chosen = (spec) => ({ id: ids[spec.name], provider: spec.provider, destination: sent[spec.name] });
    // What a commit of `decisions` writes, derived by the owner's builders.
    const derive = (decisions) => ask({
      op: "derived",
      spec: { app: APP, origins: ["interactive"], removed: [], subset: {}, bindings: [], selections: [], ...decisions },
    });
    // The loader's admission, compared whole: admitted, on the profile and
    // consent the model takes from it, at the source node and activation
    // digest the derivation names, its edges the derived blob's.
    const admission = (admitted, made) => ({
      admitted: true, profile_id: admitted.profile_id, consent_id: admitted.consent_id, node_ref: APP,
      node_digest: made.node_digest, edges: made.edges,
    });
    const edgeTo = (edges, dep) => Object.entries(edges || {})
      .find(([key]) => key === dep || key.startsWith(`${dep}|`));
    // A use answer, compared whole and in order: as many answers as uses
    // asked, each in the place of the use it decides and naming that use's
    // request as the proof sent it (edge, need, account, root, method and
    // URL) beside the decision the proof expects for it, so an answer moved
    // to another request fails.
    const used = (answer, asked, decisions) => asked.length === decisions.length &&
      same(answer, { admitted: true, results: asked.map((request, i) => ({ request, ...decisions[i] })) });
    const yes = { admitted: true };
    const expired = { admitted: false, refusal: "grant_expired" };
    const openaiUse = (root) => ({
      edge: OPENAI, need: "api_key", root, url: "https://api.openai.com/v1/models", method: "GET",
    });
    const ownUse = (root, account) => ({
      edge: "@ingress", need: "openai", root, url: "https://api.openai.com/v1/chat/completions", method: "POST",
      ...(account ? { account } : {}),
    });
    const claudeUse = (root) => ({
      edge: CLAUDE, need: "api_key", root, url: "https://api.anthropic.com/v1/messages", method: "POST",
    });

    // -----------------------------------------------------------------------
    // provided_preview
    // -----------------------------------------------------------------------
    const published = await ask({ op: "publish", manifest: MANIFEST, index: INDEX });
    const passkey = await registerPasskey(page);
    await openGrant(page);
    const first = await sheet(page);
    const grok = depNeed(first, GROK);
    const providedRow = credential(first, KEY.grok);
    // The publisher's configuration takes no choice and asks for no key:
    // no entry offered, no "Change", no "Connect", no account to add, and
    // the prompt is the grant itself, never a credential prompt.
    const noKeyQuestion = !!grok && !!grok.provided && grok.picks.length === 0 && !grok.change && !grok.connect &&
      !grok.add_account && first.kind === "grant";
    const destinationShown = !!grok && !!grok.provided && /^Provided by local\b/.test(grok.provided) &&
      ["https://api.x.ai", "GET", "POST", "/v1/"].every((part) => grok.provided.includes(part));
    const firstHtml = await page.content();
    const committed1 = await confirmGrant(page);
    const admitted1 = await ask({ op: "admit" });
    profileId = admitted1.profile_id;
    const made1 = await derive({});
    const providedAsked = [
      { edge: GROK, need: "api_key", root: ROOT_A, url: "https://api.x.ai/v1/chat/completions", method: "POST" },
      { edge: GROK, need: "api_key", root: ROOT_A, url: "https://api.x.ai/v2/models", method: "GET" },
    ];
    const providedUses = await ask({ op: "use", uses: providedAsked });
    // The loaded Grok edge's vault is the provided configuration whole: the
    // destination the manifest names over https, its value and Grok's
    // attach rule.
    const grokEdge = edgeTo(admitted1.edges, GROK);
    const providedVault = {
      provided: {
        destination: { ...PROVIDED.destination, scheme: "https" }, values: PROVIDED.values, attach: BEARER,
      },
    };
    model.profiles = [profileRow(admitted1.consent_id)];
    model.consents = [consentRow(admitted1.consent_id, 1, made1)];
    const providedState = await stateHolds();
    record.provided_preview = {
      published, passkey, grok, provided_row: providedRow, committed: committed1, admitted: admitted1,
      provided_uses: providedUses, state: providedState.compared,
    };
    if (!row("provided_preview",
      published.name === NAME && published.version === MANIFEST.version && !!published.component &&
        passkey.active && noKeyQuestion && destinationShown && providedRow && committed1 &&
        same(admitted1, admission(admitted1, made1)) && grokEdge && same(grokEdge[1].vault, providedVault) &&
        used(providedUses, providedAsked, [yes, { admitted: false, refusal: "destination_mismatch" }]) &&
        !holdsKey(firstHtml) && providedState.held,
      "Grok's need shows the publisher's configuration and destination and asks nothing; committed, the loader " +
        "admits the root, whose Grok edge carries exactly that configuration, used only within its destination; " +
        "the whole state is the model",
      { grok, provided_row: providedRow, admitted: admitted1, grok_edge: grokEdge, uses: providedUses,
        state: providedState.compared })) return;

    // -----------------------------------------------------------------------
    // account_choices
    // -----------------------------------------------------------------------
    await openGrant(page);
    const connectWork = await connect(page, ownSelector("openai"), WORK);
    const connectAnthropic = await connect(page, depSelector(CLAUDE), ANTHROPIC);
    await page.locator(`${layer} [data-test="prompt-dismiss"]`).click({ timeout: 30_000 });
    const madeHome = await createOnVault(page, HOME);
    Object.assign(ids, await vaultIds(page));
    sent[WORK.name] = sentDestination(connectWork.sent.hosts);
    sent[ANTHROPIC.name] = sentDestination(connectAnthropic.sent.hosts);
    sent[HOME.name] = sentDestination(madeHome.sent.hosts);
    const listedAll = ENTRIES.every((e) => ids[e.name]);
    const vaultHtml = await page.content();
    await openGrant(page);
    const choices = await sheet(page);
    // Opened as the plan suggests: the athanor's default for openai.com,
    // the first she made, pressed on both OpenAI needs, each with "Change"
    // since another entry can meet it; the one Anthropic entry pressed with
    // no "Change", no picker and nothing else to choose.
    const openedAs = {
      own: shownPicks(ownNeed(choices, "openai")),
      own_change: !!ownNeed(choices, "openai")?.change,
      openai: shownPicks(depNeed(choices, OPENAI)),
      openai_change: !!depNeed(choices, OPENAI)?.change,
      claude: shownPicks(depNeed(choices, CLAUDE)),
      claude_change: !!depNeed(choices, CLAUDE)?.change,
    };
    const openedExpected = {
      own: [{ name: WORK.name, pressed: true }], own_change: true,
      openai: [{ name: WORK.name, pressed: true }], openai_change: true,
      claude: [{ name: ANTHROPIC.name, pressed: true }], claude_change: false,
    };
    // The OpenAI dependency's edge takes the other entry: "Change", then it.
    await page.locator(`${depSelector(OPENAI)} [data-test="grant-change"]`).click({ timeout: 30_000 });
    const changing = await settled(page, (s) => (depNeed(s, OPENAI)?.picks || []).length === 2, "both OpenAI entries");
    await page.locator(`${depSelector(OPENAI)} [data-test="grant-pick"][phx-value-entry_id="${ids[HOME.name]}"]`)
      .click({ timeout: 30_000 });
    const chose = await settled(page, (s) => s.confirmable && (credential(s, KEY.openai)?.sentence || "")
      .includes(HOME.name), "the OpenAI edge previewed with OpenAI Home").catch(() => null);
    // One credential row per binding, each naming the entry chosen for its
    // edge, all until revoked; Grok's the publisher's.
    const perEdge = chose && {
      own: (credential(chose, KEY.own)?.sentence || "").includes(WORK.name),
      openai: (credential(chose, KEY.openai)?.sentence || "").includes(HOME.name),
      claude: (credential(chose, KEY.claude)?.sentence || "").includes(ANTHROPIC.name),
      grok: !!credential(chose, KEY.grok),
      lifetimes: lifetimesOf(chose),
      removed: chose.removed,
    };
    const committed2 = await confirmGrant(page);
    const admitted2 = await ask({ op: "admit" });
    const requested = await ask({
      op: "requested",
      entries: ENTRIES.map((e) => ({ provider: e.provider, field: e.field, destination: sent[e.name] })),
    });
    implied = Object.fromEntries(ENTRIES.map((e, i) => [e.name, (requested.entries || [])[i] || {}]));
    const decisions2 = {
      bindings: [{ need: "openai", entry: chosen(WORK), lifetime: { kind: "standing" } }],
      selections: [
        { from: APP, dep: OPENAI, need: "api_key", entry: chosen(HOME), lifetime: { kind: "standing" } },
        { from: APP, dep: CLAUDE, need: "api_key", entry: chosen(ANTHROPIC), lifetime: { kind: "standing" } },
      ],
    };
    const made2 = await derive(decisions2);
    // Three entries she made, each the one its request implies, holding
    // what she typed; the first of each provider its default; revision 2
    // of the profile binding each edge to its chosen entry.
    setEntries(ENTRIES);
    model.defaults = [defaultRow("openai.com", WORK), defaultRow("anthropic.com", ANTHROPIC)];
    model.profiles = [profileRow(admitted2.consent_id)];
    model.consents = [...model.consents, consentRow(admitted2.consent_id, 2, made2)];
    model.refs = [
      bindingRow(admitted2.consent_id, KEY.own, WORK),
      bindingRow(admitted2.consent_id, KEY.openai, HOME),
      bindingRow(admitted2.consent_id, KEY.claude, ANTHROPIC),
    ];
    const choicesState = await stateHolds();
    const grantHtml = await page.content();
    record.account_choices = {
      connect: { work: connectWork, anthropic: connectAnthropic }, vault: madeHome, ids, sent,
      opened_as: openedAs, changing: changing && depNeed(changing, OPENAI), per_edge: perEdge,
      committed: committed2, admitted: admitted2, state: choicesState.compared,
    };
    if (!row("account_choices",
      listedAll && madeHome.created && connectWork.cleared && connectAnthropic.cleared && madeHome.cleared &&
        same(openedAs, openedExpected) && perEdge && perEdge.own && perEdge.openai &&
        perEdge.claude && perEdge.grok &&
        same(perEdge.lifetimes, lifetimesExpected({
          [KEY.own]: STANDING, [KEY.openai]: STANDING, [KEY.claude]: STANDING, [KEY.grok]: STANDING,
        })) &&
        perEdge.removed.length === 0 && committed2 && same(admitted2, admission(admitted2, made2)) &&
        !holdsKey(vaultHtml) && !holdsKey(grantHtml) && choicesState.held,
      "two OpenAI entries, one through Connect and one on the Vault page, and one Anthropic entry: the app's own " +
        "calls take OpenAI Work, the OpenAI edge OpenAI Home, the one Anthropic entry chosen with no picker; the " +
        "whole state is the model",
      { opened_as: openedAs, per_edge: perEdge, admitted: admitted2, state: choicesState.compared })) return;

    // -----------------------------------------------------------------------
    // commit_bindings
    // -----------------------------------------------------------------------
    await openGrant(page);
    const regrant = await sheet(page);
    // A re-grant opens on what the head binds, each until revoked.
    const reopened = lifetimesOf(regrant);
    await credentialRow(page, KEY.openai).locator('button[data-lifetime="once"]').click({ timeout: 30_000 });
    await settled(page, (s) => credential(s, KEY.openai)?.lifetime === "one run", "the once lifetime");
    const before = (await ask({ op: "clock" })).now;
    await credentialRow(page, KEY.claude).locator('button[data-lifetime="5m"]').click({ timeout: 30_000 });
    // An until names its instant; "until revoked" is standing.
    const timed = await settled(page,
      (s) => /^until \d{4}-\d{2}-\d{2}T\S+$/.test(credential(s, KEY.claude)?.lifetime || ""),
      "the five-minute lifetime");
    const after = (await ask({ op: "clock" })).now;
    const until = credential(timed, KEY.claude).lifetime.slice("until ".length);
    // The until she was shown is five minutes from the moment she chose it,
    // to the second: between the database's time just before the click,
    // cut to its second, and its time just after.
    const untilAt = micros(until);
    const chosenAt = untilAt === null ? null : untilAt - 300_000_000n;
    const untilHeld = chosenAt !== null && chosenAt >= (micros(before) / 1_000_000n) * 1_000_000n &&
      chosenAt <= micros(after);
    await page.locator(`${layer} [data-row="egress"][data-node="${OPENAI}"] [data-test="grant-get-head-only"]`)
      .click({ timeout: 30_000 });
    const narrowed = await settled(page, (s) => s.confirmable && egressOf(s, OPENAI)?.narrowing?.pressed === true,
      "GET only pressed");
    const lifetimesShown = lifetimesOf(narrowed);
    const committed3 = await confirmGrant(page);
    const admitted3 = await ask({ op: "admit" });
    const subset = { [OPENAI]: { egress: { methods: ["GET"] } } };
    const decisions3 = {
      bindings: [{ need: "openai", entry: chosen(WORK), lifetime: { kind: "standing" } }],
      selections: [
        { from: APP, dep: OPENAI, need: "api_key", entry: chosen(HOME), lifetime: { kind: "once" } },
        { from: APP, dep: CLAUDE, need: "api_key", entry: chosen(ANTHROPIC), lifetime: { kind: "until", until } },
      ],
      subset,
    };
    const made3 = await derive(decisions3);
    model.profiles = [profileRow(admitted3.consent_id)];
    model.consents = [...model.consents, consentRow(admitted3.consent_id, 3, made3)];
    model.refs = [
      ...model.refs,
      bindingRow(admitted3.consent_id, KEY.own, WORK),
      bindingRow(admitted3.consent_id, KEY.openai, HOME, "once"),
      bindingRow(admitted3.consent_id, KEY.claude, ANTHROPIC, "until", instant(until)),
    ];
    const bindingsState = await stateHolds();
    record.commit_bindings = {
      reopened, before, after, until, until_held: untilHeld, lifetimes_shown: lifetimesShown,
      openai_egress: egressOf(narrowed, OPENAI), removed: narrowed.removed, committed: committed3,
      admitted: admitted3, state: bindingsState.compared,
    };
    if (!row("commit_bindings",
      same(reopened, lifetimesExpected({
        [KEY.own]: STANDING, [KEY.openai]: STANDING, [KEY.claude]: STANDING, [KEY.grok]: STANDING,
      })) &&
        same(lifetimesShown, lifetimesExpected({
          [KEY.own]: STANDING, [KEY.openai]: "one run", [KEY.claude]: `until ${until}`, [KEY.grok]: STANDING,
        })) && untilHeld &&
        same(egressOf(narrowed, OPENAI), GET_ONLY_SHOWN) &&
        narrowed.removed.length === 0 && committed3 && same(admitted3, admission(admitted3, made3)) &&
        bindingsState.held,
      "the re-grant opens on the head's bindings, and commits them until revoked, once and for five minutes from " +
        "the moment she chose it, the OpenAI edge narrowed to GET only; the whole state is the model",
      { reopened, lifetimes_shown: lifetimesShown, until, until_held: untilHeld, admitted: admitted3,
        state: bindingsState.compared })) return;

    // -----------------------------------------------------------------------
    // lifetime_decisions
    // -----------------------------------------------------------------------
    // Before the until: the app's own calls admitted; the once binding
    // admitted for root A, again for root A, refused for root B; the
    // five-minute binding admitted.
    const firstAsked = [ownUse(ROOT_A), openaiUse(ROOT_A), openaiUse(ROOT_A), openaiUse(ROOT_B), claudeUse(ROOT_A)];
    const firstUses = await ask({ op: "use", uses: firstAsked });
    // Root A consumed the once binding's row; each entry admitted was read
    // and its last use stamped.
    model.refs = model.refs.map((r) => (r.consent_id === admitted3.consent_id && r.binding_key === KEY.openai
      ? { ...r, consumed_by_root: ROOT_A } : r));
    for (const spec of ENTRIES) entryOver[spec.name] = { ...(entryOver[spec.name] || {}), last_used_at: IN_WINDOW };
    setEntries(ENTRIES);
    const usedState = await stateHolds();
    // A real wait, bounded, until the database's time is past the until.
    const waitStart = Date.now();
    let now = (await ask({ op: "clock" })).now;
    while (!(micros(now) > untilAt) && Date.now() - waitStart < 330_000) {
      await sleep(5_000);
      now = (await ask({ op: "clock" })).now;
    }
    const waited = Math.round((Date.now() - waitStart) / 1000);
    const passed = micros(now) > untilAt;
    // After it: the five-minute binding refused, the standing one admitted.
    const laterAsked = [claudeUse(ROOT_A), ownUse(ROOT_B)];
    const laterUses = await ask({ op: "use", uses: laterAsked });
    const admittedLater = await ask({ op: "admit" });
    const openaiEdge = edgeTo(admittedLater.edges, OPENAI);
    const expiredState = await stateHolds();
    record.lifetime_decisions = {
      roots: { a: ROOT_A, b: ROOT_B }, first_uses: firstUses, used_state: usedState.compared, waited, passed,
      now, later_uses: laterUses, admitted: admittedLater, openai_edge: openaiEdge, state: expiredState.compared,
    };
    if (!row("lifetime_decisions",
      used(firstUses, firstAsked, [yes, yes, yes, expired, yes]) && usedState.held && passed && waited <= 330 &&
        used(laterUses, laterAsked, [expired, yes]) && same(admittedLater, admission(admitted3, made3)) && openaiEdge &&
        same(openaiEdge[1].egress, GET_ONLY_GRANT) && expiredState.held,
      "the use path admits the once binding for root A, again for root A, refuses root B; admits the five-minute " +
        `binding, then after a real wait of ${waited} s past its instant refuses it; the loaded OpenAI edge grants ` +
        "GET alone; no request is sent; the whole state is the model",
      { first_uses: firstUses, waited, later_uses: laterUses, openai_edge: openaiEdge,
        state: expiredState.compared })) return;

    // -----------------------------------------------------------------------
    // named_prompt
    // -----------------------------------------------------------------------
    const thread = await ask({ op: "thread" });
    await open(page, `${base}/chat?a=${encodeURIComponent(segment)}&c=${encodeURIComponent(thread.thread_id)}`);
    // The athanor's thread pane, its own view, connected. Its connected
    // mount follows the thread's events (`PrismWeb.ThreadPaneLive`'s
    // `open_thread/2`) before it answers the join that marks it connected,
    // so once it is, the announcement reaches it: nothing more is waited for.
    await page.waitForSelector(`[id="pane-${person.athanor_id}"].phx-connected`, { timeout: 30_000 });
    const announced = await ask({ op: "announce", thread_id: thread.thread_id, name: ACCOUNT });
    await granting(page);
    const named = await sheet(page);
    const ownBlock = ownNeed(named, "openai");
    const account = ownBlock && ownBlock.accounts.find((a) => a.account === ACCOUNT);
    // The prompt opens on the account: a row of that fixed name beside the
    // app's default, its entries offered with none pressed; the binding
    // whose until passed opens with no lifetime pressed; the used once
    // binding stays once, with "Grant once again" not pressed; and the
    // OpenAI catalyst's network opens on the head's narrowing, GET only,
    // which she leaves as it is.
    const openedOn = {
      title: named.title,
      account: account && { fixed: account.fixed, picks: shownPicks(account) },
      claude_pending: !!depNeed(named, CLAUDE)?.pending &&
        !depNeed(named, CLAUDE).pending.lifetimes.some((l) => l.pressed),
      openai: credential(named, KEY.openai) &&
        { lifetime: credential(named, KEY.openai).lifetime, renew: credential(named, KEY.openai).renew },
      openai_egress: egressOf(named, OPENAI),
      account_lifetimes: account && account.lifetimes,
    };
    const accountRow = `${ownSelector("openai")} [data-test="grant-account"][data-account="${ACCOUNT}"]`;
    await page.locator(`${accountRow} [data-test="grant-account-pick"][phx-value-entry_id="${ids[HOME.name]}"]`)
      .click({ timeout: 30_000 });
    await page.locator(`${accountRow} [data-test="grant-account-lifetime"] button[data-lifetime="standing"]`)
      .click({ timeout: 30_000 });
    await page.locator(`${depSelector(CLAUDE)} [data-test="grant-lifetime-pending"] button[data-lifetime="standing"]`)
      .click({ timeout: 30_000 });
    const namedReady = await settled(page, (s) => s.confirmable &&
      (credential(s, KEY.personal)?.sentence || "").includes(HOME.name) &&
      credential(s, KEY.claude)?.lifetime === "until revoked" && egressOf(s, OPENAI)?.narrowing?.pressed === true,
    "the account bound, Anthropic until revoked, GET only").catch(() => null);
    const namedShown = namedReady && {
      lifetimes: lifetimesOf(namedReady),
      openai_egress: egressOf(namedReady, OPENAI),
      removed: namedReady.removed,
    };
    const committed4 = await confirmGrant(page);
    const retold = await told(page, "Granted. The turn that asked has ended — send your message again to run it.");
    const admitted4 = await ask({ op: "admit" });
    const decisions4 = {
      bindings: [
        { need: "openai", entry: chosen(WORK), lifetime: { kind: "standing" } },
        { need: "openai", name: ACCOUNT, entry: chosen(HOME), lifetime: { kind: "standing" } },
      ],
      selections: [
        { from: APP, dep: OPENAI, need: "api_key", entry: chosen(HOME), lifetime: { kind: "once" } },
        { from: APP, dep: CLAUDE, need: "api_key", entry: chosen(ANTHROPIC), lifetime: { kind: "standing" } },
      ],
      subset,
    };
    const made4 = await derive(decisions4);
    const resolved = await ask({ op: "account", name: ACCOUNT });
    // Revision 4: the app's default, the account beside it, the used once
    // binding carried used by root A, Anthropic until revoked. No turn and
    // no execution exists.
    model.profiles = [profileRow(admitted4.consent_id)];
    model.consents = [...model.consents, consentRow(admitted4.consent_id, 4, made4)];
    model.refs = [
      ...model.refs,
      bindingRow(admitted4.consent_id, KEY.own, WORK),
      bindingRow(admitted4.consent_id, KEY.personal, HOME),
      bindingRow(admitted4.consent_id, KEY.openai, HOME, "once", null, ROOT_A),
      bindingRow(admitted4.consent_id, KEY.claude, ANTHROPIC),
    ];
    const namedState = await stateHolds();
    const chatHtml = await page.content();
    record.named_prompt = {
      thread, announced, opened_on: openedOn, shown: namedShown, committed: committed4, retold,
      admitted: admitted4, resolved, state: namedState.compared,
    };
    if (!row("named_prompt",
      same(announced, { resolution: "connection_not_granted", announced: true }) &&
        // A need's entries are offered in the order the vault lists them,
        // by name (`Arca.VaultStorage.list/2`).
        same(openedOn.account, {
          fixed: true, picks: [{ name: HOME.name, pressed: false }, { name: WORK.name, pressed: false }],
        }) &&
        openedOn.claude_pending && same(openedOn.openai, { lifetime: "one run", renew: false }) &&
        same(openedOn.openai_egress, GET_ONLY_SHOWN) && namedShown &&
        same(namedShown.lifetimes, lifetimesExpected({
          [KEY.own]: STANDING, [KEY.personal]: STANDING, [KEY.openai]: "one run", [KEY.claude]: STANDING,
          [KEY.grok]: STANDING,
        })) &&
        same(namedShown.openai_egress, GET_ONLY_SHOWN) &&
        namedShown.removed.length === 0 && committed4 && retold && same(admitted4, admission(admitted4, made4)) &&
        same(resolved, { resolved: true, entry_id: ids[HOME.name], name: ACCOUNT }) && !holdsKey(chatHtml) &&
        namedState.held,
      `the prompt a launch naming "${ACCOUNT}" opens, raised by the event a turn would announce and with no turn, ` +
        "opens on the head's GET only and binds OpenAI Home under that name; the new revision holds it, still GET " +
        "only, the pane says to send the message again, and no turn or execution exists; the whole state is the model",
      { announced, opened_on: openedOn, shown: namedShown, retold, resolved, state: namedState.compared })) return;

    // -----------------------------------------------------------------------
    // revocation
    // -----------------------------------------------------------------------
    await open(page, pagePath("/vault"));
    await page.locator(`button[phx-click="revoke"][phx-value-id="${ids[WORK.name]}"]`).click({ timeout: 30_000 });
    await agree(page);
    const revoked = await told(page, "Entry revoked — 1 profile(s) lose access at next run.");
    const admittedRevoked = await ask({ op: "admit" });
    const revokedAsked = [ownUse(ROOT_C), ownUse(ROOT_C, ACCOUNT)];
    const revokedUses = await ask({ op: "use", uses: revokedAsked });
    // OpenAI Work is revoked; the account beside it was used.
    entryOver[WORK.name] = { ...entryOver[WORK.name], status: "revoked" };
    setEntries(ENTRIES);
    const revokedState = await stateHolds();
    record.revocation = {
      revoked, admitted: admittedRevoked, uses: revokedUses, state: revokedState.compared,
    };
    row("revocation",
      revoked && same(admittedRevoked, admission(admitted4, made4)) &&
        used(revokedUses, revokedAsked, [{ admitted: false, refusal: "entry_unavailable", status: "revoked" }, yes]) &&
        revokedState.held,
      "OpenAI Work revoked on the Vault page: the root is still admitted, the next use of the app's own calls is " +
        `refused, and the "${ACCOUNT}" account beside it still admitted; the whole state is the model`,
      { revoked, uses: revokedUses, state: revokedState.compared });
  } catch (error) {
    row(STEPS[rows.length] || "error", false, "the step ran to its end", String(error && error.stack || error));
  } finally {
    const failed = rows.length !== STEPS.length || !rows.every((r) => r.held);
    if (failed) {
      // The screenshot, unless the page could show a key she typed: then it
      // is withheld, and the record says so with redact.mjs's marker.
      const screenshot = { secret_on_page: secretOnPage };
      if (secretOnPage) {
        screenshot.withheld = `${MARKER}: withheld, since the page could show a key she typed`;
      } else {
        await diagnose(page, "approval-proof");
        screenshot.file = "approval-proof.png";
      }
      record.screenshot = screenshot;
      // Collect the page's tokens before closing it. Every later writer,
      // including an error while closing, keeps these values redacted too.
      for (const token of await pageTokens(page)) knownPageTokens.add(token);
      writeFileSync(join(outDir, "approval-proof-frames.json"),
        JSON.stringify(redactFrames(frames.slice(-40), outputSecrets()), null, 1));
    }
    await browser.close();
    await proxy.close();
    // No key, nor a digest of a key or of a typed payload, reached an
    // answer, the record or a question left in the output directory.
    const recorded = JSON.stringify({ rows, record });
    const asks = readdirSync(outDir).filter((f) => f.startsWith("ask-"))
      .map((f) => readFileSync(join(outDir, f), "utf8"));
    const leaked = holdsKey(recorded) || answers.some(holdsKey) || asks.some(holdsKey);
    if (leaked) rows.push({ step: "material", held: false, what: "a key reached an answer or the record", detail: {} });
    writeFileSync(join(outDir, "approval-proof.json"), recordText({
      viewport: record.viewport, browser: record.browser, rows, record, material_in_answers: leaked,
    }, outputSecrets()));
    const table = [`Viewport: ${viewportName} (${viewport.width}×${viewport.height}), Chromium ${record.browser || "?"}`, "",
      "| Step | Held | What |", "|---|---|---|",
      ...rows.map((r) => `| \`${r.step}\` | ${r.held ? "held" : "FAILED"} | ${r.what} |`)].join("\n");
    const shownTable = outputText(table);
    writeFileSync(join(outDir, "approval-proof.md"), shownTable + "\n");
    console.log(shownTable);
  }
}

main()
  .then(() => process.exit(rows.length === STEPS.length && rows.every((r) => r.held) ? 0 : 1))
  .catch((error) => {
    console.error(outputText(String(error && error.stack || error)));
    process.exit(1);
  });
