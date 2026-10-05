// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The instance-entry proof, run in the official Playwright image by run.sh
// against a `cyfr` release behind the harness's HTTPS front (README.md).
// The platform administrator, in Chromium, offers the instance's own
// entries from the Settings page; Ana, a member who signs in after, is
// offered them in her vault; Bea signs in once and is denied. Each step is
// one row of the record; the proof fails when a row does not hold, and
// stops at the first row a later one rests on.
//
//   create_entry     Company AI (openai.com, a person cap of 3) and Company
//                    Mail are made on the Settings card, each key typed in
//                    the system layer's prompt alone and its credential_entry
//                    confirmation proven with the administrator's passkey
//   first_sign_in    Ana's first sign-in provisions her athanor: its
//                    bootstrap binds Company AI on the openai catalyst, the
//                    real loader admits the root with no run started, and
//                    her vault offers both entries and shows no material
//   claim_cap        three claims of Company AI under Ana's context are
//                    admitted, her vault then says her daily limit is
//                    reached and resets at midnight UTC, and the fourth is
//                    refused with the database's next UTC midnight
//   narrow_audience  the administrator narrows Company AI to Bea on the
//                    card, which sends the audience it showed as expected:
//                    Ana's claim and her consent's row binding are refused,
//                    and her vault no longer offers it
//   revoke           Company Mail, claimed by Ana just before, is revoked
//                    on the card: her next claim is refused, and her vault
//                    offers nothing
//   deny_person      Bea is denied at the door on the Settings page: Company
//                    AI's card lists no one, and no audience lists her
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
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { launchBrowser, readHomes, sleep, startProxy, virtualAuthenticator } from "../browser/lib.mjs";

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

const STEPS = ["create_entry", "first_sign_in", "claim_cap", "narrow_audience", "revoke", "deny_person", "admin_focus"];
const { homes } = readHomes(homesFile);
const base = homes[0].origin;
const layer = "#system-layer-dialog";
const rows = [];
const record = { viewport: { name: viewportName, ...viewport } };

// The keys are this run's own, typed in the prompt and nowhere else; no
// page, answer or record may hold either.
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
// The digest of the payload document an entry's card typed, as its owner
// encodes one (`Sanctum.Vault.Payload`: version 3, the one field, no
// token bundle) in its canonical text; the fixture compares the stored
// payload with it. Neither it nor a digest of a key may reach a page, an
// answer or the record.
const typedDigest = (spec) => sha256(JSON.stringify(canonical({ v: 3, fields: { [FIELD]: spec.key } })));
const REACHED = "Your daily limit is reached; it resets at midnight UTC.";
// The field the key is typed under in the system layer's prompt.
const FIELD = "API_KEY";

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

// The destination an entry's card requested: every field it typed, as
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
//            the model holds: what a card's request implies the owner stores
//            (`requested_digest`), or what the first sign-in's bootstrap
//            derives from it (`derived_head`);
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
// digest of the payload document its card typed, the fixture unseals the
// stored payload as its owner does and answers only the outcome, so neither
// the material nor anything derived from it reaches the proof. Each outcome
// but a match is its own sentence.
const TYPED = "the value its card typed";
const PAYLOAD_OUTCOMES = {
  matches: TYPED,
  differs: "the stored payload unseals to another value than its card typed",
  does_not_unseal: "the stored payload does not unseal",
  absent: "no payload is stored where its card typed one",
};
const typedPayload = {
  class: "derived",
  from: "the digest of the payload document its card typed, compared inside the fixture",
  check: (value) => PAYLOAD_OUTCOMES[value] || { unexpected_payload_answer: typeof value },
};

const CARD = "its card on the Settings page shows";
const ADMISSION = "the loader's admission of Ana's root named";
const SIGN_IN = "the person's sign-in named";
const REQUESTED = "requested_digest, from the destination its card requested";
const DERIVED = "derived_head, built by the owner's builders from the installed catalyst and the request";

const FIELDS = {
  instance_entries: {
    id: minted(CARD),
    name: exact,
    kind: exact,
    provider_hint: exact,
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
    audience: exact,
    person_daily: exact,
    total_daily: exact,
    component_policy: exact,
    created_by: minted("the administrator's sign-in named"),
    inserted_at: clock,
    updated_at: clock,
  },
  instance_entry_members: {
    instance_entry_id: minted(CARD),
    user_id: minted(SIGN_IN),
    inserted_at: clock,
  },
  instance_entry_usage: {
    instance_entry_id: minted(CARD),
    user_id: minted(`${SIGN_IN}, or the empty id of the entry's own total`),
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
    supersedes_id: exact,
    admitted_origins: exact,
  },
  consent_vault_refs: {
    consent_id: minted(ADMISSION),
    athanor_id: minted(SIGN_IN),
    binding_key: exact,
    scope: exact,
    vault_entry_id: exact,
    instance_entry_id: minted(CARD),
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
    provider: exact,
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
// every entry, member and use row of the instance, Ana's profiles,
// consents, binding rows and offered entries, and Bea's row.
function storedState(state, read, problems) {
  const each = (table, rows) => (rows || []).map((r) => classified(table, r, read, problems));
  return {
    entries: each("instance_entries", state && state.entries),
    members: each("instance_entry_members", state && state.members),
    usage: each("instance_entry_usage", state && state.usage),
    ana: (state && state.ana) ? {
      profiles: each("profiles", state.ana.profiles),
      consents: each("consents", state.ana.consents),
      rows: each("consent_vault_refs", state.ana.rows),
      offered: state.ana.offered || [],
    } : null,
    bea: (state && state.bea) ? { user: classified("users", state.bea.user, read, problems) } : null,
  };
}

// The whole entry a card's request asks the store to hold: its id as its
// card shows it, the card's fields, the key's one field, what the request
// implies the owner stores (`requested_digest`: the destination's canonical
// text and the binding digest over it), the administrator who made it, the
// state a new entry starts in, the payload its card typed and its clock's
// times;
// `over` is what a later step changed.
function requestedEntry(spec, id, implied, adminId, over = {}) {
  return {
    id,
    name: spec.name,
    kind: "api_key",
    provider_hint: spec.provider,
    provenance: "user",
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
    audience: "everyone",
    person_daily: spec.person_daily === "" ? null : Number(spec.person_daily),
    total_daily: null,
    component_policy: "any",
    created_by: adminId,
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

const MATERIAL = () => [...KEYS, ...KEYS.map(sha256), typedDigest(AI), typedDigest(MAIL)];
const holdsKey = (text) => MATERIAL().some((secret) => String(text).includes(secret));
const pagePath = (segment, suffix) => `${base}/a/${encodeURIComponent(segment)}${suffix}`;

// A context signed in with the session cookie `cookie`, at the run's
// viewport.
async function signedIn(browser, cookie) {
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

// A flash the page shows, by its words.
const told = (page, words, timeout = 30_000) =>
  page.getByText(words, { exact: false }).first().waitFor({ timeout }).then(() => true).catch(() => false);

// The page's own confirm for a control marked data-confirm (app.js
// `showConfirmDialog`), agreed to: the change is sent once it is.
async function agree(page) {
  const confirm = page.locator("div.fixed.inset-0 button", { hasText: /^Confirm$/ });
  await confirm.waitFor({ timeout: 30_000 });
  await confirm.click();
}

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

// The rows of Ana's "Provided by this instance", by id, with their text.
async function offered(page) {
  await page.waitForSelector('[data-test="instance-offered"]', { timeout: 30_000 });
  return page.$$eval('[data-test="offered-entry"]', (els) =>
    els.map((el) => ({ id: el.getAttribute("data-id"), text: el.textContent.replace(/\s+/g, " ").trim() })));
}

// The entry's card on the Settings page.
const card = (id) => `[data-test="instance-entry"][data-id="${id}"]`;

// Each entry's id by its name, as the Settings page shows them on their
// cards.
async function cardIds(page, settings) {
  await open(page, settings);
  const shown = await page.$$eval('[data-test="instance-entry"]', (els) => els.map((el) => [
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

// The new-entry form's change round trip, answered: LiveView marks what a
// change event is in flight for until the server's reply is applied, and
// the reply redraws the form from what the server holds (a provider's
// prefill among it).
function changeAnswered(page) {
  return page.waitForFunction(
    () => !document.querySelector(
      "#instance-create.phx-change-loading, #instance-create .phx-change-loading, " +
        "#instance-create[data-phx-ref-loading], #instance-create [data-phx-ref-loading]"),
    null, { timeout: 10_000 },
  ).then(() => true).catch(() => false);
}

// One field of the new-entry form, typed and read back once the change it
// made is answered.
async function typeField(page, selector, value) {
  const field = page.locator(`#instance-create ${selector}`);
  for (let attempt = 0; attempt < 5; attempt++) {
    await field.fill(value);
    await changeAnswered(page);
    if ((await field.inputValue()) === value) return true;
  }
  return false;
}

// An instance entry made on the Settings card: everything but the key on
// the card, the key in the system layer's prompt alone, the record proven
// with the passkey.
async function createEntry(page, settings, entry) {
  await open(page, settings);
  const typed = [];
  typed.push(await typeField(page, "#instance-name", entry.name));
  typed.push(await typeField(page, "#instance-provider", entry.provider));
  typed.push(await typeField(page, 'input[name="destination_hosts"]', entry.hosts));
  typed.push(await typeField(page, 'input[name="destination_methods"]', entry.methods));
  typed.push(await typeField(page, 'input[name="destination_paths"]', entry.paths));
  typed.push(await typeField(page, 'input[name="person_daily"]', entry.person_daily));
  await page.locator('#instance-create input[name="audience"][value="everyone"]').check();
  await page.locator('#instance-create input[name="component_policy"][value="any"]').check();
  const cardFields = await page.$$eval("#instance-create input, #instance-create select", (els) =>
    els.filter((el) => el.type !== "radio" && el.type !== "checkbox" && el.type !== "hidden")
      .map((el) => [el.name, el.value]));
  await page.locator('#instance-create button[type="submit"]').click();

  const prompt = `${layer}[open] form#system-layer-credential[data-target="instance"]`;
  const asked = await page.waitForSelector(prompt, { timeout: 30_000 }).then(() => true).catch(() => false);
  if (!asked) return { asked, typed, cardFields };
  await page.locator(`${layer} #system-layer-secret`).fill(entry.key);
  await page.locator(`${layer} #system-layer-secret`).press("Enter");

  const panel = `${layer} [data-test="confirmation"][data-own="true"]`;
  const confirmation = await page.waitForSelector(panel, { timeout: 30_000 })
    .then((el) => el.innerText()).catch(() => "");
  await page.locator(`${panel} [data-test="confirm-passkey"]`).click({ timeout: 30_000 });
  const created = await told(page, "Instance entry created.");
  const html = await page.content();
  return {
    asked, typed, cardFields, created,
    confirmation: confirmation.replace(/\s+/g, " ").slice(0, 300),
    key_on_page: holdsKey(html),
  };
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
  if (action === "deny") await agree(page);
  return told(page, action === "allow" ? "Allowed." : "Denied.");
}

async function main() {
  const proxy = await startProxy(null, readHomes(homesFile));
  const browser = await launchBrowser("chromium", proxy);
  record.browser = browser.version();
  const admin = await (await signedIn(browser, adminCookie)).newPage();
  const frames = [];
  admin.on("websocket", (ws) => {
    ws.on("framesent", (f) => frames.push(String(f.payload).slice(0, 2000)));
  });
  const settings = pagePath(adminSegment, "/settings");
  let ai;
  let mail;
  let ana;
  let bea;
  let anaPage;

  try {
    // The proof's own model of everything the README names, changed at each
    // step only by what that step did: the instance's entries, their listed
    // members and their use, Ana's profiles, consents, binding rows and
    // offered entries once she has signed in, and Bea's row once she has.
    // After every step the whole of it is compared with the whole of what
    // the home holds, in one read, every field through its class: a change
    // behind the browser to any of it fails the next step, whichever step
    // that is.
    const model = { entries: [], members: [], usage: [], ana: null, bea: null };
    // The database's time as the run starts: the window every stored time
    // is held to opens here, before anything the proof names is made.
    const run = { start: (await ask({ op: "clock" })).now };
    record.run_start = run.start;
    let aiOver = {};
    let mailOver = {};
    let aiImplied;
    let mailImplied;
    let operator;
    const setEntries = () => {
      model.entries = [
        requestedEntry(AI, ai.id, aiImplied, operator.user_id, aiOver),
        requestedEntry(MAIL, mail.id, mailImplied, operator.user_id, mailOver),
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
    // A use row of the entry `entryId` as the model holds it: the person's
    // count, or the entry's own total under the empty id, on the database's
    // today.
    const use = (entryId, userId, count) =>
      ({ instance_entry_id: entryId, user_id: userId, day: TODAY, count, updated_at: IN_WINDOW });
    // A claim's whole answer: its results, and the database's next UTC
    // midnight, the value a cap's reset is compared with.
    const claimAnswer = (answer, results) =>
      same(answer, { results, next_utc_midnight: answer && answer.next_utc_midnight });
    const ids = (shown) => shown.map((o) => o.id);

    // -----------------------------------------------------------------------
    // create_entry
    // -----------------------------------------------------------------------
    const passkey = await registerPasskey(admin, settings);
    const madeAi = await createEntry(admin, settings, AI);
    const madeMail = await createEntry(admin, settings, MAIL);
    operator = await ask({ op: "admin" });
    // What each request implies the owner stores, from the destination it
    // typed: the destination's canonical text and the digest over it.
    const impliedBy = (spec) => ask({
      op: "requested_digest", provider: spec.provider, field: FIELD, destination: requestedDestination(spec),
    });
    aiImplied = await impliedBy(AI);
    mailImplied = await impliedBy(MAIL);
    const cards = await cardIds(admin, settings);
    ai = { id: cards[AI.name] };
    mail = { id: cards[MAIL.name] };
    setEntries();
    const created = await stateHolds();
    record.create_entry = { passkey, ai: madeAi, mail: madeMail, cards, state: created.compared };
    if (!row("create_entry",
      passkey.active && madeAi.created && madeMail.created && !madeAi.key_on_page && !madeMail.key_on_page &&
        Object.keys(cards).length === 2 && created.held,
      "Company AI and Company Mail made on the card, each key typed in the prompt and proven with the passkey; " +
        "the whole state is the two entries their cards requested",
      { passkey, cards, state: created.compared, confirmations: [madeAi.confirmation, madeMail.confirmation] })) return;

    // -----------------------------------------------------------------------
    // first_sign_in
    // -----------------------------------------------------------------------
    const allowed = [
      await door(admin, settings, "ana@example.com", "allow"),
      await door(admin, settings, "bea@example.com", "allow"),
    ];
    ana = await ask({ op: "sign_in", name: "ana", email: "ana@example.com" });
    // The loader's decision on her root names the profile and consent it
    // roots on: the ids the model takes for the profile and head the
    // bootstrap minted.
    const admitted = await ask({ op: "admit", user_id: ana.user_id });
    // What the bootstrap derives for that head from the request alone: the
    // policy blob's text, its digest, the activation, the shape and commit
    // digests, built by the owner's own builders, never read back.
    const derived = await ask({
      op: "derived_head", user_id: ana.user_id, entry_id: ai.id,
      provider: AI.provider, field: FIELD, destination: requestedDestination(AI),
    });
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
    const shown = await offered(anaPage);
    const anaHtml = await anaPage.content();
    // Her first sign-in mints one profile of the catalyst, Ana's own owner
    // default, active, headed by one consent: the bootstrap's first
    // revision, versionless, open and inert, made for Ana, admitting the
    // two origins a machine-minted revision admits (spelled as the store
    // writes them), with the policy blob, its digest, the activation and
    // the shape and commit digests the bootstrap derives from the request,
    // compared as stored text. The head holds one binding row, Company AI
    // on the catalyst's own default slot, standing, at the digest its
    // request implies; her vault offers both entries.
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
        supersedes_id: null,
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
        scope: "instance",
        vault_entry_id: null,
        instance_entry_id: ai.id,
        via_label: null,
        binding_digest: aiImplied.binding_digest,
        lifetime_kind: "standing",
        expires_at: null,
        consumed_by_root: null,
      }],
      offered: [ai.id, mail.id],
    };
    const signed = await stateHolds();
    record.first_sign_in = {
      allowed, ana: { user_id: ana.user_id, segment: ana.segment }, admitted, derived, shown, state: signed.compared,
    };
    if (!row("first_sign_in",
      allowed.every(Boolean) && same(admitted, admission) && same(ids(shown), model.ana.offered) &&
        !holdsKey(anaHtml) && signed.held,
      "Ana's first sign-in binds Company AI at bootstrap, the loader admits the root, her vault offers both, no material; " +
        "the whole state is the model",
      { admitted, shown: ids(shown), state: signed.compared })) return;

    // -----------------------------------------------------------------------
    // claim_cap
    // -----------------------------------------------------------------------
    const three = await ask({ op: "claim", user_id: ana.user_id, entry_id: ai.id, count: 3, url: AI.url, method: AI.method });
    await open(anaPage, pagePath(ana.segment, "/vault"));
    const cappedShown = await offered(anaPage);
    const capped = cappedShown.find((o) => o.id === ai.id);
    const fourth = await ask({ op: "claim", user_id: ana.user_id, entry_id: ai.id, count: 1, url: AI.url, method: AI.method });
    // Each claim's whole answer, the fourth's reset the database's next UTC
    // midnight; Company AI is used, and its use is Ana's three and the
    // day's three on the database's today, no one else's and no other day.
    const threeAdmitted = [{ admitted: true }, { admitted: true }, { admitted: true }];
    const fourthRefused = [{ admitted: false, refusal: "connection_cap", reset_at: fourth.next_utc_midnight }];
    aiOver = { ...aiOver, last_used_at: IN_WINDOW };
    setEntries();
    model.usage = [use(ai.id, ana.user_id, 3), use(ai.id, "", 3)];
    const claimed = await stateHolds();
    record.claim_cap = { three, fourth, shown: cappedShown, state: claimed.compared };
    if (!row("claim_cap",
      claimAnswer(three, threeAdmitted) && claimAnswer(fourth, fourthRefused) &&
        same(ids(cappedShown), model.ana.offered) &&
        capped && capped.text.includes("3 requests today") && capped.text.includes(REACHED) && claimed.held,
      "three claims admitted, her vault says the limit is reached and resets at midnight UTC, the fourth refused at " +
        "the next UTC midnight; the whole state is the model",
      { three, fourth, shown: capped && capped.text, state: claimed.compared })) return;

    // -----------------------------------------------------------------------
    // narrow_audience
    // -----------------------------------------------------------------------
    bea = await ask({ op: "sign_in", name: "bea", email: "bea@example.com" });
    await open(admin, settings);
    const form = `#instance-audience-${ai.id}`;
    await admin.locator(`${card(ai.id)} details > summary`).click();
    const picker = admin.locator(`${form} input[name="members[]"][value="${bea.user_id}"]`);
    const listed = await picker.waitFor({ timeout: 30_000 }).then(() => true).catch(() => false);
    await admin.locator(`${form} input[name="audience"][value="listed"]`).check();
    await picker.check();
    const mark = frames.length;
    await admin.locator(`${form} [data-test="instance-audience-save"]`).click();
    const saved = await told(admin, "Audience saved.");
    const sent = frames.slice(mark).filter((f) => f.includes("instance_audience"));
    const sentExpected = sent.some((f) => f.includes("audience_shown=everyone"));
    const claim = await ask({ op: "claim", user_id: ana.user_id, entry_id: ai.id, count: 1, url: AI.url, method: AI.method });
    const rowBinding = await ask({ op: "row_binding", user_id: ana.user_id, entry_id: ai.id });
    await open(anaPage, pagePath(ana.segment, "/vault"));
    const afterNarrow = await offered(anaPage);
    // Bea's first sign-in leaves her row as the release fixture's person
    // signs in (GitHub, verified, "Release proof"), active, at security
    // generation 1, her personal athanor the one her sign-in names. Company
    // AI is listed for Bea alone; Ana's claim and row binding are refused
    // as not offered, and her vault offers Company Mail alone.
    model.bea = {
      user: {
        id: bea.user_id,
        email: "bea@example.com",
        email_verified: true,
        provider: "github",
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
    };
    aiOver = { ...aiOver, audience: "listed" };
    setEntries();
    model.members = [{ instance_entry_id: ai.id, user_id: bea.user_id, inserted_at: IN_WINDOW }];
    model.ana.offered = [mail.id];
    const notOffered = [{ admitted: false, refusal: "not_offered" }];
    const rowRefused = { row: true, offered: false, refusal: "not_offered" };
    const narrowedState = await stateHolds();
    record.narrow_audience = {
      listed, saved, sent, claim, rowBinding, shown: afterNarrow, state: narrowedState.compared,
    };
    if (!row("narrow_audience",
      listed && saved && sentExpected && claimAnswer(claim, notOffered) && same(rowBinding, rowRefused) &&
        same(ids(afterNarrow), model.ana.offered) && narrowedState.held,
      "Company AI narrowed to Bea on the card, sent with the audience it showed: Ana's claim and row binding refused, " +
        "her vault drops it; the whole state is the model",
      { sent_expected: sentExpected, claim, row_binding: rowBinding, shown: ids(afterNarrow),
        state: narrowedState.compared })) return;

    // -----------------------------------------------------------------------
    // revoke
    // -----------------------------------------------------------------------
    const before = await ask({ op: "claim", user_id: ana.user_id, entry_id: mail.id, count: 1, url: MAIL.url, method: MAIL.method });
    await open(admin, settings);
    const revoke = admin.locator(`${card(mail.id)} button[phx-click="instance_revoke"]`);
    await revoke.scrollIntoViewIfNeeded();
    const revokeMark = frames.length;
    await revoke.click();
    await agree(admin);
    const revoked = await told(admin, "Entry revoked.");
    const revokeShown = revoked ? [] :
      [...await diagnose(admin, "revoke"), { sent: frames.slice(revokeMark).filter((f) => f.includes("instance_revoke")) }];
    const after = await ask({ op: "claim", user_id: ana.user_id, entry_id: mail.id, count: 1, url: MAIL.url, method: MAIL.method });
    await open(anaPage, pagePath(ana.segment, "/vault"));
    const afterRevoke = await offered(anaPage);
    const nothing = await told(anaPage, "This instance offers you no entry.", 10_000);
    // The claim before is admitted and the one after refused as revoked;
    // Company Mail is used once by Ana and revoked, and her vault offers
    // nothing.
    const admittedOnce = [{ admitted: true }];
    const refusedRevoked = [{ admitted: false, refusal: "entry_unavailable", status: "revoked" }];
    mailOver = { ...mailOver, status: "revoked", last_used_at: IN_WINDOW };
    setEntries();
    model.usage = [...model.usage, use(mail.id, ana.user_id, 1), use(mail.id, "", 1)];
    model.ana.offered = [];
    const revokedState = await stateHolds();
    record.revoke = {
      before, revoked, revoke_page: revokeShown, after, shown: afterRevoke, nothing, state: revokedState.compared,
    };
    if (!row("revoke",
      claimAnswer(before, admittedOnce) && revoked && claimAnswer(after, refusedRevoked) &&
        same(ids(afterRevoke), model.ana.offered) && nothing && revokedState.held,
      "Company Mail, claimed just before, is revoked on the card: Ana's next claim is refused and her vault offers " +
        "nothing; the whole state is the model",
      { before, after, shown: ids(afterRevoke), state: revokedState.compared })) return;

    // -----------------------------------------------------------------------
    // deny_person
    // -----------------------------------------------------------------------
    const denied = await door(admin, settings, "bea@example.com", "deny");
    await open(admin, settings);
    const audienceShown = await admin.locator(`${card(ai.id)} [data-test="instance-audience"]`).innerText()
      .catch(() => "");
    // A deny commits three columns of her row together
    // (`Sanctum.Tenancy.Users`): denied, a denial time, and her security
    // generation one above the model's; and it takes her out of Company
    // AI's audience, which then lists no one.
    model.bea.user = {
      ...model.bea.user,
      status: "denied",
      denied_at: IN_WINDOW,
      security_generation: model.bea.user.security_generation + 1,
    };
    model.members = [];
    const deniedState = await stateHolds();
    record.deny_person = { denied, card: audienceShown, state: deniedState.compared };
    if (!row("deny_person",
      denied && /nobody listed/.test(audienceShown) && deniedState.held,
      "Bea denied at the door on the Settings page: Company AI's card lists no one, and no audience lists her; " +
        "the whole state is the model",
      { card: audienceShown, state: deniedState.compared })) return;

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
    // The visit lands where the refusal sends it, which says so.
    await admin.goto(pagePath(ana.segment, "/vault"));
    const refusedVisit = await told(admin, "You are not a member of that athanor.", 15_000);
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
        same(decision, { platform_admin: true, in_focus: operator.athanor_id, focus: "not_member", refocus: "not_member" }) &&
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
