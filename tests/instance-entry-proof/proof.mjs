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

import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
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
const REACHED = "Your daily limit is reached; it resets at midnight UTC.";

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

const holdsKey = (text) => KEYS.some((key) => String(text).includes(key));
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

async function entries() {
  return (await ask({ op: "entries" })).entries || [];
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
    // -----------------------------------------------------------------------
    // create_entry
    // -----------------------------------------------------------------------
    const passkey = await registerPasskey(admin, settings);
    const madeAi = await createEntry(admin, settings, AI);
    const madeMail = await createEntry(admin, settings, MAIL);
    const made = await entries();
    ai = made.find((e) => e.name === AI.name);
    mail = made.find((e) => e.name === MAIL.name);
    record.create_entry = { passkey, ai: madeAi, mail: madeMail, entries: made };
    if (!row("create_entry",
      passkey.active && madeAi.created && madeMail.created && !madeAi.key_on_page && !madeMail.key_on_page &&
        ai && ai.provider_hint === AI.provider && ai.kind === "api_key" && ai.audience === "everyone" &&
        ai.person_daily === 3 && ai.component_policy === "any" && ai.status === "active" && ai.sealed &&
        JSON.stringify(ai.destination.hosts) === JSON.stringify(["api.openai.com"]) &&
        JSON.stringify(ai.destination.paths) === JSON.stringify(["/v1/chat/completions", "/v1/models"]) &&
        mail && mail.provider_hint === MAIL.provider && mail.audience === "everyone" && mail.status === "active",
      "Company AI and Company Mail made on the card, each key typed in the prompt and proven with the passkey",
      { passkey, ai, mail, confirmations: [madeAi.confirmation, madeMail.confirmation] })) return;

    // -----------------------------------------------------------------------
    // first_sign_in
    // -----------------------------------------------------------------------
    const allowed = [
      await door(admin, settings, "ana@example.com", "allow"),
      await door(admin, settings, "bea@example.com", "allow"),
    ];
    ana = await ask({ op: "sign_in", name: "ana", email: "ana@example.com" });
    const binding = await ask({ op: "binding", user_id: ana.user_id, entry_id: ai.id });
    const admitted = await ask({ op: "admit", user_id: ana.user_id });
    anaPage = await (await signedIn(browser, ana.cookie)).newPage();
    await open(anaPage, pagePath(ana.segment, "/vault"));
    const shown = await offered(anaPage);
    const anaHtml = await anaPage.content();
    record.first_sign_in = { allowed, ana: { user_id: ana.user_id, segment: ana.segment }, binding, admitted, shown };
    if (!row("first_sign_in",
      allowed.every(Boolean) && binding.bound && binding.scope === "instance" && binding.digest_is_entry &&
        binding.revision === 1 && binding.lifetime === "standing" && binding.instance_rows === 1 &&
        admitted.admitted && admitted.consent_id === binding.consent_id &&
        shown.some((o) => o.id === ai.id) && shown.some((o) => o.id === mail.id) && !holdsKey(anaHtml),
      "Ana's first sign-in binds Company AI at bootstrap, the loader admits the root, and her vault offers both, no material",
      { binding, admitted, shown: shown.map((o) => o.id) })) return;

    // -----------------------------------------------------------------------
    // claim_cap
    // -----------------------------------------------------------------------
    const three = await ask({ op: "claim", user_id: ana.user_id, entry_id: ai.id, count: 3, url: AI.url, method: AI.method });
    await open(anaPage, pagePath(ana.segment, "/vault"));
    const capped = (await offered(anaPage)).find((o) => o.id === ai.id);
    const fourth = await ask({ op: "claim", user_id: ana.user_id, entry_id: ai.id, count: 1, url: AI.url, method: AI.method });
    const refused = fourth.results && fourth.results[0];
    record.claim_cap = { three, capped, fourth };
    if (!row("claim_cap",
      three.results.length === 3 && three.results.every((r) => r.admitted) && three.used_today === 3 &&
        capped && capped.text.includes("3 requests today") && capped.text.includes(REACHED) &&
        refused && refused.admitted === false && refused.refusal === "connection_cap" &&
        refused.reset_is_next_utc_midnight === true && fourth.used_today === 3,
      "three claims admitted, her vault says the limit is reached and resets at midnight UTC, the fourth refused at the next UTC midnight",
      { three: three.results, shown: capped && capped.text, fourth: refused, used_today: fourth.used_today })) return;

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
    const narrowed = (await entries()).find((e) => e.id === ai.id);
    const claim = await ask({ op: "claim", user_id: ana.user_id, entry_id: ai.id, count: 1, url: AI.url, method: AI.method });
    const rowBinding = await ask({ op: "row_binding", user_id: ana.user_id, entry_id: ai.id });
    await open(anaPage, pagePath(ana.segment, "/vault"));
    const afterNarrow = await offered(anaPage);
    record.narrow_audience = { listed, saved, sent, narrowed, claim, rowBinding, shown: afterNarrow };
    if (!row("narrow_audience",
      listed && saved && sentExpected && narrowed.audience === "listed" &&
        JSON.stringify(narrowed.members) === JSON.stringify([bea.user_id]) &&
        claim.results[0].admitted === false && claim.results[0].refusal === "not_offered" &&
        rowBinding.row && rowBinding.offered === false && rowBinding.refusal === "not_offered" &&
        !afterNarrow.some((o) => o.id === ai.id) && afterNarrow.some((o) => o.id === mail.id),
      "Company AI narrowed to Bea on the card, sent with the audience it showed: Ana's claim and row binding refused, her vault drops it",
      { sent_expected: sentExpected, narrowed, claim: claim.results[0], row_binding: rowBinding, shown: afterNarrow.map((o) => o.id) })) return;

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
    record.revoke = { before, revoked, revoke_page: revokeShown, after, shown: afterRevoke, nothing };
    if (!row("revoke",
      before.results[0].admitted && revoked && after.results[0].admitted === false &&
        after.results[0].refusal === "entry_unavailable" && after.results[0].status === "revoked" &&
        afterRevoke.length === 0 && nothing,
      "Company Mail, claimed just before, is revoked on the card: Ana's next claim is refused and her vault offers nothing",
      { before: before.results[0], after: after.results[0], shown: afterRevoke.map((o) => o.id) })) return;

    // -----------------------------------------------------------------------
    // deny_person
    // -----------------------------------------------------------------------
    const denied = await door(admin, settings, "bea@example.com", "deny");
    const left = (await entries()).find((e) => e.id === ai.id);
    const beaNow = await ask({ op: "standing", user_id: bea.user_id });
    await open(admin, settings);
    const audienceShown = await admin.locator(`${card(ai.id)} [data-test="instance-audience"]`).innerText()
      .catch(() => "");
    record.deny_person = { denied, left, bea: beaNow, card: audienceShown };
    if (!row("deny_person",
      denied && left.audience === "listed" && left.members.length === 0 &&
        beaNow.status === "denied" && beaNow.listed_in === 0 && /nobody listed/.test(audienceShown),
      "Bea denied at the door on the Settings page: Company AI's card lists no one, and no audience lists her",
      { left: { audience: left.audience, members: left.members }, bea: beaNow, card: audienceShown })) return;

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
    record.admin_focus = {
      drawn, switcher_links: switcherLinks, links: links.filter((h) => h.startsWith("/a/")), lists_ana: listsAna,
      landed, refusedVisit, decision,
    };
    row("admin_focus",
      drawn && !listsAna && !intoAna(landed) && refusedVisit &&
        decision.platform_admin === true && decision.focus === "not_member" && decision.refocus === "not_member" &&
        !holdsKey(adminHtml),
      "the administrator's switcher lists no athanor of Ana's, a direct visit is refused, and the focus decision refuses it",
      { lists_ana: listsAna, landed, refused_visit: refusedVisit, decision });
  } catch (error) {
    row(STEPS[rows.length] || "error", false, "the step ran to its end", String(error && error.stack || error));
  } finally {
    await browser.close();
    await proxy.close();
    const recorded = JSON.stringify({ rows, record }, null, 2);
    // No key reached a page, an answer or the record.
    const leaked = holdsKey(recorded) || answers.some(holdsKey);
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
