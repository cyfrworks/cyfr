// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The instance-entry proof, run in the official Playwright image by run.sh
// against a `cyfr` release behind the harness's HTTPS front (README.md).
// The platform administrator, in Chromium, makes two keys on the Vault page
// and shares each with everyone through the system layer's sharing sheet;
// Ana, a member who signs in after, is offered them in her vault and her
// first sign-in binds the model key's share; Bea signs in once and is
// denied. Each step is one row of the record; the proof fails when a row
// does not hold, and stops at the first row a later one rests on.
//
//   share_key        Company AI (openai.com, a person cap of 3) and Company
//                    Mail are made on the Vault page, each key typed in its
//                    form alone and its credential_entry confirmation proven
//                    with the administrator's passkey; each is shared with
//                    everyone through the sharing sheet, which opens with
//                    its caps empty and says what they mean, its
//                    credential_sharing confirmation proven with the
//                    passkey; Shared by you reads both
//   first_sign_in    Ana's first sign-in provisions her athanor: its
//                    bootstrap binds Company AI's share on the openai
//                    catalyst, the real loader admits the root with no run
//                    started, a claim through the share is admitted and
//                    counted, its row binding reads offered, and her vault's
//                    Shared with you offers both, by the administrator's
//                    name, and shows no material
//   claim_cap        two more claims through the share are admitted and the
//                    next is refused with its reset at the database's next
//                    UTC midnight; her vault's Shared with you, compared
//                    whole, shows the owner and her use today, 3, and no
//                    cap, which is the owner's
//   narrow_audience  the administrator narrows Company AI's share to a group
//                    holding Bea on Shared by you, which sends the audience
//                    the row showed as expected: Ana's claim is refused, her
//                    consent's row binding reads it no longer offered, and
//                    her vault no longer offers it
//   revoke           Company Mail's share, claimed by Ana just before, is
//                    revoked on Shared by you: her next claim is refused,
//                    and her vault offers nothing
//   deny_person      Bea, in Traders, is offered Company AI's share and a
//                    claim through it is admitted and counted; denied at the
//                    door on the Settings page, she is offered nothing, the
//                    same claim is refused and counts nothing, and nothing of
//                    a share changes
//   admin_focus      the administrator's switcher lists no athanor of Ana's,
//                    a direct visit is refused, and Sanctum's focus decision
//                    refuses it
//
// The home's part of a step — signing a person in, a claim, a read of what
// was committed — is run.sh's, asked for through OUT_DIR (`ask-N.json`,
// answered `answer-N.json`) and done by fixture.exs, which returns bounded
// facts and never material.
//
// Usage: node proof.mjs HOMES_FILE ADMIN_SEGMENT ADMIN_COOKIE OUT_DIR VIEWPORT

import { createHash, randomBytes } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ask as askRunSh, launchBrowser, readHomes, startProxy, virtualAuthenticator } from "../browser/lib.mjs";

const [homesFile, adminSegment, adminCookie, outDir, viewportName] = process.argv.slice(2);
if (!homesFile || !adminSegment || !adminCookie || !outDir || !viewportName) {
  console.error("usage: node proof.mjs HOMES_FILE ADMIN_SEGMENT ADMIN_COOKIE OUT_DIR VIEWPORT");
  process.exit(64);
}

// VAULT_PROOF_VIEWPORT, as run.sh validated it.
const VIEWPORTS = { desktop: { width: 1280, height: 900 }, "720x720": { width: 720, height: 720 } };
const viewport = VIEWPORTS[viewportName];
if (!viewport) {
  console.error(`the viewport is desktop or 720x720, not ${viewportName}`);
  process.exit(64);
}
mkdirSync(outDir, { recursive: true });

const STEPS = ["share_key", "first_sign_in", "claim_cap", "narrow_audience", "revoke", "deny_person", "admin_focus"];
const { homes } = readHomes(homesFile);
const base = homes[0].origin;
const layer = "#system-layer-dialog";
const rows = [];
const record = { viewport: { name: viewportName, ...viewport } };

// The keys are this run's own, typed in the Vault page's form and nowhere
// else; no page, answer or record may hold either.
const AI = {
  name: "Company AI",
  provider: "openai.com",
  hosts: "api.openai.com",
  methods: "POST GET",
  paths: "/v1/chat/completions /v1/models",
  person_daily: "3",
  key: `sk-company-ai-${randomBytes(12).toString("hex")}`,
  url: "https://api.openai.com/v1/chat/completions",
  method: "POST",
};
const MAIL = {
  name: "Company Mail",
  provider: "mail.example",
  hosts: "api.mail.example",
  methods: "POST",
  paths: "/v1/send",
  person_daily: "",
  key: `mail-key-${randomBytes(12).toString("hex")}`,
  url: "https://api.mail.example/v1/send",
  method: "POST",
};
const KEYS = [AI.key, MAIL.key];
const sha256 = (text) => createHash("sha256").update(text).digest("hex");
// The digest of the payload document an entry's form typed, as its owner
// encodes one (`Sanctum.Vault.Payload`: version 3, the one field, no
// token bundle) in its canonical text; the fixture compares the stored
// payload with it. Neither it nor a digest of a key may reach a page, an
// answer or the record.
const typedDigest = (spec) => sha256(JSON.stringify(canonical({ v: 3, fields: { [FIELD]: spec.key } })));
// The field the key is typed under in the Vault page's form.
const FIELD = "API_KEY";
// The administrator's name as others read it: the release fixture's person
// (tests/release-boot/fixture.exs `person`), as Bea's row below holds it.
const OWNER = "Release proof";
// What the sharing sheet says of its caps, and of a share to everyone with
// none, to the platform administrator.
const CAPS_MEANING = "An empty cap is no limit. 0 admits no use. A number is the most requests that day; " +
  "a day ends at midnight UTC.";
const UNCAPPED = "Shared with everyone and no cap, anyone on this CYFR may use it without limit. You administer " +
  "this CYFR, so a key you share with everyone is also what each new person's AQUA uses when it fits, with no " +
  "limit unless you set one.";

// ---------------------------------------------------------------------------
// Whole objects
// ---------------------------------------------------------------------------
//
// A claim about something the home committed compares the whole committed
// object with the whole object the proof expects, as one equality, after
// the same canonical ordering on both sides: object members by name, and
// the items of every list by their own canonical text, so a list is read
// as the set the grammar makes it.

function canonical(value) {
  if (Array.isArray(value)) {
    return value.map(canonical).map((item) => [JSON.stringify(item), item])
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([, item]) => item);
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  }
  return value;
}

const same = (stored, expected) => JSON.stringify(canonical(stored)) === JSON.stringify(canonical(expected));

// Both sides of a whole-object comparison, for the record of a row.
const compared = (stored, expected) => ({ stored: canonical(stored), expected: canonical(expected) });

// The destination an entry's form requested: every field it typed, as
// the destination grammar names them (`hosts`, `scheme`, `port`,
// `methods`, `paths`). A port left blank is no port.
function requestedDestination(spec) {
  const words = (text) => text.split(/\s+/).filter(Boolean);
  return { hosts: words(spec.hosts), scheme: "https", methods: words(spec.methods), paths: words(spec.paths) };
}

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
//            the model holds: what a form's request implies the owner stores
//            (`requested_digest`), or what the first sign-in's bootstrap
//            derives from it and the administrator's share (`derived_head`);
//   bound    a clock or server-minted value, held to the bound the table
//            states.
//
// Before the one comparison every field goes through its class: an exact
// or derived field stays as stored, and a bound field becomes what the
// model holds when the bound holds. A field the table does not name
// becomes `{unclassified: true}` and a named field a row lacks
// `{missing: true}`; the model never holds either, so either fails the
// step, and the step's record names the field. A new column cannot slip in
// unchecked.

// What a bound field becomes when its bound holds.
const IN_WINDOW = "inside the run's window";
const TODAY = "the database's today";

// Microseconds since the epoch of a UTC time as the home writes it
// (`2026-10-05T10:00:00.123456Z`), or null for anything else.
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
const day = {
  class: "bound",
  bound: "the database's today, read in the same call",
  check: (value, read) => (value === read.today ? TODAY : { not_today: value }),
};
// The sealed payload, compared inside the fixture: the proof passes the
// digest of the payload document its form typed, the fixture unseals the
// stored payload as its owner does and answers only the outcome, so neither
// the material nor anything derived from it reaches the proof. Each outcome
// but a match is its own sentence.
const TYPED = "the value its form typed";
const PAYLOAD_OUTCOMES = {
  matches: TYPED,
  differs: "the stored payload unseals to another value than its form typed",
  does_not_unseal: "the stored payload does not unseal",
  absent: "no payload is stored where its form typed one",
};
const typedPayload = {
  class: "derived",
  from: "the digest of the payload document its form typed, compared inside the fixture",
  check: (value) => PAYLOAD_OUTCOMES[value] || { unexpected_payload_answer: typeof value },
};

const ROW = "its row on the Vault page shows";
const SHARED_ROW = "its row under Shared by you on the Vault page shows";
const ADMISSION = "the loader's admission of Ana's root named";
const SIGN_IN = "the person's sign-in named";
const ADMIN = "the administrator's sign-in named";
const REQUESTED = "requested_digest, from the destination its form requested";
const DERIVED = "derived_head, built by the owner's builders from the installed catalyst, the request and the share";
const NONE = "no row is expected: nothing in this proof makes one";

const FIELDS = {
  vault_entries: {
    id: minted(ROW),
    athanor_id: minted(ADMIN),
    name: exact,
    provider_hint: exact,
    kind: exact,
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
  instance_entries: {
    id: minted(NONE),
    name: exact,
    kind: exact,
    provider_hint: exact,
    field_names: exact,
    binding_digest: derived(REQUESTED),
    destination: derived(REQUESTED),
    status: exact,
    payload_rev: exact,
    sealed_payload: exact,
    last_used_at: clock,
    audience: exact,
    person_daily: exact,
    total_daily: exact,
    component_policy: exact,
    created_by: minted(ADMIN),
    inserted_at: clock,
    updated_at: clock,
  },
  instance_entry_members: {
    instance_entry_id: minted(NONE),
    user_id: minted(SIGN_IN),
    inserted_at: clock,
  },
  instance_entry_usage: {
    instance_entry_id: minted(NONE),
    user_id: minted(`${SIGN_IN}, or the empty id of the entry's own total`),
    day,
    count: exact,
    updated_at: clock,
  },
  shares: {
    id: minted(SHARED_ROW),
    athanor_id: minted(ADMIN),
    vault_entry_id: minted(ROW),
    audience: exact,
    group_id: exact,
    person_daily: exact,
    total_daily: exact,
    status: exact,
    created_by: minted(ADMIN),
    inserted_at: clock,
    updated_at: clock,
  },
  share_usage: {
    athanor_id: minted(ADMIN),
    share_id: minted(SHARED_ROW),
    user_id: minted(`${SIGN_IN}, or the empty id of the share's own total`),
    day,
    count: exact,
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
    admitted_origins: exact,
  },
  consent_vault_refs: {
    consent_id: minted(ADMISSION),
    athanor_id: minted(SIGN_IN),
    binding_key: exact,
    scope: exact,
    vault_entry_id: exact,
    instance_entry_id: exact,
    share_id: minted(SHARED_ROW),
    via_label: exact,
    binding_digest: derived(REQUESTED),
    lifetime_kind: exact,
    expires_at: exact,
    consumed_by_root: exact,
  },
  users: {
    id: minted(SIGN_IN),
    email: exact,
    email_verified: exact,
    admission: exact,
    display_name: exact,
    namespace: exact,
    personal_athanor_id: minted(SIGN_IN),
    status: exact,
    prefs: exact,
    first_seen_at: clock,
    last_seen_at: clock,
    denied_at: clock,
    security_generation: exact,
    created_at: clock,
    updated_at: clock,
  },
};

// One stored row of `table`, each field through its class; `problems`
// collects each unclassified or missing field.
function classified(table, row, read, problems) {
  if (!row || typeof row !== "object") return row;
  const fields = FIELDS[table];
  const out = {};
  for (const [name, value] of Object.entries(row)) {
    const spec = fields[name];
    if (!spec) problems.push(`${table}.${name}: unclassified`);
    out[name] = !spec ? { unclassified: true } : spec.check ? spec.check(value, read) : value;
  }
  for (const name of Object.keys(fields)) {
    if (!(name in row)) {
      problems.push(`${table}.${name}: missing`);
      out[name] = { missing: true };
    }
  }
  return out;
}

// Everything the README names, as the home holds it (`fixture.exs`
// `state`), every field through its class, shaped for the one comparison:
// every vault entry, every entry, member and use row of the instance,
// every share and share use row, Ana's profiles, consents, binding rows,
// offered instance entries and shares, and Bea's row and the shares
// offered to her, or the refusal.
function storedState(state, read, problems) {
  const each = (table, rows) => (rows || []).map((r) => classified(table, r, read, problems));
  return {
    vault_entries: each("vault_entries", state && state.vault_entries),
    entries: each("instance_entries", state && state.entries),
    members: each("instance_entry_members", state && state.members),
    usage: each("instance_entry_usage", state && state.usage),
    shares: each("shares", state && state.shares),
    share_usage: each("share_usage", state && state.share_usage),
    ana: (state && state.ana) ? {
      profiles: each("profiles", state.ana.profiles),
      consents: each("consents", state.ana.consents),
      rows: each("consent_vault_refs", state.ana.rows),
      offered: state.ana.offered || [],
      shared: state.ana.shared || [],
    } : null,
    bea: (state && state.bea) ? {
      user: classified("users", state.bea.user, read, problems),
      shared: state.bea.shared === undefined ? { missing: true } : state.bea.shared,
    } : null,
  };
}

// The whole entry a form's request asks the store to hold: its id as its
// row shows it, the administrator's athanor, the form's fields, the key's
// one field, what the request implies the owner stores
// (`requested_digest`: the destination's canonical text and the binding
// digest over it), attach-only as the form leaves it, the state a new
// entry starts in, the payload its form typed and its clock's times; `over`
// is what a later step changed.
function requestedEntry(spec, id, implied, athanorId, over = {}) {
  return {
    id,
    athanor_id: athanorId,
    name: spec.name,
    provider_hint: spec.provider,
    kind: "api_key",
    field_names: JSON.stringify([FIELD]),
    binding_digest: implied.binding_digest,
    oauth_endpoints: null,
    oauth_scopes: null,
    destination: implied.destination,
    attach_only: true,
    status: "active",
    payload_rev: 0,
    sealed_payload: TYPED,
    last_used_at: null,
    inserted_at: IN_WINDOW,
    updated_at: IN_WINDOW,
    ...over,
  };
}

// The whole share the sheet's request asks the store to hold: its id as
// its row shows it, the entry it names, everyone, the caps typed (an empty
// one none), active, made by the administrator; `over` is what a later
// step changed.
function requestedShare(spec, id, entryId, operator, over = {}) {
  return {
    id,
    athanor_id: operator.athanor_id,
    vault_entry_id: entryId,
    audience: "everyone",
    group_id: null,
    person_daily: spec.person_daily === "" ? null : Number(spec.person_daily),
    total_daily: null,
    status: "active",
    created_by: operator.user_id,
    inserted_at: IN_WINDOW,
    updated_at: IN_WINDOW,
    ...over,
  };
}

function row(step, held, what, detail) {
  rows.push({ step, held: !!held, what, detail });
  console.log(`${held ? "held  " : "FAILED"} ${step}: ${what} — ${JSON.stringify(detail).slice(0, 2000)}`);
  return !!held;
}

const answers = [];
const ask = (request, options) => askRunSh(request, { outDir, timeoutMs: 240_000, answers, ...options });

const MATERIAL = () => [...KEYS, ...KEYS.map(sha256), typedDigest(AI), typedDigest(MAIL)];
const holdsKey = (text) => MATERIAL().some((secret) => String(text).includes(secret));
const pagePath = (segment, suffix) => `${base}/a/${encodeURIComponent(segment)}${suffix}`;
const words = (text) => String(text || "").replace(/\s+/g, " ").trim();

// A context signed in with the session cookie `cookie`, at the run's
// viewport.
async function signedIn(browser, cookie) {
  const context = await browser.newContext({ viewport });
  // The page's data-confirm controls ask the browser's native confirm; the
  // proof agrees to each one as its page asks it.
  context.on("page", (page) => page.on("dialog", (dialog) => dialog.accept()));
  await context.addCookies([{
    name: "_cyfr_key", value: cookie, url: base, httpOnly: true, secure: true, sameSite: "Lax",
  }]);
  return context;
}

async function open(page, url) {
  await page.goto(url);
  await page.waitForSelector(".phx-connected", { timeout: 30_000 });
}

// A flash the page shows, by its words.
const told = (page, text, timeout = 30_000) =>
  page.getByText(text, { exact: false }).first().waitFor({ timeout }).then(() => true).catch(() => false);

// What a page shows when a step does not hold: a screenshot beside the
// record, and the text of what it says in alerts and flashes. Neither key
// is on a page (each row checks), so neither is in what this keeps.
async function diagnose(page, name) {
  await page.screenshot({ path: join(outDir, `${name}.png`), fullPage: true }).catch(() => null);
  return page.evaluate(() =>
    [...document.querySelectorAll('[role="alert"], #flash-group, [id^="flash"]')]
      .map((el) => el.textContent.replace(/\s+/g, " ").trim()).filter(Boolean).slice(0, 10))
    .catch(() => []);
}

// The rows of a person's "Shared with you", by share id, each whole: all
// it says, and its parts by name, the destination, whose it is and the
// person's own use.
async function sharedWithYou(page) {
  await page.waitForSelector('[data-test="shared-with-you"]', { timeout: 30_000 });
  return page.$$eval('[data-test="shared-with-you-row"]', (els) => els.map((el) => {
    const text = (sel) => ((el.querySelector(sel) || { textContent: "" }).textContent || "").replace(/\s+/g, " ").trim();
    return {
      id: el.getAttribute("data-id"),
      text: el.textContent.replace(/\s+/g, " ").trim(),
      destination: text('[data-test="shared-destination"]'),
      by: text('[data-test="shared-by"]'),
      use: text('[data-test="shared-use"]'),
    };
  }));
}

// One "Shared with you" row as the person reads it, whole: the source's
// provider and kind, where it goes (its canonical destination as the
// request implied it, in one line), the owner, and the person's own use.
// A share's caps are its owner's, and the row says nothing of them.
function withYouRow(spec, shareId, implied, use) {
  const to = JSON.parse(implied.destination);
  const destination = `${to.scheme}://${to.hosts.join(", ")}` + (to.port ? `:${to.port}` : "") +
    (to.methods ? ` · ${to.methods.join(" ")}` : "") + (to.paths ? ` · ${to.paths.join(" ")}` : "");
  const by = `Shared by ${OWNER}`;
  const useText = `Your use: ${use}`;
  return {
    id: shareId, text: `${spec.provider} · api_key ${destination} ${by} ${useText}`, destination, by, use: useText,
  };
}

// The rows of the administrator's "Shared by you", by share id, with each
// row's status and its one line.
async function sharedByYou(page) {
  await page.waitForSelector('[data-test="shared-by-you"]', { timeout: 30_000 });
  return page.$$eval('[data-test="shared-by-you-row"]', (els) => els.map((el) => ({
    id: el.getAttribute("data-id"),
    status: el.getAttribute("data-status"),
    line: ((el.querySelector('[data-test="share-line"]') || { textContent: "" }).textContent || "")
      .replace(/\s+/g, " ").trim(),
  })));
}

const byYouRow = (id) => `[data-test="shared-by-you-row"][data-id="${id}"]`;

// Each entry's id by its name, as the Vault page's rows show them, once
// `count` rows are drawn.
async function entryIds(page, vault, count) {
  await open(page, vault);
  await page.waitForFunction((n) => document.querySelectorAll('[data-test="entry-name"]').length >= n, count,
    { timeout: 30_000 }).catch(() => null);
  const shown = await page.$$eval('[data-test="entry-name"]', (els) => els.map((el) => [
    (el.querySelector("span.font-medium") || { textContent: "" }).textContent.trim(), el.getAttribute("data-id"),
  ]));
  return Object.fromEntries(shown);
}

// The administrator's first passkey, made by the virtual authenticator and
// registered from the Settings page through the system layer's ceremony,
// within the first-method window of the sign-in.
async function registerPasskey(page, settings) {
  const authenticator = await virtualAuthenticator(page);
  await open(page, settings);
  await page.locator('[data-test="passkey-register"]').click({ timeout: 30_000 });
  const active = await page.waitForSelector('[data-test="passkey"][data-state="active"]', { timeout: 30_000 })
    .then(() => true).catch(() => false);
  const held = (await authenticator.credentials()).length;
  return { active, held };
}

// The page's own request waiting on its record, proven with the passkey.
async function proveOwn(page) {
  const panel = `${layer} [data-test="confirmation"][data-own="true"]`;
  const confirmation = await page.waitForSelector(panel, { timeout: 30_000 })
    .then((el) => el.innerText()).catch(() => "");
  await page.locator(`${panel} [data-test="confirm-passkey"]`).click({ timeout: 30_000 });
  return words(confirmation).slice(0, 300);
}

// A key made on the Vault page: its name, kind, label and destination and
// its one field typed in the create form, which the browser keeps and
// sends again once its credential_entry record is proven with the passkey.
// The form's fields but the key's are recorded.
async function createKey(page, vault, spec) {
  await open(page, vault);
  await page.locator('button[phx-click="show_add"][phx-value-mode="fields"]').click();
  const form = "#vault-create-form";
  await page.waitForSelector(form, { timeout: 30_000 });
  await page.locator(`${form} input[name="name"]`).fill(spec.name);
  await page.locator(`${form} select[name="kind"]`).selectOption("api_key");
  await page.locator(`${form} input[name="provider_hint"]`).fill(spec.provider);
  await page.locator(`${form} textarea[name="fields"]`).fill(`${FIELD}=${spec.key}`);
  await page.locator(`${form} input[name="destination_hosts"]`).fill(spec.hosts);
  await page.locator(`${form} input[name="destination_methods"]`).fill(spec.methods);
  await page.locator(`${form} input[name="destination_paths"]`).fill(spec.paths);
  const formFields = await page.$$eval(`${form} input, ${form} select`, (els) =>
    els.filter((el) => el.type !== "checkbox" && el.type !== "hidden").map((el) => [el.name, el.value]));
  const disclosed = await page.locator(`${form} input[name="disclose"]`).isChecked();
  await page.locator(`${form} button[type="submit"]`).click();
  const confirmation = await proveOwn(page);
  const created = await told(page, "Entry created.");
  const diagnosed = created ? [] : await diagnose(page, `create-${spec.provider}`);
  return {
    form: formFields, disclosed, created, confirmation, diagnosed, key_on_page: holdsKey(await page.content()),
  };
}

// A key shared with everyone through the system layer's sharing sheet: what
// the sheet offers and says before anything is chosen, then everyone and
// `spec`'s caps, its credential_sharing record proven with the passkey.
async function shareKey(page, vault, entryId, spec) {
  await open(page, vault);
  await page.locator(`[data-test="entry-share"][phx-value-id="${entryId}"]`).click({ timeout: 30_000 });
  const sheet = `${layer}[open] form#system-layer-share`;
  const asked = await page.waitForSelector(sheet, { timeout: 30_000 }).then(() => true).catch(() => false);
  if (!asked) return { asked, diagnosed: await diagnose(page, `share-${spec.provider}`) };
  const shown = await page.evaluate((selector) => {
    const form = document.querySelector(selector);
    const text = (sel) => [...form.querySelectorAll(sel)].map((el) => el.textContent.replace(/\s+/g, " ").trim());
    return {
      audiences: text('[data-test="share-audience"] label'),
      caps: [...form.querySelectorAll('input[type="number"]')].map((el) => [el.name, el.value]),
      meaning: text('[data-test="share-caps-meaning"]'),
      uncapped: text('[data-test="share-uncapped"]'),
      secret_inputs: form.querySelectorAll('input[type="password"], textarea').length,
    };
  }, sheet);
  await page.locator(`${sheet} input[name="audience"][value="everyone"]`).check();
  if (spec.person_daily !== "") await page.locator(`${sheet} input[name="person_daily"]`).fill(spec.person_daily);
  await page.locator(`${layer} [data-test="share-submit"]`).click();
  const confirmation = await proveOwn(page);
  const shared = await told(page, "Shared.");
  return { asked, shown, shared, confirmation, key_on_page: holdsKey(await page.content()) };
}

// The door's form on the Settings page, its value typed, then `action`
// (allow or deny) clicked once the button carries it.
async function door(page, settings, value, action) {
  await open(page, settings);
  await page.locator('form[phx-change="door_form_changed"] input[name="value"]').fill(value);
  const button = page.locator(`button[phx-click="door_${action}"][phx-value-door="${value}"]`);
  await button.waitFor({ timeout: 30_000 });
  await button.click();
  // Denying asks the page's own confirm first.
  return told(page, action === "allow" ? "Allowed." : "Denied.");
}

async function main() {
  const proxy = await startProxy(readHomes(homesFile));
  const browser = await launchBrowser("chromium", proxy);
  record.browser = browser.version();
  const admin = await (await signedIn(browser, adminCookie)).newPage();
  const frames = [];
  admin.on("websocket", (ws) => {
    ws.on("framesent", (f) => frames.push(String(f.payload).slice(0, 2000)));
  });
  const settings = pagePath(adminSegment, "/settings");
  const vault = pagePath(adminSegment, "/vault");
  let ai;
  let mail;
  let ana;
  let bea;
  let anaPage;

  try {
    // The proof's own model of everything the README names, changed at each
    // step only by what that step did: the administrator's vault entries,
    // the instance's entries, their listed members and their use (none),
    // the shares and their use, Ana's profiles, consents, binding rows,
    // offered entries and shares once she has signed in, and Bea's row once
    // she has. After every step the whole of it is compared with the whole
    // of what the home holds, in one read, every field through its class: a
    // change behind the browser to any of it fails the next step, whichever
    // step that is.
    const model = {
      vault_entries: [], entries: [], members: [], usage: [], shares: [], share_usage: [], ana: null, bea: null,
    };
    // The database's time as the run starts: the window every stored time
    // is held to opens here, before anything the proof names is made.
    const run = { start: (await ask({ op: "clock" })).now };
    record.run_start = run.start;
    let aiOver = {};
    let mailOver = {};
    let aiShareOver = {};
    let mailShareOver = {};
    let aiImplied;
    let mailImplied;
    let operator;
    const setModel = () => {
      model.vault_entries = [
        requestedEntry(AI, ai.id, aiImplied, operator.athanor_id, aiOver),
        requestedEntry(MAIL, mail.id, mailImplied, operator.athanor_id, mailOver),
      ];
      model.shares = [
        requestedShare(AI, ai.share, ai.id, operator, aiShareOver),
        requestedShare(MAIL, mail.share, mail.id, operator, mailShareOver),
      ];
    };
    const stateHolds = async () => {
      const state = await ask({
        op: "state", ana: ana ? ana.user_id : "", bea: bea ? bea.user_id : "",
        payloads: { [ai.id]: typedDigest(AI), [mail.id]: typedDigest(MAIL) },
      });
      const read = { start: run.start, now: state && state.now, today: state && state.today };
      const problems = [];
      const stored = storedState(state, read, problems);
      return {
        held: problems.length === 0 && same(stored, model),
        compared: { read, fields: problems, ...compared(stored, model) },
      };
    };
    // A use row of a share, in the administrator's athanor, as the model
    // holds it: the person's count, or the share's own total under the
    // empty id, on the database's today.
    const shareUse = (shareId, userId, count) => ({
      athanor_id: operator.athanor_id, share_id: shareId, user_id: userId, day: TODAY, count, updated_at: IN_WINDOW,
    });
    // `count` claims under Ana's context: of a share her head binds
    // (`share`), or of one held to the digest its source's request implies
    // and its one field, as a grant of it would bind it (`granted`).
    // `count` claims under the context Bea's request established and still
    // holds, of a share held to the digest its source's request implies and
    // its one field: what a deny must refuse though the request is already
    // in flight.
    const heldClaimOf = (shareId, spec, count, implied) =>
      ask({
        op: "held_claim", user_id: bea.user_id, id: shareId, count, url: spec.url, method: spec.method,
        digest: implied.binding_digest, field: FIELD,
      });
    const claimOf = (source, shareId, spec, count, implied) =>
      ask({
        op: "claim", user_id: ana.user_id, source, id: shareId, count, url: spec.url, method: spec.method,
        digest: implied ? implied.binding_digest : "-", field: implied ? FIELD : "-",
      });
    // A claim's whole answer: its results, and the database's next UTC
    // midnight, the value a cap's reset is compared with.
    const claimAnswer = (answer, results) =>
      same(answer, { results, next_utc_midnight: answer && answer.next_utc_midnight });
    const ids = (shown) => shown.map((o) => o.id);
    // What Shared by you reads, by id, as the model's shares and today's
    // use make it.
    const byYouLines = (lines) => lines.map(([id, status, line]) => ({ id, status, line }));

    // -----------------------------------------------------------------------
    // share_key
    // -----------------------------------------------------------------------
    const passkey = await registerPasskey(admin, settings);
    record.share_key = { passkey };
    const madeAi = await createKey(admin, vault, AI);
    record.share_key.ai = madeAi;
    const madeMail = await createKey(admin, vault, MAIL);
    record.share_key.mail = madeMail;
    operator = await ask({ op: "admin" });
    // What each request implies the owner stores, from the destination it
    // typed: the destination's canonical text and the digest over it.
    const impliedBy = (spec) => ask({
      op: "requested_digest", provider: spec.provider, field: FIELD, destination: requestedDestination(spec),
    });
    aiImplied = await impliedBy(AI);
    mailImplied = await impliedBy(MAIL);
    const shownIds = await entryIds(admin, vault, 2);
    ai = { id: shownIds[AI.name] };
    mail = { id: shownIds[MAIL.name] };
    const sharedAi = await shareKey(admin, vault, ai.id, AI);
    const sharedMail = await shareKey(admin, vault, mail.id, MAIL);
    await open(admin, vault);
    const madeShares = await sharedByYou(admin);
    const shareOf = (name) => (madeShares.find((s) => s.line.startsWith(`${name},`)) || {}).id;
    ai.share = shareOf(AI.name);
    mail.share = shareOf(MAIL.name);
    setModel();
    const sheetOpened = (made) => made.asked && same(made.shown, {
      audiences: ["Everyone on this CYFR"],
      caps: [["person_daily", ""], ["total_daily", ""]],
      meaning: [CAPS_MEANING],
      uncapped: [UNCAPPED],
      secret_inputs: 0,
    });
    const linesMade = byYouLines([
      [ai.share, "active", "Company AI, shared with everyone, 0 today, at most 3 a person a day"],
      [mail.share, "active", "Company Mail, shared with everyone, 0 today, no cap"],
    ]);
    const made = await stateHolds();
    record.share_key = {
      passkey, ai: madeAi, mail: madeMail, entries: shownIds, sheets: [sharedAi, sharedMail], shared_by_you: madeShares,
      state: made.compared,
    };
    if (!row("share_key",
      passkey.active && madeAi.created && madeMail.created && !madeAi.disclosed && !madeMail.disclosed &&
        !madeAi.key_on_page && !madeMail.key_on_page && Object.keys(shownIds).length === 2 &&
        sheetOpened(sharedAi) && sheetOpened(sharedMail) && sharedAi.shared && sharedMail.shared &&
        !sharedAi.key_on_page && !sharedMail.key_on_page && same(madeShares, linesMade) && made.held,
      "Company AI and Company Mail made on the Vault page, each key typed in its form and proven with the passkey, " +
        "each shared with everyone through the sheet, which opens with its caps empty and says what they mean, " +
        "proven with the passkey; Shared by you reads both; the whole state is the two entries and two shares " +
        "their forms requested",
      { passkey, entries: shownIds, sheets: [sharedAi.shown, sharedMail.shown], shared_by_you: madeShares,
        state: made.compared,
        confirmations: [madeAi.confirmation, madeMail.confirmation, sharedAi.confirmation, sharedMail.confirmation] })) {
      return;
    }

    // -----------------------------------------------------------------------
    // first_sign_in
    // -----------------------------------------------------------------------
    // The administrator opens the door to newcomers, which admits Ana and
    // Bea when they are made; Ana's first sign-in binds the share of the
    // key that fits the openai catalyst's need, Company AI's.
    const allowed = [await door(admin, settings, "*", "allow")];
    ana = await ask({ op: "sign_in", name: "ana", email: "ana@example.com" });
    // The loader's decision on her root names the profile and consent it
    // roots on: the ids the model takes for the profile and head the
    // bootstrap minted.
    const admitted = await ask({ op: "admit", user_id: ana.user_id });
    // What the bootstrap derives for that head from the request alone: the
    // policy blob's text, its digest, the activation, the shape and commit
    // digests, built by the owner's own builders, never read back.
    const derived = await ask({
      op: "derived_head", user_id: ana.user_id, share_id: ai.share,
      provider: AI.provider, field: FIELD, destination: requestedDestination(AI),
    });
    // One claim through the share her head binds, held to the digest and
    // the field it binds, is admitted and counted; the row binding reads
    // the share live as offered.
    const shareClaim = await claimOf("share", ai.share, AI, 1);
    const shareBinding = await ask({ op: "row_binding", user_id: ana.user_id, share_id: ai.share });
    // The admission's whole answer: its profile and consent are the ids the
    // model takes; the node and activation digest it verified for the
    // catalyst are the ones the bootstrap derives (the derived activation's
    // own text, never a stored one).
    const node = Object.entries(JSON.parse(derived.activation || "{}"))
      .find(([ref]) => ref === "catalyst:local.openai" || ref.startsWith("catalyst:local.openai:")) || [];
    const admission = {
      admitted: true, profile_id: admitted.profile_id, consent_id: admitted.consent_id,
      node_ref: node[0], node_digest: node[1],
    };
    anaPage = await (await signedIn(browser, ana.cookie)).newPage();
    await open(anaPage, pagePath(ana.segment, "/vault"));
    const shown = await sharedWithYou(anaPage);
    const anaHtml = await anaPage.content();
    // Her first sign-in mints one profile of the catalyst, Ana's own owner
    // default, active, headed by one consent: the bootstrap's first
    // revision, versionless, open and inert, made for Ana, admitting the
    // two origins a machine-minted revision admits (spelled as the store
    // writes them), with the policy blob, its digest, the activation and
    // the shape and commit digests the bootstrap derives from the request,
    // compared as stored text. The head holds one binding row, Company AI's
    // share on the catalyst's own default slot, standing, at the digest
    // Company AI's request implies; the share is used once by Ana, which
    // its entry's last use says; her vault offers no instance entry and
    // both shares, each by the administrator's name.
    model.ana = {
      profiles: [{
        id: admitted.profile_id,
        athanor_id: ana.athanor_id,
        source_ref: "catalyst:local.openai",
        kind: "owner",
        label: "default",
        status: "active",
        head_consent_id: admitted.consent_id,
        inserted_at: IN_WINDOW,
        updated_at: IN_WINDOW,
      }],
      consents: [{
        id: admitted.consent_id,
        athanor_id: ana.athanor_id,
        profile_id: admitted.profile_id,
        revision: 1,
        scope: "versionless",
        pinned_version: "",
        invoke_mode: "open_inert",
        granted_by: ana.user_id,
        granted_via: "bootstrap",
        granted_at: IN_WINDOW,
        admitted_origins: JSON.stringify(["interactive", "programmatic"]),
        resolved_policy: derived.resolved_policy,
        blob_digest: derived.blob_digest,
        activation: derived.activation,
        shape_digest: derived.shape_digest,
        commit_digest: derived.commit_digest,
      }],
      rows: [{
        consent_id: admitted.consent_id,
        athanor_id: ana.athanor_id,
        binding_key: "catalyst:local.openai|@ingress|default",
        scope: "share",
        vault_entry_id: null,
        instance_entry_id: null,
        share_id: ai.share,
        via_label: null,
        binding_digest: aiImplied.binding_digest,
        lifetime_kind: "standing",
        expires_at: null,
        consumed_by_root: null,
      }],
      offered: [],
      shared: [ai.share, mail.share],
    };
    aiOver = { ...aiOver, last_used_at: IN_WINDOW };
    setModel();
    model.share_usage = [shareUse(ai.share, ana.user_id, 1), shareUse(ai.share, "", 1)];
    const shownFirst = [
      withYouRow(AI, ai.share, aiImplied, "1 request today"),
      withYouRow(MAIL, mail.share, mailImplied, "none today"),
    ];
    const signed = await stateHolds();
    record.first_sign_in = {
      allowed, ana: { user_id: ana.user_id, segment: ana.segment }, admitted, derived, share_claim: shareClaim,
      share_binding: shareBinding, shown, state: signed.compared,
    };
    if (!row("first_sign_in",
      allowed.every(Boolean) && same(admitted, admission) && claimAnswer(shareClaim, [{ admitted: true }]) &&
        same(shareBinding, { row: true, offered: true }) && same(shown, shownFirst) &&
        !holdsKey(anaHtml) && signed.held,
      "Ana's first sign-in binds Company AI's share at bootstrap, the loader admits the root, a claim through the " +
        "share is admitted, its row binding reads offered, her vault's Shared with you offers both by the " +
        "administrator's name, no material; the whole state is the model",
      { admitted, share_claim: shareClaim, share_binding: shareBinding, shown, state: signed.compared })) return;

    // -----------------------------------------------------------------------
    // claim_cap
    // -----------------------------------------------------------------------
    const two = await claimOf("share", ai.share, AI, 2);
    await open(anaPage, pagePath(ana.segment, "/vault"));
    const cappedShown = await sharedWithYou(anaPage);
    const fourth = await claimOf("share", ai.share, AI, 1);
    // Each claim's whole answer, the fourth's reset the database's next UTC
    // midnight; the share's use is Ana's three and the day's three on the
    // database's today, no one else's and no other day. Her Shared with you
    // is compared whole: the owner and her own use, 3, and nothing of the
    // cap, which is the owner's (`share.offered` carries no cap).
    const twoAdmitted = [{ admitted: true }, { admitted: true }];
    const fourthRefused = [{ admitted: false, refusal: "connection_cap", reset_at: fourth.next_utc_midnight }];
    model.share_usage = [shareUse(ai.share, ana.user_id, 3), shareUse(ai.share, "", 3)];
    const shownCapped = [
      withYouRow(AI, ai.share, aiImplied, "3 requests today"),
      withYouRow(MAIL, mail.share, mailImplied, "none today"),
    ];
    const claimed = await stateHolds();
    record.claim_cap = { two, fourth, shown: cappedShown, state: claimed.compared };
    if (!row("claim_cap",
      claimAnswer(two, twoAdmitted) && claimAnswer(fourth, fourthRefused) && same(cappedShown, shownCapped) &&
        claimed.held,
      "two more claims admitted, the next refused with its reset at the next UTC midnight; her Shared with you, " +
        "compared whole, shows the owner and her use today, 3, and no cap; the whole state is the model",
      { two, fourth, shown: cappedShown, state: claimed.compared })) return;

    // -----------------------------------------------------------------------
    // narrow_audience
    // -----------------------------------------------------------------------
    // Bea signs in once and is seated with the administrator in a group,
    // Traders, which the narrowing names.
    bea = await ask({ op: "sign_in", name: "bea", email: "bea@example.com" });
    const traders = await ask({ op: "group", member: bea.user_id, name: "Traders" });
    await open(admin, vault);
    const audience = admin.locator(`${byYouRow(ai.share)} form[data-test="share-audience-form"]`);
    const offeredTraders = await audience.locator(`option[value="group:${traders.group_id}"]`)
      .waitFor({ state: "attached", timeout: 30_000 }).then(() => true).catch(() => false);
    await audience.locator('select[name="audience"]').selectOption(`group:${traders.group_id}`);
    const mark = frames.length;
    await audience.locator('[data-test="share-audience-save"]').click();
    const saved = await told(admin, "Audience saved.");
    const sent = frames.slice(mark).filter((f) => f.includes("share_audience"));
    const sentExpected = sent.some((f) => f.includes("expected_audience=everyone"));
    const narrowedLines = await sharedByYou(admin);
    const claim = await claimOf("share", ai.share, AI, 1);
    const rowBinding = await ask({ op: "row_binding", user_id: ana.user_id, share_id: ai.share });
    await open(anaPage, pagePath(ana.segment, "/vault"));
    const afterNarrow = await sharedWithYou(anaPage);
    // Bea's first sign-in leaves her row as the release fixture's person
    // is made and signs in (an open admission, her GitHub email verified,
    // "Release proof"), active, at security generation 1, her personal
    // athanor the one her sign-in names. Company AI's share is to Traders
    // alone, which Ana is not in: her claim of it is refused as not
    // offered, as is the row binding the loader reads, and her vault offers
    // Company Mail's share alone.
    model.bea = {
      user: {
        id: bea.user_id,
        email: "bea@example.com",
        email_verified: true,
        admission: "open",
        display_name: "Release proof",
        namespace: null,
        personal_athanor_id: bea.athanor_id,
        status: "active",
        security_generation: 1,
        prefs: "{}",
        first_seen_at: IN_WINDOW,
        last_seen_at: IN_WINDOW,
        denied_at: null,
        created_at: IN_WINDOW,
        updated_at: IN_WINDOW,
      },
      // Seated in Traders, she is offered Company AI's share, and Company
      // Mail's, which is to everyone.
      shared: [ai.share, mail.share],
    };
    aiShareOver = { ...aiShareOver, audience: "group", group_id: traders.group_id };
    setModel();
    model.ana.shared = [mail.share];
    const notOffered = [{ admitted: false, refusal: "not_offered" }];
    const rowNotOffered = { row: true, offered: false, refusal: "not_offered" };
    const linesNarrowed = byYouLines([
      [ai.share, "active", "Company AI, shared with Traders, 3 today, at most 3 a person a day"],
      [mail.share, "active", "Company Mail, shared with everyone, 0 today, no cap"],
    ]);
    const narrowedState = await stateHolds();
    record.narrow_audience = {
      traders, offered_traders: offeredTraders, saved, sent, shared_by_you: narrowedLines, claim, rowBinding,
      shown: afterNarrow, state: narrowedState.compared,
    };
    if (!row("narrow_audience",
      offeredTraders && saved && sentExpected && same(narrowedLines, linesNarrowed) && claimAnswer(claim, notOffered) &&
        same(rowBinding, rowNotOffered) && same(ids(afterNarrow), model.ana.shared) && narrowedState.held,
      "Company AI's share narrowed to Traders on Shared by you, sent with the audience the row showed: Ana's claim " +
        "refused, her row binding reads it not offered, her vault drops it; the whole state is the model",
      { sent_expected: sentExpected, shared_by_you: narrowedLines, claim, row_binding: rowBinding,
        shown: ids(afterNarrow), state: narrowedState.compared })) return;

    // -----------------------------------------------------------------------
    // revoke
    // -----------------------------------------------------------------------
    const before = await claimOf("granted", mail.share, MAIL, 1, mailImplied);
    await open(admin, vault);
    const revoke = admin.locator(`${byYouRow(mail.share)} [data-test="share-revoke"]`);
    await revoke.scrollIntoViewIfNeeded();
    const revokeMark = frames.length;
    await revoke.click();
    const revoked = await told(admin, "Share revoked.");
    const revokeShown = revoked ? [] :
      [...await diagnose(admin, "revoke"), { sent: frames.slice(revokeMark).filter((f) => f.includes("share_revoke")) }];
    const revokedLines = await sharedByYou(admin);
    const after = await claimOf("granted", mail.share, MAIL, 1, mailImplied);
    await open(anaPage, pagePath(ana.segment, "/vault"));
    const afterRevoke = await sharedWithYou(anaPage);
    const nothing = await told(anaPage, "No one shares a key with you.", 10_000);
    // The claim before is admitted and the one after refused as not
    // offered; Company Mail is used once by Ana, its share revoked, and her
    // vault offers nothing.
    const admittedOnce = [{ admitted: true }];
    mailOver = { ...mailOver, last_used_at: IN_WINDOW };
    mailShareOver = { ...mailShareOver, status: "revoked" };
    setModel();
    model.share_usage = [...model.share_usage, shareUse(mail.share, ana.user_id, 1), shareUse(mail.share, "", 1)];
    model.ana.shared = [];
    model.bea.shared = [ai.share];
    const linesRevoked = byYouLines([
      [ai.share, "active", "Company AI, shared with Traders, 3 today, at most 3 a person a day"],
      [mail.share, "revoked", "Company Mail, shared with everyone, revoked"],
    ]);
    const revokedState = await stateHolds();
    record.revoke = {
      before, revoked, revoke_page: revokeShown, shared_by_you: revokedLines, after, shown: afterRevoke, nothing,
      state: revokedState.compared,
    };
    if (!row("revoke",
      claimAnswer(before, admittedOnce) && revoked && same(revokedLines, linesRevoked) &&
        claimAnswer(after, notOffered) && same(ids(afterRevoke), model.ana.shared) && nothing && revokedState.held,
      "Company Mail's share, claimed just before, is revoked on Shared by you, which reads it revoked: Ana's next " +
        "claim is refused and her vault offers nothing; the whole state is the model",
      { before, after, shared_by_you: revokedLines, shown: ids(afterRevoke), state: revokedState.compared })) return;

    // -----------------------------------------------------------------------
    // deny_person
    // -----------------------------------------------------------------------
    // The control first: Bea, in Traders, is offered Company AI's share, and
    // a claim through it under the context her request holds is admitted
    // and counted, Bea's 1 beside Ana's 3, the day's 4.
    const beaBefore = await heldClaimOf(ai.share, AI, 1, aiImplied);
    model.share_usage = [
      shareUse(ai.share, ana.user_id, 3), shareUse(ai.share, bea.user_id, 1), shareUse(ai.share, "", 4),
      shareUse(mail.share, ana.user_id, 1), shareUse(mail.share, "", 1),
    ];
    const offeredState = await stateHolds();
    // A deny names the person, by her user id.
    const denied = await door(admin, settings, bea.user_id, "deny");
    // The same claim under the same held context is refused as hers, a
    // person who no longer stands, and counts nothing.
    const beaAfter = await heldClaimOf(ai.share, AI, 1, aiImplied);
    await open(admin, vault);
    const deniedLines = await sharedByYou(admin);
    // A deny commits three columns of her row together
    // (`Sanctum.Tenancy.Users`): denied, a denial time, and her security
    // generation one above the model's. A share's audience is read at use,
    // so nothing of a share is written; what she is offered is now the
    // refusal of a person who does not stand, and the use rows stand as
    // they were. Shared by you reads Company AI's use with hers.
    model.bea.user = {
      ...model.bea.user,
      status: "denied",
      denied_at: IN_WINDOW,
      security_generation: model.bea.user.security_generation + 1,
    };
    model.bea.shared = { refused: "denied" };
    const linesDenied = byYouLines([
      [ai.share, "active", "Company AI, shared with Traders, 4 today, at most 3 a person a day"],
      [mail.share, "revoked", "Company Mail, shared with everyone, revoked"],
    ]);
    const deniedState = await stateHolds();
    record.deny_person = {
      bea_before: beaBefore, offered_state: offeredState.compared, denied, bea_after: beaAfter,
      shared_by_you: deniedLines, state: deniedState.compared,
    };
    if (!row("deny_person",
      claimAnswer(beaBefore, [{ admitted: true }]) && offeredState.held && denied &&
        claimAnswer(beaAfter, [{ admitted: false, refusal: "denied" }]) && same(deniedLines, linesDenied) &&
        deniedState.held,
      "Bea, in Traders, is offered Company AI's share and her claim through it is admitted and counted; denied at " +
        "the door on the Settings page, she is offered nothing, the same claim is refused as denied and counts " +
        "nothing, and no share changes; the whole state is the model before and after",
      { bea_before: beaBefore, bea_after: beaAfter, shared_by_you: deniedLines, offered_state: offeredState.compared,
        state: deniedState.compared })) return;

    // -----------------------------------------------------------------------
    // admin_focus
    // -----------------------------------------------------------------------
    await open(admin, settings);
    // The switcher's popover, drawn: its own content (the new-group form it
    // always holds, beside a row for each athanor when there are several)
    // is waited for, so its links are read only once it shows them.
    const popover = 'div[phx-click-away="close_popover"]';
    await admin.locator("button", { has: admin.locator("#viewing-name") }).click();
    const drawn = await admin.locator(`${popover} form[phx-submit="create_group"]`)
      .waitFor({ timeout: 30_000 }).then(() => true).catch(() => false);
    const switcherLinks = await admin.$$eval(`${popover} a[href]`, (els) => els.map((el) => el.getAttribute("href")));
    const links = await admin.$$eval("a[href]", (els) => els.map((el) => el.getAttribute("href")));
    // A link into Ana's athanor: a path under her segment, spelled either
    // way, or a page that names her athanor as its `a` (the switcher's chat
    // rows); never a segment that only begins with hers.
    const anaRoutes = [`/a/${ana.segment}`, `/a/${encodeURIComponent(ana.segment)}`];
    const intoAna = (href) => {
      const url = new URL(href, base);
      return url.searchParams.get("a") === ana.segment ||
        anaRoutes.some((route) => url.pathname === route || url.pathname.startsWith(`${route}/`));
    };
    const listsAna = [...switcherLinks, ...links].some(intoAna);
    // The visit lands where the refusal sends it, which says what it says
    // of an athanor that does not exist.
    await admin.goto(pagePath(ana.segment, "/vault"));
    const refusedVisit = await told(admin, `There is no athanor at ${ana.segment}.`, 15_000);
    const landed = admin.url();
    const decision = await ask({ op: "focus", athanor_id: ana.athanor_id });
    const adminHtml = await admin.content();
    // Nothing the administrator did here changes anything the model holds.
    const focusedState = await stateHolds();
    record.admin_focus = {
      drawn, switcher_links: switcherLinks, links: links.filter((h) => h.startsWith("/a/")), lists_ana: listsAna,
      landed, refusedVisit, decision, state: focusedState.compared,
    };
    row("admin_focus",
      drawn && !listsAna && !intoAna(landed) && refusedVisit &&
        same(decision, { platform_admin: true, in_focus: operator.athanor_id, focus: "not_found", refocus: "not_found" }) &&
        !holdsKey(adminHtml) && focusedState.held,
      "the administrator's switcher lists no athanor of Ana's, a direct visit is refused, and the focus decision " +
        "refuses it; the whole state is the model",
      { lists_ana: listsAna, landed, refused_visit: refusedVisit, decision, state: focusedState.compared });
  } catch (error) {
    row(STEPS[rows.length] || "error", false, "the step ran to its end", String(error && error.stack || error));
  } finally {
    await browser.close();
    await proxy.close();
    const recorded = JSON.stringify({ rows, record }, null, 2);
    // No key, nor a digest of a key or of a typed payload, reached an
    // answer, the record or a question left in the output directory.
    const asks = readdirSync(outDir).filter((f) => f.startsWith("ask-"))
      .map((f) => readFileSync(join(outDir, f), "utf8"));
    const leaked = holdsKey(recorded) || answers.some(holdsKey) || asks.some(holdsKey);
    if (leaked) rows.push({ step: "material", held: false, what: "a key reached an answer or the record", detail: {} });
    writeFileSync(join(outDir, "instance-entry-proof.json"),
      JSON.stringify({ viewport: record.viewport, browser: record.browser, rows, record, material_in_answers: leaked }, null, 2));
    const table = [`Viewport: ${viewportName} (${viewport.width}×${viewport.height}), Chromium ${record.browser || "?"}`, "",
      "| Step | Held | What |", "|---|---|---|",
      ...rows.map((r) => `| \`${r.step}\` | ${r.held ? "held" : "FAILED"} | ${r.what} |`)].join("\n");
    writeFileSync(join(outDir, "instance-entry-proof.md"), table + "\n");
    console.log(table);
  }
}

main()
  .then(() => process.exit(rows.length === STEPS.length && rows.every((r) => r.held) ? 0 : 1))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
