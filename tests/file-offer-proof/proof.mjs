// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The file-offer proof, run in the official Playwright image by run.sh
// against a `cyfr` release behind the harness's HTTPS front (README.md).
// Three people, each signed in in a Chromium context of their own at the
// run's viewport: the sender and the recipient sit together in one group,
// and the outsider sits in no athanor but their own. Every step a person
// takes is taken on the Files page and its topbar, as that person sees it.
// Each step is one row of the record; the proof fails when a row does not
// hold, and stops at the first row a later one rests on.
//
//   picker     the sender's picker lists the recipient alone, never the
//              outsider, each time it opens
//   offered    three offers of one file each, sent from the picker: each
//              row offered from the sender to the recipient; after each,
//              every snapshot offered so far holds its file's original
//              bytes; the sender's usage grown by each
//   notice     each offer reaches the recipient's open Files page, its
//              Inbox and the topbar's count, without a reload
//   edited     the sender edits the first offered original and saves it:
//              the store holds the edit, every snapshot its original
//   withdrawn  the sender withdraws the third before the recipient acts on
//              it, every open snapshot holding its original just before:
//              it leaves the recipient's page, nothing lands, and the
//              sender's usage returns by its snapshot
//   accepted   the recipient accepts the first into the default folder
//              the form shows, both open snapshots holding their originals
//              just before: it lands at data/inbox/<sender slug>/<offer
//              id>/<filename>, its bytes the original's at offer time, not
//              the edit; the sender's usage returns by the snapshot, and
//              the recipient's holds the file once, its custody released
//   declined   the recipient declines the second, its snapshot holding its
//              original just before: it ends declined, nothing lands, and
//              the sender's usage returns by it
//   outsider   the outsider's open Files page shows no offer at any step,
//              no offer row names them, the recipient's picker lists the
//              sender alone, and a picker edited in the sender's browser to
//              name the outsider is refused, writing nothing
//   storage    the storage counts over the whole run, step by step, as the
//              offer's lifecycle states
//
// A snapshot "holds its original" when the fixture, reading what is
// stored under the offer's `payloads/offers/<offer id>/` as the sender,
// finds that one file, of the original's size and SHA-256, computed from
// the bytes read there and compared with the bytes this proof uploaded,
// never with the digest the offer row records (`snapshotsHold`).
//
// The server's part of a step — writing the sender's files, and reading
// the rows, the storage counts, and the snapshots' and the accepted
// copy's digests — is run.sh's, asked for through OUT_DIR (`ask-N.json`,
// answered `answer-N.json`). OUT_DIR also holds run.sh's `setup.json`:
// the people, the group, the viewport and the cases shown elsewhere.
//
// Usage: node proof.mjs HOMES_FILE OUT_DIR SENDER_COOKIE RECIPIENT_COOKIE OUTSIDER_COOKIE

import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { launchBrowser, readHomes, sleep, startProxy, waitFor } from "../browser/lib.mjs";

const [homesFile, outDir, senderCookie, recipientCookie, outsiderCookie] = process.argv.slice(2);
if (!homesFile || !outDir || !senderCookie || !recipientCookie || !outsiderCookie) {
  console.error("usage: node proof.mjs HOMES_FILE OUT_DIR SENDER_COOKIE RECIPIENT_COOKIE OUTSIDER_COOKIE");
  process.exit(64);
}
mkdirSync(outDir, { recursive: true });

const setup = JSON.parse(readFileSync(join(outDir, "setup.json"), "utf8"));
const VIEWPORTS = { desktop: { width: 1280, height: 900 }, "720x720": { width: 720, height: 720 } };
const viewport = VIEWPORTS[setup.viewport];
if (!viewport) {
  console.error(`no viewport named ${JSON.stringify(setup.viewport)}: desktop or 720x720`);
  process.exit(64);
}

const { sender: SENDER, recipient: RECIPIENT, outsider: OUTSIDER } = setup.people;
const FOLDER = "data/reports";
const STEPS = ["picker", "offered", "notice", "edited", "withdrawn", "accepted", "declined", "outsider", "storage"];

// Each file is one line of ASCII of an exact length, so every count is
// exact and the editor carries it unchanged.
const line = (label, size) => (`${label} `.repeat(Math.ceil(size / (label.length + 1)))).slice(0, size - 1) + ".";
const ORIGINAL = {
  "alpha.txt": line("alpha, as it was offered", 1536),
  "beta.txt": line("beta, as it was offered", 2560),
  "gamma.txt": line("gamma, as it was offered", 3584),
};
const EDITED = line("alpha, edited by its sender after the offer", 1024);
const size = (text) => Buffer.byteLength(text, "utf8");
const sha256 = (text) => createHash("sha256").update(text, "utf8").digest("hex");

// The default folder of an offer from the sender, `data/inbox/<sender
// slug>`: the slug is their namespace when it is one storage path segment,
// their person id otherwise.
const segmentName = (name) => typeof name === "string" && name !== "" && name !== "." && name !== ".." &&
  !name.includes("/") && !name.includes("\\");
const SENDER_SLUG = segmentName(SENDER.namespace) ? SENDER.namespace : SENDER.user_id;
const INBOX = `data/inbox/${SENDER_SLUG}`;

const { homes } = readHomes(homesFile);
const base = homes[0].origin;
const rows = [];
const record = { viewport: { name: setup.viewport, ...viewport }, steps: {} };

function row(step, held, what, detail) {
  rows.push({ step, held: !!held, what, detail });
  console.log(`${held ? "held  " : "FAILED"} ${step}: ${what} — ${JSON.stringify(detail).slice(0, 4000)}`);
  return !!held;
}

let asked = 0;
async function ask(request, timeoutMs = 120_000) {
  const id = ++asked;
  const answer = join(outDir, `answer-${id}.json`);
  writeFileSync(join(outDir, `ask-${id}.part`), JSON.stringify(request));
  renameSync(join(outDir, `ask-${id}.part`), join(outDir, `ask-${id}.json`));
  const deadline = Date.now() + timeoutMs;
  while (!existsSync(answer)) {
    if (Date.now() > deadline) throw new Error(`run.sh never answered ${request.op}`);
    await sleep(100);
  }
  const answered = JSON.parse(readFileSync(answer, "utf8"));
  if (answered.error) throw new Error(`run.sh could not answer ${request.op}: ${answered.error}`);
  return answered;
}

// ---------------------------------------------------------------------------
// The people's pages
// ---------------------------------------------------------------------------

const filesUrl = (person, path = "") =>
  `${base}/a/${encodeURIComponent(person.segment)}/files${path ? `?p=${encodeURIComponent(path)}` : ""}`;

// A person's own browser context, signed in as their session's cookie, at
// the run's viewport.
async function personPage(browser, person, cookie) {
  const context = await browser.newContext({ viewport });
  await context.addCookies([{
    name: "_cyfr_key", value: cookie, url: base, httpOnly: true, secure: new URL(base).protocol === "https:",
    sameSite: "Lax",
  }]);
  const page = await context.newPage();
  const view = { person, context, page, loads: 0, marker: null };
  page.on("load", () => { view.loads += 1; });
  return view;
}

// The Files page at `path`, its socket joined and its offers read, then
// marked: a reload of the document drops the mark, a live update does not.
async function openFiles(view, path = "") {
  await view.page.goto(filesUrl(view.person, path));
  await view.page.waitForSelector(".phx-connected", { timeout: 30_000 });
  await view.page.waitForFunction(() => {
    const offers = document.querySelector("#files-offers");
    return offers && !/Loading\.\.\./.test(offers.textContent);
  }, null, { timeout: 30_000 });
  await view.page.waitForFunction(() => !document.querySelector("#files-page")?.textContent.includes("Loading..."),
    null, { timeout: 30_000 });
  view.marker = randomBytes(8).toString("hex");
  view.loads = 0;
  await view.page.evaluate((mark) => { window.__fileOfferProof = mark; }, view.marker);
}

// Whether the page is still the document `openFiles` marked.
async function sameDocument(view) {
  const mark = await view.page.evaluate(() => window.__fileOfferProof ?? null);
  return mark === view.marker && view.loads === 0;
}

// What the Files page shows of offers, and of the folder in view: the
// offers waiting in its Inbox (their files and the folder the accept form
// shows), the receipts still landing, the offers sent with their status
// and whether they can be withdrawn, the topbar's count, and the listing.
function shown(view) {
  return view.page.evaluate(() => {
    const text = (el) => (el ? el.textContent.replace(/\s+/g, " ").trim() : null);
    const visible = (el) => {
      if (!el) return false;
      const box = el.getBoundingClientRect();
      const style = getComputedStyle(el);
      return box.width > 0 && box.height > 0 && style.visibility !== "hidden" && style.display !== "none";
    };
    const offers = document.querySelector("#files-offers");
    const files = (el) => [...el.querySelectorAll("li")].map((li) => text(li.querySelector(".font-mono")));
    const badge = document.querySelector("#file-offers");
    return {
      inbox: [...offers.querySelectorAll('[id^="offer-"]')].map((el) => ({
        id: el.id.slice("offer-".length),
        files: files(el),
        from: text(el.querySelector("div > span")),
        folder: el.querySelector('input[name="folder"]')?.value ?? null,
      })),
      receipts: [...offers.querySelectorAll("[data-receipt]")].map((el) => ({
        id: el.getAttribute("data-receipt"), text: text(el),
      })),
      sent: [...offers.querySelectorAll('[id^="sent-"]')].map((el) => ({
        id: el.id.slice("sent-".length),
        files: files(el),
        to: text(el.querySelector("div > span")),
        status: text(el.querySelector("div > span.text-xs")),
        withdraw: !!el.querySelector('[phx-click="withdraw"]'),
      })),
      nothing_waiting: /Nothing is waiting for you\./.test(offers.textContent),
      nothing_sent: /You have sent no copies from this athanor\./.test(offers.textContent),
      unreadable: /could not be read/.test(offers.textContent),
      badge: badge ? { text: text(badge), visible: visible(badge) } : null,
      listing: [...document.querySelectorAll("#files-entries tr")].map((tr) => text(tr.querySelector("td span.font-mono"))),
    };
  });
}

// The flash the page answers an action with, matching `pattern` (and of
// `kind`, info or error, when one is named); then dismissed, as a person
// clicks it away.
async function flash(view, pattern, what, kind = null) {
  const found = await waitFor(async () => {
    const flashes = await view.page.evaluate(() => [...document.querySelectorAll('[id^="flash-"]')]
      .map((el) => ({ kind: el.id.slice("flash-".length), text: el.querySelector("span")?.textContent.trim() ?? "" })));
    return flashes.find((f) => pattern.test(f.text) && (kind === null || f.kind === kind)) ?? null;
  }, { what });
  await view.page.locator(`#flash-${found.kind}`).click({ timeout: 5_000 }).catch(() => {});
  return found;
}

// Tick `paths` in the listing, open the picker, and read who it offers.
async function openPicker(view, paths) {
  for (const path of paths) {
    await view.page.locator(`#files-entries input[type="checkbox"][phx-value-path="${path}"]`).check();
  }
  await view.page.waitForFunction((n) => document.querySelector("#files-selection")?.textContent.includes(`${n} selected`),
    paths.length, { timeout: 30_000 });
  await view.page.locator("#files-send-copy").click();
  await view.page.waitForSelector("#send-copy", { timeout: 30_000 });
  return view.page.evaluate(() => [...document.querySelectorAll('#send-copy-form input[name="to"]')]
    .map((input) => ({
      user_id: input.value,
      label: input.closest("label")?.textContent.replace(/\s+/g, " ").trim() ?? null,
    })));
}

async function closePicker(view) {
  await view.page.locator('#send-copy button[phx-click="close_picker"]').click();
  await view.page.waitForSelector("#send-copy", { state: "detached", timeout: 30_000 });
  await view.page.locator('#files-selection button[phx-click="clear_selection"]').click();
  await view.page.waitForSelector("#files-selection", { state: "detached", timeout: 30_000 });
}

// The text the open file shows, once it is `path`'s.
async function opened(view, path) {
  await view.page.locator(`#files-entries button[phx-click="open"][phx-value-path="${path}"]`).click();
  await view.page.waitForFunction((p) => document.querySelector("#files-open span.font-mono")?.textContent.trim() === p,
    path, { timeout: 30_000 });
  const content = await view.page.locator("#files-open pre").textContent({ timeout: 30_000 });
  return content;
}

async function closeFile(view) {
  await view.page.locator('#files-open button[phx-click="close"]').click();
  await view.page.waitForSelector("#files-open", { state: "detached", timeout: 30_000 });
}

// The rows, counts and bytes the server holds now.
const facts = () => ask({ op: "facts" });
const offerRows = (fact, offerId) => [...fact.outbox, ...fact.inbox].filter((r) => r.offer_id === offerId)
  .filter((r, i, all) => all.findIndex((o) => o.offer_id === r.offer_id && o.filename === r.filename) === i);
// Whether the snapshot of each offer of `names` holds exactly its file with
// the bytes this proof uploaded: what is stored under the offer's
// `payloads/offers/<offer id>/`, hashed by the fixture from the bytes read
// there, never the digest the offer row records.
function snapshotsHold(fact, offers, names) {
  const checked = names.map((name) => {
    const offerId = offers[name];
    const stored = fact.snapshot_files[offerId] ?? {};
    const file = stored[name];
    const bytes = !file ? "absent" : file.sha256 === sha256(ORIGINAL[name]) ? "the original" :
      file.sha256 === sha256(EDITED) ? "the sender's edit" : "other bytes";
    return {
      file: name, offer_id: offerId, stored: Object.keys(stored), bytes,
      size: file?.size ?? null, sha256: file?.sha256 ?? null, original_sha256: sha256(ORIGINAL[name]),
      held: Object.keys(stored).length === 1 && bytes === "the original" && file.size === size(ORIGINAL[name]),
    };
  });
  return { held: checked.length > 0 && checked.every((c) => c.held), checked };
}

// Whether the snapshot of an ended offer is gone: nothing stored under it.
const released = (fact, offerId) => fact.snapshots[offerId] === 0 &&
  Object.keys(fact.snapshot_files[offerId] ?? {}).length === 0;

// What a snapshot check shows, in a row's detail.
const hashed = (check) => check.checked.map((c) => `${c.file}: ${c.bytes}${c.held ? "" : ` (${c.sha256}, ${c.size} bytes, stored ${JSON.stringify(c.stored)})`}`);

const totals = (fact) => ({
  sender: fact.usage.sender.total, recipient: fact.usage.recipient.total, outsider: fact.usage.outsider.total,
});

// The outsider's page and rows, at every step: nothing offered, nothing
// listed, nothing counted.
const outsiderChecks = [];
async function checkOutsider(when, outsiderView, fact) {
  const seen = await shown(outsiderView);
  const check = {
    when,
    same_document: await sameDocument(outsiderView),
    page_inbox: seen.inbox.length,
    page_receipts: seen.receipts.length,
    page_sent: seen.sent.length,
    nothing_waiting: seen.nothing_waiting,
    nothing_sent: seen.nothing_sent,
    unreadable: seen.unreadable,
    badge: seen.badge,
    rows: fact.outsider_inbox.length + fact.outsider_outbox.length + fact.outsider_receipts.length,
    named: [...fact.outbox, ...fact.inbox].some((r) => r.recipient_user_id === OUTSIDER.user_id ||
      r.sender_user_id === OUTSIDER.user_id),
    usage: fact.usage.outsider.total,
  };
  check.held = check.same_document && check.page_inbox === 0 && check.page_receipts === 0 &&
    check.page_sent === 0 && check.nothing_waiting && check.nothing_sent && !check.unreadable &&
    check.badge === null && check.rows === 0 && !check.named &&
    (outsiderChecks.length === 0 || check.usage === outsiderChecks[0].usage);
  outsiderChecks.push(check);
  return check;
}

// The storage counts, step by step: what each person's whole tree holds,
// and what the step should have moved it by.
const timeline = [];
function counted(step, fact, expected, previous) {
  const now = totals(fact);
  const entry = { step, totals: now, moved: {}, expected, held: true };
  for (const who of ["sender", "recipient", "outsider"]) {
    entry.moved[who] = now[who] - previous[who];
    if (entry.moved[who] !== (expected[who] ?? 0)) entry.held = false;
  }
  entry.payloads = { sender: fact.usage.sender.payloads, recipient: fact.usage.recipient.payloads };
  entry.cap = { sender: fact.usage.sender.cap, recipient: fact.usage.recipient.cap, outsider: fact.usage.outsider.cap };
  timeline.push(entry);
  return entry;
}

async function main() {
  const proxy = await startProxy(null, readHomes(homesFile));
  const browser = await launchBrowser("chromium", proxy);
  record.browser = `Chromium ${browser.version()}`;
  record.at = new Date().toISOString();
  const sender = await personPage(browser, SENDER, senderCookie);
  const recipient = await personPage(browser, RECIPIENT, recipientCookie);
  const outsider = await personPage(browser, OUTSIDER, outsiderCookie);

  try {
    // -----------------------------------------------------------------------
    // The sender's originals, and each person's Files page open
    // -----------------------------------------------------------------------
    for (const [name, content] of Object.entries(ORIGINAL)) {
      await ask({ op: "file", path: `${FOLDER}/${name}`, content });
    }
    await openFiles(sender, FOLDER);
    await openFiles(recipient);
    await openFiles(outsider);
    const start = await facts();
    record.start = { facts: start, sender: await shown(sender), recipient: await shown(recipient) };
    let previous = totals(start);
    counted("start", start, {}, previous);
    const outsiderAtStart = await checkOutsider("start", outsider, start);
    if (start.outbox.length || start.inbox.length || start.receipts.length || !outsiderAtStart.held) {
      row("start", false, "the run began with an offer or a receipt already in place", { start, outsiderAtStart });
      return;
    }

    // -----------------------------------------------------------------------
    // picker, offered, notice
    // -----------------------------------------------------------------------
    const offers = {};
    const pickers = [];
    const notices = [];
    const offered = [];
    for (const [n, name] of Object.keys(ORIGINAL).entries()) {
      const path = `${FOLDER}/${name}`;
      const sentBefore = new Set((await shown(sender)).sent.map((s) => s.id));
      const picker = await openPicker(sender, [path]);
      pickers.push({ file: name, picker });
      if (!picker.some((p) => p.user_id === RECIPIENT.user_id)) {
        row("picker", false, "the sender's picker did not list the recipient", { pickers });
        return;
      }
      await sender.page.locator(`#send-copy-form input[name="to"][value="${RECIPIENT.user_id}"]`).check();
      await sender.page.locator('#send-copy-form button[type="submit"]').click();
      const said = await flash(sender, /^Offered a copy of /, `the sender's offer of ${name}`);
      const sent = await waitFor(async () => (await shown(sender)).sent.find((s) => !sentBefore.has(s.id)),
        { what: `the sender's offer of ${name} in Sent` });
      const offerId = sent.id;
      offers[name] = offerId;

      // The recipient's page, open since before the offer, shows it.
      const arrived = await waitFor(async () => {
        const seen = await shown(recipient);
        const entry = seen.inbox.find((o) => o.id === offerId);
        return entry && seen.badge && seen.badge.text === `${n + 1} ${n === 0 ? "offer" : "offers"}` ? { seen, entry } : null;
      }, { what: `the recipient's notice of ${name}` }).catch((error) => ({ error: error.message }));
      const recipientSeen = arrived.seen ?? await shown(recipient);
      notices.push({
        file: name, offer_id: offerId, same_document: await sameDocument(recipient),
        entry: arrived.entry ?? null, badge: recipientSeen.badge, waiting: recipientSeen.inbox.map((o) => o.id),
        error: arrived.error ?? null,
      });

      const fact = await facts();
      const rowsOf = offerRows(fact, offerId);
      offered.push({
        file: name, offer_id: offerId, flash: said.text, sent, rows: rowsOf, snapshot: fact.snapshots[offerId],
        snapshots: snapshotsHold(fact, offers, Object.keys(offers)),
        step: counted(`offer ${name}`, fact, { sender: size(ORIGINAL[name]) }, previous),
      });
      previous = totals(fact);
      await checkOutsider(`offer ${name}`, outsider, fact);
    }
    record.steps.picker = pickers;
    record.steps.offered = offered;
    record.steps.notice = notices;

    if (!row("picker",
      pickers.every(({ picker }) => picker.length === 1 && picker[0].user_id === RECIPIENT.user_id),
      "the sender's picker lists the recipient alone, never the outsider or the sender, each time it opens",
      { pickers: pickers.map(({ file, picker }) => ({ file, listed: picker })) })) return;

    const offeredHeld = offered.every((o) => {
      const [only] = o.rows;
      return o.rows.length === 1 && only.filename === o.file && only.status === "offered" &&
        only.size === size(ORIGINAL[o.file]) && only.digest === `sha256:${sha256(ORIGINAL[o.file])}` &&
        only.sender_user_id === SENDER.user_id && only.recipient_user_id === RECIPIENT.user_id &&
        o.snapshot === size(ORIGINAL[o.file]) && o.snapshots.held && o.step.held && o.sent.status === "waiting" &&
        o.sent.withdraw;
    }) && new Set(offered.map((o) => o.offer_id)).size === 3;
    if (!row("offered", offeredHeld,
      "three offers of one file each, sent from the picker: offered from the sender to the recipient; after each, every snapshot offered so far holds its file's original bytes, hashed where they are stored; the sender's usage grown by each",
      offered.map((o) => ({
        file: o.file, offer_id: o.offer_id, rows: o.rows.map((r) => `${r.filename} ${r.status} ${r.size}`),
        snapshot: o.snapshot, hashed: hashed(o.snapshots), sender_moved: o.step.moved.sender,
        expected: o.step.expected.sender, sent: o.sent.status,
      })))) return;

    row("notice",
      notices.every((n) => n.same_document && n.entry && n.entry.files.length === 1 && n.entry.files[0] === n.file &&
        n.badge && n.badge.visible && n.entry.folder === INBOX && !n.error),
      "each offer reaches the recipient's open Files page, its Inbox and the topbar's count, without a reload",
      notices.map((n) => ({
        file: n.file, same_document: n.same_document, files: n.entry?.files, from: n.entry?.from,
        folder: n.entry?.folder, badge: n.badge, error: n.error,
      })));

    // -----------------------------------------------------------------------
    // edited
    // -----------------------------------------------------------------------
    const alpha = `${FOLDER}/alpha.txt`;
    const before = await opened(sender, alpha);
    await sender.page.locator('#files-open button[phx-click="edit"]').click();
    await sender.page.locator('#files-editor textarea[name="content"]').fill(EDITED);
    await sender.page.locator('#files-editor button[type="submit"]').click();
    const saved = await flash(sender, /^Saved /, "the sender's save");
    await closeFile(sender);
    const after = await opened(sender, alpha);
    await closeFile(sender);
    const editFact = await facts();
    const editStep = counted("edit alpha.txt", editFact, { sender: size(EDITED) - size(ORIGINAL["alpha.txt"]) }, previous);
    const editSnapshots = snapshotsHold(editFact, offers, Object.keys(offers));
    previous = totals(editFact);
    await checkOutsider("edit alpha.txt", outsider, editFact);
    record.steps.edited = {
      before: sha256(before), after: sha256(after), saved, facts: editFact, step: editStep, snapshots: editSnapshots,
    };
    if (!row("edited",
      before === ORIGINAL["alpha.txt"] && after === EDITED && /alpha\.txt/.test(saved.text) &&
        editFact.snapshots[offers["alpha.txt"]] === size(ORIGINAL["alpha.txt"]) && editSnapshots.held &&
        editFact.usage.sender.data - start.usage.sender.data === size(EDITED) - size(ORIGINAL["alpha.txt"]) &&
        editStep.held && (await sameDocument(sender)),
      "the sender edits the offered original on the Files page; reopened, it reads the edit, and every snapshot still holds its original bytes",
      {
        opened_before: before === ORIGINAL["alpha.txt"] ? "the original" : before.slice(0, 60),
        reopened: after === EDITED ? "the edit" : after.slice(0, 60), saved: saved.text,
        snapshot: editFact.snapshots[offers["alpha.txt"]], hashed: hashed(editSnapshots),
        sender_moved: editStep.moved.sender,
      })) return;

    // -----------------------------------------------------------------------
    // withdrawn
    // -----------------------------------------------------------------------
    const gamma = offers["gamma.txt"];
    // Every snapshot still open, the third's included, just before the
    // withdrawal releases the third's.
    const beforeWithdraw = snapshotsHold(await facts(), offers, ["alpha.txt", "beta.txt", "gamma.txt"]);
    await sender.page.locator(`#sent-${gamma} button[phx-click="withdraw"]`).click();
    const withdrawnSaid = await flash(sender, /^Withdrawn/, "the sender's withdrawal");
    const senderSent = await waitFor(async () => {
      const entry = (await shown(sender)).sent.find((s) => s.id === gamma);
      return entry && entry.status === "withdrawn" ? entry : null;
    }, { what: "the withdrawn offer in Sent" }).catch(() => null);
    const left = await waitFor(async () => {
      const seen = await shown(recipient);
      return !seen.inbox.some((o) => o.id === gamma) && seen.badge?.text === "2 offers" ? seen : null;
    }, { what: "the withdrawn offer gone from the recipient's Inbox" }).catch(() => null);
    const withdrawFact = await facts();
    const withdrawStep = counted("withdraw gamma.txt", withdrawFact, { sender: -size(ORIGINAL["gamma.txt"]) }, previous);
    previous = totals(withdrawFact);
    await checkOutsider("withdraw gamma.txt", outsider, withdrawFact);
    const gammaRows = offerRows(withdrawFact, gamma);
    record.steps.withdrawn = {
      before: beforeWithdraw, flash: withdrawnSaid, sent: senderSent, recipient: left, facts: withdrawFact,
      step: withdrawStep,
    };
    if (!row("withdrawn",
      beforeWithdraw.held && gammaRows.length === 1 && gammaRows[0].status === "withdrawn" && senderSent &&
        !senderSent.withdraw &&
        left && (await sameDocument(recipient)) &&
        withdrawFact.receipts.every((r) => r.offer_id !== gamma) && released(withdrawFact, gamma) &&
        withdrawFact.custody[gamma] === 0 && withdrawStep.held &&
        offerRows(withdrawFact, offers["alpha.txt"])[0].status === "offered" &&
        offerRows(withdrawFact, offers["beta.txt"])[0].status === "offered",
      "the sender withdraws the third offer before the recipient acts on it, its snapshot holding the original's bytes until then: it leaves the recipient's open page, nothing lands, the sender's usage returns by its snapshot",
      {
        rows: gammaRows.map((r) => r.status), sender_sees: senderSent?.status, withdraw_left: senderSent?.withdraw,
        recipient_waiting: left?.inbox.map((o) => o.id), recipient_badge: left?.badge,
        hashed_before: hashed(beforeWithdraw), snapshot: withdrawFact.snapshots[gamma],
        sender_moved: withdrawStep.moved.sender,
      })) return;

    // -----------------------------------------------------------------------
    // accepted
    // -----------------------------------------------------------------------
    const alphaOffer = offers["alpha.txt"];
    const landedAt = `${INBOX}/${alphaOffer}/alpha.txt`;
    const form = await shown(recipient);
    const shownFolder = form.inbox.find((o) => o.id === alphaOffer)?.folder ?? null;
    // Both snapshots still open, just before the acceptance releases the
    // first's.
    const beforeAccept = snapshotsHold(await facts(), offers, ["alpha.txt", "beta.txt"]);
    await recipient.page.locator(`#accept-${alphaOffer} button[type="submit"]`).click();
    const acceptedSaid = await flash(recipient, /^Accepted into /, "the recipient's acceptance");
    const afterAccept = await waitFor(async () => {
      const seen = await shown(recipient);
      return !seen.inbox.some((o) => o.id === alphaOffer) && seen.badge?.text === "1 offer" ? seen : null;
    }, { what: "the accepted offer gone from the recipient's Inbox" }).catch(() => null);
    const senderSaw = await waitFor(async () => {
      const entry = (await shown(sender)).sent.find((s) => s.id === alphaOffer);
      return entry && entry.status === "accepted" ? entry : null;
    }, { what: "the accepted offer in the sender's Sent" }).catch(() => null);
    const acceptFact = await facts();
    const acceptStep = counted("accept alpha.txt", acceptFact,
      { sender: -size(ORIGINAL["alpha.txt"]), recipient: size(ORIGINAL["alpha.txt"]) }, previous);
    previous = totals(acceptFact);
    await checkOutsider("accept alpha.txt", outsider, acceptFact);
    const receipts = acceptFact.receipts.filter((r) => r.offer_id === alphaOffer);
    const landed = acceptFact.landed.find((l) => l.offer_id === alphaOffer) ?? null;
    const liveAccept = await sameDocument(recipient);

    // The recipient opens what landed.
    await openFiles(recipient, `${INBOX}/${alphaOffer}`);
    const landedListing = (await shown(recipient)).listing;
    const landedShown = await opened(recipient, landedAt);
    await closeFile(recipient);
    record.steps.accepted = {
      before: beforeAccept, shown_folder: shownFolder, flash: acceptedSaid, recipient: afterAccept, sender: senderSaw, facts: acceptFact,
      step: acceptStep, listing: landedListing, landed_shown: sha256(landedShown),
    };
    if (!row("accepted",
      beforeAccept.held && shownFolder === INBOX && acceptedSaid.text === `Accepted into ${INBOX}/${alphaOffer}/` &&
        afterAccept && liveAccept &&
        senderSaw && !senderSaw.withdraw &&
        offerRows(acceptFact, alphaOffer).every((r) => r.status === "accepted") &&
        receipts.length === 1 && receipts[0].status === "completed" && receipts[0].attempt_path === landedAt &&
        landed && landed.path === landedAt && landed.size === size(ORIGINAL["alpha.txt"]) &&
        landed.sha256 === sha256(ORIGINAL["alpha.txt"]) && landed.sha256 !== sha256(EDITED) &&
        landedShown === ORIGINAL["alpha.txt"] &&
        JSON.stringify(landedListing) === JSON.stringify(["alpha.txt"]) &&
        released(acceptFact, alphaOffer) && acceptFact.custody[alphaOffer] === 0 &&
        acceptFact.usage.recipient.payloads === start.usage.recipient.payloads && acceptStep.held,
      "the recipient accepts the first offer into the folder the form shows: it lands at data/inbox/<sender slug>/<offer id>/alpha.txt holding the original's bytes at offer time, not the edit; the sender's usage returns by the snapshot, and the recipient's holds the file once, its custody released",
      {
        hashed_before: hashed(beforeAccept), folder_shown: shownFolder, flash: acceptedSaid.text,
        expected_path: landedAt,
        receipt: receipts.map((r) => ({ status: r.status, attempt_path: r.attempt_path })),
        landed: landed && { path: landed.path, size: landed.size, sha256: landed.sha256 },
        landed_bytes: !landed ? "none" : landed.sha256 === sha256(ORIGINAL["alpha.txt"]) ? "the original at offer time" :
          landed.sha256 === sha256(EDITED) ? "the sender's later edit" : "neither the original nor the edit",
        original_sha256: sha256(ORIGINAL["alpha.txt"]), edited_sha256: sha256(EDITED),
        recipient_opened: landedShown === ORIGINAL["alpha.txt"] ? "the original" :
          landedShown === EDITED ? "the edit" : landedShown.slice(0, 60),
        snapshot: acceptFact.snapshots[alphaOffer], custody: acceptFact.custody[alphaOffer],
        sender_moved: acceptStep.moved.sender, recipient_moved: acceptStep.moved.recipient,
        sender_sees: senderSaw?.status,
      })) return;

    // -----------------------------------------------------------------------
    // declined
    // -----------------------------------------------------------------------
    const beta = offers["beta.txt"];
    // The second's snapshot, the one still open, just before the decline
    // releases it.
    const beforeDecline = snapshotsHold(await facts(), offers, ["beta.txt"]);
    await recipient.page.locator(`#offer-${beta} button[phx-click="decline"]`).click();
    const declinedSaid = await flash(recipient, /^Declined/, "the recipient's decline");
    const afterDecline = await waitFor(async () => {
      const seen = await shown(recipient);
      return seen.inbox.length === 0 && seen.nothing_waiting && seen.badge === null ? seen : null;
    }, { what: "the recipient's Inbox empty" }).catch(() => null);
    const senderSawDecline = await waitFor(async () => {
      const entry = (await shown(sender)).sent.find((s) => s.id === beta);
      return entry && entry.status === "declined" ? entry : null;
    }, { what: "the declined offer in the sender's Sent" }).catch(() => null);
    const declineFact = await facts();
    const declineStep = counted("decline beta.txt", declineFact, { sender: -size(ORIGINAL["beta.txt"]) }, previous);
    previous = totals(declineFact);
    await checkOutsider("decline beta.txt", outsider, declineFact);
    await openFiles(recipient, INBOX);
    const inboxListing = (await shown(recipient)).listing;
    const senderEnd = await shown(sender);
    record.steps.declined = {
      before: beforeDecline, flash: declinedSaid, recipient: afterDecline, sender: senderEnd, facts: declineFact, step: declineStep,
      inbox_listing: inboxListing,
    };
    const statusOf = (id) => senderEnd.sent.find((s) => s.id === id)?.status ?? null;
    if (!row("declined",
      beforeDecline.held && offerRows(declineFact, beta).every((r) => r.status === "declined") && afterDecline &&
        senderSawDecline && declineFact.receipts.every((r) => r.offer_id === alphaOffer) && released(declineFact, beta) &&
        declineFact.custody[beta] === 0 && declineStep.held &&
        JSON.stringify(inboxListing) === JSON.stringify([`${alphaOffer}/`]) &&
        statusOf(alphaOffer) === "accepted" && statusOf(beta) === "declined" && statusOf(gamma) === "withdrawn" &&
        senderEnd.sent.every((s) => !s.withdraw) && (await sameDocument(sender)),
      "the recipient declines the second offer, its snapshot holding the original's bytes until then: it ends declined, nothing lands for it or the withdrawn one, and the sender's usage returns by its snapshot",
      {
        hashed_before: hashed(beforeDecline), rows: offerRows(declineFact, beta).map((r) => r.status),
        flash: declinedSaid.text,
        recipient_inbox_folder: inboxListing, sender_sees: senderEnd.sent.map((s) => `${s.files.join(",")} ${s.status}`),
        snapshot: declineFact.snapshots[beta], sender_moved: declineStep.moved.sender,
        recipient_moved: declineStep.moved.recipient,
      })) return;

    // -----------------------------------------------------------------------
    // outsider
    // -----------------------------------------------------------------------
    // The recipient's picker, from the copy that landed.
    await openFiles(recipient, `${INBOX}/${alphaOffer}`);
    const recipientPicker = await openPicker(recipient, [landedAt]);
    await closePicker(recipient);

    // A picker edited in the sender's browser to name the outsider.
    const senderPicker = await openPicker(sender, [`${FOLDER}/beta.txt`]);
    const sentBeforeForged = (await shown(sender)).sent.map((s) => s.id);
    await sender.page.evaluate((outsiderId) => {
      const form = document.getElementById("send-copy-form");
      for (const input of form.querySelectorAll('input[name="to"]')) input.checked = false;
      const forged = document.createElement("input");
      forged.type = "radio";
      forged.name = "to";
      forged.value = outsiderId;
      forged.checked = true;
      form.prepend(forged);
    }, OUTSIDER.user_id);
    await sender.page.locator('#send-copy-form button[type="submit"]').click();
    // The refusal names the person the submission carried, so it shows the
    // outsider's id reached the server and was refused there.
    const notShared = `You share no athanor with ${OUTSIDER.user_id} — an offer goes to someone you share an athanor with`;
    const refused = await flash(sender, /./, "the refusal of the edited picker", "error").catch(() => null);
    const sentAfterForged = (await shown(sender)).sent.map((s) => s.id);
    await closePicker(sender);
    const forgedFact = await facts();
    const forgedStep = counted("an offer to the outsider, refused", forgedFact, {}, previous);
    previous = totals(forgedFact);
    const outsiderAtEnd = await checkOutsider("end", outsider, forgedFact);
    record.steps.outsider = {
      checks: outsiderChecks, recipient_picker: recipientPicker, sender_picker: senderPicker, refused,
      sent_before: sentBeforeForged, sent_after: sentAfterForged, facts: forgedFact, step: forgedStep,
    };
    row("outsider",
      outsiderChecks.every((c) => c.held) && outsiderAtEnd.held &&
        recipientPicker.length === 1 && recipientPicker[0].user_id === SENDER.user_id &&
        senderPicker.length === 1 && senderPicker[0].user_id === RECIPIENT.user_id &&
        refused && refused.text === notShared &&
        JSON.stringify(sentAfterForged) === JSON.stringify(sentBeforeForged) &&
        forgedFact.outbox.length === 3 && forgedStep.held,
      "the outsider's open Files page shows no offer at any step and no row names them; the recipient's picker lists the sender alone; a picker edited to name the outsider is refused and writes nothing",
      {
        outsider_page: outsiderChecks.map((c) => `${c.when}: ${c.held ? "nothing" : JSON.stringify(c)}`),
        recipient_picker: recipientPicker, sender_picker: senderPicker,
        edited_picker: refused ? `${refused.kind}: ${refused.text}` : "no answer",
        expected_refusal: notShared,
        offers_after: forgedFact.outbox.length, sender_moved: forgedStep.moved.sender,
      });

    // -----------------------------------------------------------------------
    // storage
    // -----------------------------------------------------------------------
    const end = totals(forgedFact);
    const first = totals(start);
    record.steps.storage = timeline;
    row("storage",
      timeline.every((t) => t.held) &&
        end.sender - first.sender === size(EDITED) - size(ORIGINAL["alpha.txt"]) &&
        end.recipient - first.recipient === size(ORIGINAL["alpha.txt"]) && end.outsider === first.outsider &&
        forgedFact.usage.sender.payloads === start.usage.sender.payloads &&
        forgedFact.usage.recipient.payloads === start.usage.recipient.payloads,
      "each person's whole tree, as the storage cap counts it, moved by each step as the offer's lifecycle states, and no snapshot or custody copy is left",
      timeline.map((t) => `${t.step}: ${["sender", "recipient", "outsider"].map((w) => `${w} ${t.moved[w] >= 0 ? "+" : ""}${t.moved[w]} (expected ${t.expected[w] ?? 0})`).join(", ")}${t.held ? "" : " FAILED"}`));
  } catch (error) {
    console.error(error);
    for (const view of [sender, recipient, outsider]) {
      await view.page.screenshot({ path: join(outDir, `${view.person === SENDER ? "sender" : view.person === RECIPIENT ? "recipient" : "outsider"}.png`), fullPage: true }).catch(() => {});
    }
    rows.push({ step: "error", held: false, what: "the proof stopped on an error", detail: String(error && error.stack || error) });
  } finally {
    await browser.close();
    await proxy.close();
    const result = {
      viewport: record.viewport,
      browser: record.browser,
      at: record.at,
      people: setup.people,
      group: setup.group,
      rows,
      shown_elsewhere: setup.shown_elsewhere,
      record,
    };
    writeFileSync(join(outDir, "file-offer-proof.json"), JSON.stringify(result, null, 2));
    const table = [
      `Viewport: \`${setup.viewport}\` (${viewport.width}×${viewport.height}), ${record.browser ?? "Chromium"}, ${record.at ?? ""}.`,
      "",
      "| Step | Held | What |",
      "|---|---|---|",
      ...rows.map((r) => `| \`${r.step}\` | ${r.held ? "held" : "FAILED"} | ${r.what} |`),
      "",
      "Shown elsewhere (not run by this proof):",
      "",
      "| Claim | Test file | Test name | Owner |",
      "|---|---|---|---|",
      ...setup.shown_elsewhere.map((s) => `| ${s.claim} | \`${s.file}\` (line ${s.line}) | \`${s.test}\` | ${s.owner} |`),
    ].join("\n");
    writeFileSync(join(outDir, "file-offer-proof.md"), table + "\n");
    console.log(table);
  }
}

main()
  .then(() => process.exit(rows.length === STEPS.length && rows.every((r, i) => r.held && r.step === STEPS[i]) ? 0 : 1))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
