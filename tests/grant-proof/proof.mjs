// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The grant proof, run in the official Playwright image by run.sh against a
// `cyfr` release behind the harness's HTTPS front (README.md). One person,
// in Chromium, grants the tincture grant-probe on the console's Components
// page. Each step is one row of the record; the proof fails when a row does
// not hold, and stops at the first row a later one rests on.
//
//   prism_grant  the first text of the grant prompt's accessible
//                description in Chromium's tree, with keyboard focus inside
//                the prompt; the grant made in Prism's system layer, one
//                host narrowed away and interactive the one origin
//                admitted: the head holds exactly that, every field of it,
//                under the shape the version's plan asks
//   cli_digest   the same decisions previewed from the command line answer
//                the commit digest the head was committed under
//   background   a version asking to keep running when hidden: the person's
//                run is asked to grant again, and the sheet shows the
//                background row; granted, the head is the first head one
//                revision on, under the version's shape and the digest the
//                command line previews for what the re-grant commits
//   reworded     a version that only rewords its need's reason: the same
//                shape digest, and the run is admitted under the grant it
//                had, nothing asked
//   flows        a version that lets one more class reach the host it keeps:
//                the person's run is asked to grant again, the sheet shows
//                that exit with the class unticked; ticked and granted, the
//                head holds the flow, under the digest the command line
//                previews for the same decisions
//   revocation   the profile revoked in the console: the next admission is
//                refused for want of a profile, timed from the revocation's
//                answer, and the answer is held whole
//
// The server's part of a step — publishing a version, reading the head and
// the plan, an admission, the revocation and the command line's preview —
// is run.sh's, asked for through OUT_DIR (`ask-N.json`, answered
// `answer-N.json`).
//
// Usage: node proof.mjs HOMES_FILE SEGMENT COOKIE OUT_DIR

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  ask as askRunSh, launchBrowser, pageTokens, readHomes, recordText, redact, redactFrames, signedIn, startProxy, waitFor,
} from "../browser/lib.mjs";
import {
  REVOKE_BOUND_US, changedCopies, digestCopies, flowsHeld, grantedHeld, previewCopies, previewHeld, regrantHeld,
  revokedHeld, sameHead, sameSet,
} from "./heads.mjs";

const [homesFile, segment, cookie, outDir] = process.argv.slice(2);
if (!homesFile || !segment || !cookie || !outDir) {
  console.error("usage: node proof.mjs HOMES_FILE SEGMENT COOKIE OUT_DIR");
  process.exit(64);
}
mkdirSync(outDir, { recursive: true });

const NAME = "grant-probe";
const REF = `tincture:local.${NAME}`;
const KEPT = "alpha.grant.test";
const DROPPED = "beta.grant.test";
const PICKED = "data/probe/notes/";
// The first words of the grant prompt's own description
// (`PrismWeb.SystemLayer`), which its dialog is described by.
const GRANT_DESCRIBED = "Approve what this app may use and reach";
// What the loader answers once the person's one owner profile is revoked:
// no profile to admit under (fixture.exs `admit`).
const REVOKED = ":no_profile";
const { homes } = readHomes(homesFile);
const base = homes[0].origin;
const components = `${base}/a/${encodeURIComponent(segment)}/components`;
const layer = "#system-layer-dialog";
const rows = [];
const record = {};

function row(step, held, what, detail) {
  rows.push({ step, held: !!held, what, detail });
  console.log(`${held ? "held  " : "FAILED"} ${step}: ${what} — ${JSON.stringify(detail).slice(0, 2000)}`);
  return !!held;
}

// What a row's detail shows of a preview's answer: its commit digest, or, for
// an error, the error and the answer's key names, never its values. The answer
// carries a single-use proof.
const previewShown = (answer) =>
  answer.commit_digest || { error: answer.error ?? null, keys: Object.keys(answer).sort() };
// What the record keeps of a preview's answer: the whole document, whose
// single-use proof the record's redaction writes as [secret] (`proof` is a
// secret key in ../browser/lib.mjs), or what previewShown keeps of an error.
const previewRecord = (answer) => (answer.commit_digest ? answer : previewShown(answer));

const ask = (request, options) => askRunSh(request, { outDir, ...options });

// The grant prompt for the tincture, opened from its Components row.
async function openGrant(page) {
  await page.goto(components);
  await page.waitForSelector(".phx-connected", { timeout: 30_000 });
  await page.locator(`[phx-click="toggle_expand"][phx-value-ref="${REF}"]`).first().click();
  await page.locator('[phx-click="open_consent"]').click({ timeout: 30_000 });
  await page.waitForSelector(`${layer}[open] [data-test="grant-rows"]`, { timeout: 30_000 });
}

// What the open sheet shows: each row's kind and text, the origins ticked,
// and whether it is approving (a preview it can commit).
function sheet(page) {
  return page.evaluate((dialog) => {
    const root = document.querySelector(dialog);
    const rowsShown = [...root.querySelectorAll("[data-row]")].map((el) => ({
      kind: el.getAttribute("data-row"),
      text: el.textContent.replace(/\s+/g, " ").trim(),
    }));
    const origins = [...root.querySelectorAll("input[data-origin]")]
      .filter((el) => el.checked)
      .map((el) => el.getAttribute("data-origin"));
    const admits = root.querySelector('[data-test="grant-admits"]');
    return {
      rows: rowsShown,
      origins,
      admits: admits ? admits.textContent.replace(/\s+/g, " ").trim() : null,
      text: root.textContent.replace(/\s+/g, " ").trim(),
    };
  }, layer);
}

// The open prompt's accessible description, as Chromium's accessibility
// tree computes it from the dialog's `aria-describedby`, and whether
// keyboard focus is inside the prompt.
async function described(page) {
  const cdp = await page.context().newCDPSession(page);
  try {
    const { root } = await cdp.send("DOM.getDocument", { depth: 0 });
    const { nodeId } = await cdp.send("DOM.querySelector", { nodeId: root.nodeId, selector: layer });
    const { nodes } = await cdp.send("Accessibility.getPartialAXTree", { nodeId, fetchRelatives: false });
    const node = nodes.find((n) => !n.ignored) || {};
    const focused = await page.evaluate((dialog) => Boolean(document.activeElement?.closest(dialog)), layer);
    return {
      role: node.role?.value ?? null,
      description: (node.description?.value ?? "").replace(/\s+/g, " ").trim(),
      focused,
    };
  } finally {
    await cdp.detach();
  }
}

async function confirm(page) {
  await page.locator(`${layer} [data-test="prompt-confirm"]`).click();
  await page.waitForFunction(() => !document.getElementById("system-layer-dialog")?.open, null, {
    timeout: 30_000,
  });
}

async function main() {
  const proxy = await startProxy(readHomes(homesFile));
  const browser = await launchBrowser("chromium", proxy);
  const context = await signedIn(browser, base, cookie);
  const page = await context.newPage();

  try {
    // -----------------------------------------------------------------------
    // prism_grant
    // -----------------------------------------------------------------------
    const frames = [];
    page.on("websocket", (ws) => {
      ws.on("framesent", (f) => frames.push({ dir: "out", data: String(f.payload).slice(0, 600) }));
      ws.on("framereceived", (f) => frames.push({ dir: "in", data: String(f.payload).slice(0, 600) }));
    });
    await openGrant(page);
    const spoken = await described(page);
    const first = await sheet(page);
    // The prompt is a focused dialog described first by its own sentence.
    const promptSpoken = spoken.role === "dialog" && spoken.focused &&
      spoken.description.startsWith(GRANT_DESCRIBED);

    // A host's checkbox, unticked: the browser sends the host it names,
    // and the home narrows the grant to the host left ticked.
    const hostBox = page.locator(
      `${layer} input[phx-click="toggle_value"][phx-value-field="domains"][phx-value-choice="${DROPPED}"]`,
    );
    await hostBox.click();
    const hostNarrowed = await waitFor(
      async () => (await sheet(page)).rows.some((r) => r.kind === "egress" && /narrowed by you/.test(r.text)),
      { what: "the narrowed host" },
    ).catch(() => false);
    const hostUnticked = !(await hostBox.isChecked());
    const hostEvent = frames.filter((f) => f.dir === "out" && /"toggle_value"/.test(f.data)).map((f) => f.data);
    const hostSent = hostEvent.some((d) => d.includes(`"choice":"${DROPPED}"`));

    // The trusted picker: a folder inside the one the tincture asks for.
    await page.locator(`${layer} button[phx-click="open_picker"][phx-value-path="data/probe/"]`).click();
    await page
      .locator(`${layer} button[phx-click="pick_path"][phx-value-path="${PICKED}"]`)
      .click({ timeout: 30_000 });
    const narrowedShown = await waitFor(
      async () => (await sheet(page)).rows.some((r) => r.kind === "storage" && /narrowed by you/.test(r.text)),
      { what: "the narrowed preview" },
    ).catch(() => false);
    const narrowed = await sheet(page);
    if (!hostNarrowed || !narrowedShown) {
      await page.screenshot({ path: join(outDir, "prism-grant.png"), fullPage: true });
      // The page's last frames, with every value the proof knows to be
      // secret replaced before it is written (lib.mjs `redact`).
      const known = [cookie, ...(await pageTokens(page))];
      writeFileSync(join(outDir, "prism-grant-frames.json"),
        JSON.stringify(redactFrames(frames.slice(-40), known), null, 1));
      row("prism_grant", false, "the sheet never showed the narrowed preview",
        { first, narrowed, host_narrowed: hostNarrowed, host_sent: hostEvent, spoken });
      return;
    }
    await confirm(page);
    const head = await ask({ op: "head" });
    const granted = await ask({ op: "plan" });
    record.prism_grant = {
      first, narrowed, head, plan: granted,
      host_checkbox: { unticked_in_browser: hostUnticked, narrowed_by_home: hostNarrowed, sent: hostEvent },
      spoken,
    };

    const egress = narrowed.rows.find((r) => r.kind === "egress");
    const storage = narrowed.rows.find((r) => r.kind === "storage");
    // Every exit is shown with the classes that may reach it: the kept
    // host the folder's files, the dropped host the notes.
    const exitShown = (shown, host, cls) =>
      shown.rows.some((r) => r.kind === "exits" && r.text.includes(host) && r.text.includes(cls));
    const exitsShown = exitShown(first, KEPT, "files_by_grant") && exitShown(first, DROPPED, "filed");
    // Exactly what the sheet decided, the host left ticked and the picked
    // folder, previewed from the command line: its digest is the one the head
    // must hold, and cli_digest holds its whole answer.
    const subset = { egress: { domains: [KEPT] }, storage: { paths: [PICKED] } };
    const decisions = { ref: REF, subset: { [REF]: subset }, origins: ["interactive"] };
    const cli = await ask({ op: "cli_preview", decisions });
    // The head the grant committed, held whole (`grantedHeld` in heads.mjs),
    // and the copies a change of permission or of digest would leave, each
    // refused.
    const firstGrant = {
      shape: granted.shape_digest, digest: cli.commit_digest, origins: ["interactive"], domains: [KEPT],
      paths: [PICKED], flows: [`files_by_grant to ${KEPT}`],
    };
    const grantCopies = [...changedCopies(head, DROPPED), ...digestCopies(head)];
    if (!row("prism_grant",
      promptSpoken && first.origins.length === 1 && first.origins[0] === "interactive" &&
        hostUnticked && hostSent && egress && /narrowed by you/.test(egress.text) &&
        storage && storage.text.includes(PICKED) && /narrowed by you/.test(storage.text) && exitsShown &&
        sameHead(granted, { shape_digest: granted.shape_digest, background: false }) &&
        grantedHeld(head, firstGrant) && grantCopies.every((copy) => !grantedHeld(copy, firstGrant)),
      "the prompt a focused dialog described by its own sentence, every exit shown with its flows; granted in Prism, a host unticked and the folder narrowed through the picker, interactive alone, the dropped host's flow gone with it; the head is held whole under the version's shape and the digest the command line previews for the same decisions, and a copy with another revision, a host or flow added or removed, or another digest is refused",
      { spoken, origins: first.origins, admits: narrowed.admits, head, shape: granted.shape_digest,
        held: grantedHeld(head, firstGrant), copies_refused: grantCopies.map((copy) => !grantedHeld(copy, firstGrant)),
        exits_shown: exitsShown, host_checkbox: record.prism_grant.host_checkbox })) return;

    // -----------------------------------------------------------------------
    // cli_digest
    // -----------------------------------------------------------------------
    // The preview's whole answer (`previewHeld` in heads.mjs), judged by one
    // function for the answer and each copy alike.
    const cliPreview = {
      digest: head.commit_digest, revision: head.revision, origins: ["interactive"], domains: [KEPT], paths: [PICKED],
    };
    const cliHeld = (answer) => previewHeld(answer, cliPreview);
    const cliCopies = previewCopies(cli, DROPPED);
    record.cli_digest = { decisions, cli: previewRecord(cli), head_digest: head.commit_digest };
    row("cli_digest", cliHeld(cli) && cliCopies.every((copy) => !cliHeld(copy)),
      "the command line's preview of the same decisions is held whole: document version 1, the head's commit digest and revision, interactive alone, nothing removed, a single-use proof of the home's form, and the host and folder rows narrowed as the sheet narrowed them; a copy with any of these changed, or a field added or missing, is refused",
      { cli: previewShown(cli), held: cliHeld(cli), copies_refused: cliCopies.map((copy) => !cliHeld(copy)) });

    // -----------------------------------------------------------------------
    // background
    // -----------------------------------------------------------------------
    await ask({ op: "publish", version: "1.1.0", variant: "background" });
    const plan = await ask({ op: "plan" });
    const asking = await ask({ op: "admit" });
    await openGrant(page);
    const again = await sheet(page);
    const frame = again.rows.find((r) => r.kind === "frame");
    await confirm(page);
    const regranted = await ask({ op: "head" });
    const admitted = await ask({ op: "admit" });
    // A re-grant opens from the head's narrowing (`Plan.head_narrowing/4`),
    // which names every narrowable field the head grants otherwise than the
    // version asks: the host and folder kept, and the one flow kept named as an
    // exit. Those decisions, previewed for this version, answer the digest it
    // committed.
    const regrantDecisions = {
      ref: REF, subset: { [REF]: { ...subset, exits: [{ from: "files_by_grant", to: KEPT }] } }, origins: ["interactive"],
    };
    const backgroundShown = await ask({ op: "cli_preview", decisions: regrantDecisions });
    // Diagnostic: the first grant's decisions, with no exit named; its digest is not the head's.
    const backgroundUnnarrowed = await ask({ op: "cli_preview", decisions });
    const backgroundGrant = { before: head, shape: plan.shape_digest, digest: backgroundShown.commit_digest };
    const backgroundCopies = [...changedCopies(regranted, DROPPED), ...digestCopies(regranted, head.commit_digest)];
    // The preview's whole answer, asked once the re-grant is the head.
    const backgroundPreview = {
      digest: regranted.commit_digest, revision: regranted.revision, origins: ["interactive"], domains: [KEPT],
      paths: [PICKED],
    };
    const backgroundPreviewHeld = (answer) => previewHeld(answer, backgroundPreview);
    const backgroundPreviewCopies = previewCopies(backgroundShown, DROPPED);
    record.background = {
      plan, asking, again, regranted, admitted, regrantDecisions,
      preview: previewRecord(backgroundShown), unnarrowed: previewShown(backgroundUnnarrowed),
    };
    if (!row("background",
      sameHead(plan, { shape_digest: plan.shape_digest, background: true }) && plan.shape_digest !== head.shape_digest &&
        sameHead(asking, { admitted: false, refusal: "consent_required" }) &&
        frame && /background/.test(frame.text) &&
        Array.isArray(again.origins) && sameSet(again.origins, regranted.admitted_origins) &&
        regrantHeld(regranted, backgroundGrant) &&
        backgroundCopies.every((copy) => !regrantHeld(copy, backgroundGrant)) &&
        backgroundPreviewHeld(backgroundShown) &&
        backgroundPreviewCopies.every((copy) => !backgroundPreviewHeld(copy)) &&
        sameHead(admitted, { admitted: true, consent_id: regranted.consent_id }),
      "a version asking to run in the background is shown and asked again, its sheet starting from the origins the head admits; granted, the head is the first head one revision on, under a new consent, the version's shape and the digest the command line previews for what the re-grant commits, every other field held, and it runs; a copy with another revision, a host or flow added or removed, or another digest is refused, and the preview is held whole as cli_digest's is",
      { asking, frame: frame && frame.text, origins_kept: again.origins, head: regranted,
        digest: previewShown(backgroundShown), unnarrowed: previewShown(backgroundUnnarrowed),
        held: regrantHeld(regranted, backgroundGrant),
        copies_refused: backgroundCopies.map((copy) => !regrantHeld(copy, backgroundGrant)),
        preview_held: backgroundPreviewHeld(backgroundShown),
        preview_copies_refused: backgroundPreviewCopies.map((copy) => !backgroundPreviewHeld(copy)), admitted })) return;

    // -----------------------------------------------------------------------
    // reworded
    // -----------------------------------------------------------------------
    await ask({ op: "publish", version: "1.2.0", variant: "reworded" });
    const reworded = await ask({ op: "plan" });
    const still = await ask({ op: "admit" });
    const unchanged = await ask({ op: "head" });
    record.reworded = { reworded, still, unchanged };
    // The head after rewording is the head before it, every field held. The
    // copies are heads a permission change would leave behind: the predicate
    // must refuse each one.
    const rewordedCopies = changedCopies(unchanged, DROPPED);
    if (!row("reworded",
      sameHead(reworded, { shape_digest: regranted.shape_digest, background: true }) &&
        sameHead(still, { admitted: true, consent_id: regranted.consent_id }) && sameHead(unchanged, regranted) &&
        rewordedCopies.every((copy) => !sameHead(copy, regranted)),
      "a reworded reason changes no shape digest and asks nothing; the head holds every field it held, and a copy with another revision, or a host or flow added or removed, is refused",
      { shape: reworded.shape_digest === regranted.shape_digest, still, head: unchanged,
        same_head: sameHead(unchanged, regranted),
        copies_refused: rewordedCopies.map((copy) => !sameHead(copy, regranted)) })) return;

    // -----------------------------------------------------------------------
    // flows
    // -----------------------------------------------------------------------
    await ask({ op: "publish", version: "1.3.0", variant: "flows" });
    const flowed = await ask({ op: "plan" });
    const flowAsking = await ask({ op: "admit" });
    await openGrant(page);
    const flowSheet = await sheet(page);
    // A re-grant opens from the head's narrowing, so a flow the version
    // newly asks for opens unticked: the person ticks it.
    const newFlow = page.locator(
      `${layer} input[phx-click="toggle_flow"][phx-value-exit="${KEPT}"][phx-value-choice="outside"]`,
    );
    const openedOff = !(await newFlow.isChecked());
    await newFlow.click();
    const ticked = await waitFor(async () => newFlow.isChecked(), { what: "the new flow ticked" }).catch(() => false);
    // The sheet records its narrowing of the flows as explicit exits whenever
    // the flows it keeps are not every flow the version asks; the commit digest
    // covers that narrowing, so the decisions name the two kept flows, which is
    // the preview the person approved.
    const keptFlows = [{ from: "files_by_grant", to: KEPT }, { from: "outside", to: KEPT }];
    const flowsDecisions = { ref: REF, subset: { [REF]: { ...subset, exits: keptFlows } }, origins: ["interactive"] };
    const flowsShown = await ask({ op: "cli_preview", decisions: flowsDecisions });
    // Diagnostic: the same decisions without the named exits; its digest is not the head's.
    const flowsUnnarrowed = await ask({ op: "cli_preview", decisions });
    await confirm(page);
    const flowHead = await ask({ op: "head" });
    const flowAdmitted = await ask({ op: "admit" });
    const flowsGrant = { regranted, shape: flowed.shape_digest, kept: KEPT, digest: flowsShown.commit_digest };
    // The preview's whole answer, asked while the background grant was the head.
    const flowsPreview = {
      digest: flowHead.commit_digest, revision: regranted.revision, origins: ["interactive"], domains: [KEPT],
      paths: [PICKED],
    };
    const flowsPreviewHeld = (answer) => previewHeld(answer, flowsPreview);
    const flowsPreviewCopies = previewCopies(flowsShown, DROPPED);
    record.flows = {
      flowed, flowAsking, flowSheet, flowHead, flowAdmitted,
      flowsShown: previewRecord(flowsShown), flowsUnnarrowed: previewShown(flowsUnnarrowed),
    };
    // The head after the flows grant moves in revision, consent, digest and
    // shape, its flows are exactly the two granted, and its digest is the one
    // the preview answers (`flowsHeld` in heads.mjs). Every other field is the
    // head before it.
    const flowsCopies = [...changedCopies(flowHead, DROPPED), ...digestCopies(flowHead, regranted.commit_digest)];
    if (!row("flows",
      sameHead(flowed, { shape_digest: flowed.shape_digest, background: true }) &&
        flowed.shape_digest !== reworded.shape_digest &&
        sameHead(flowAsking, { admitted: false, refusal: "consent_required" }) &&
        exitShown(flowSheet, KEPT, "outside") && exitShown(flowSheet, KEPT, "files_by_grant") &&
        openedOff && ticked && flowsHeld(flowHead, flowsGrant) &&
        flowsCopies.every((copy) => !flowsHeld(copy, flowsGrant)) &&
        flowsPreviewHeld(flowsShown) && flowsPreviewCopies.every((copy) => !flowsPreviewHeld(copy)) &&
        sameHead(flowAdmitted, { admitted: true, consent_id: flowHead.consent_id }),
      "a version letting one more class reach a host is asked again with that exit shown, the new flow unticked; ticked and granted, the head holds exactly its granted flows and every other field, under the digest the command line previews for the same decisions; copies with another revision, a host or flow added or removed, or another digest are refused, and the preview is held whole as cli_digest's is",
      { asking: flowAsking, opened_off: openedOff, ticked, head: flowHead, digest: previewShown(flowsShown),
        unnarrowed: previewShown(flowsUnnarrowed),
        held: flowsHeld(flowHead, flowsGrant), copies_refused: flowsCopies.map((copy) => !flowsHeld(copy, flowsGrant)),
        preview_held: flowsPreviewHeld(flowsShown),
        preview_copies_refused: flowsPreviewCopies.map((copy) => !flowsPreviewHeld(copy)) })) return;

    // -----------------------------------------------------------------------
    // revocation
    // -----------------------------------------------------------------------
    const revoked = await ask({ op: "revoke", profile_id: regranted.profile_id });
    record.revocation = revoked;
    // The answer held whole (`revokedHeld` in heads.mjs): admitted before under
    // the flows head's consent, refused at the first admission after, and each
    // copy with one field changed or added refused.
    const revocation = { consent: flowHead.consent_id, refusal: REVOKED, boundUs: REVOKE_BOUND_US };
    const revokedCopies = [
      { ...revoked, attempts: 2 },
      { ...revoked, before: { admitted: true, consent_id: regranted.consent_id } },
      { ...revoked, refused: { admitted: false, refusal: "consent_required" } },
      { ...revoked, refused_after_us: REVOKE_BOUND_US + 1 },
      { ...revoked, also: true },
    ];
    row("revocation",
      revokedHeld(revoked, revocation) && revokedCopies.every((copy) => !revokedHeld(copy, revocation)),
      "a revocation refuses the next admission on the member that committed it, for want of a profile; the answer is held whole, and a copy with a second attempt, another consent before it, another refusal, a time past its bound or another field is refused",
      { answer: revoked, held: revokedHeld(revoked, revocation),
        copies_refused: revokedCopies.map((copy) => !revokedHeld(copy, revocation)) });
  } finally {
    await browser.close();
    await proxy.close();
    writeFileSync(join(outDir, "grant-proof.json"), recordText({ rows, record }, [cookie]));
    const table = ["| Step | Held | What |", "|---|---|---|",
      ...rows.map((r) => `| \`${r.step}\` | ${r.held ? "held" : "FAILED"} | ${r.what} |`)].join("\n");
    writeFileSync(join(outDir, "grant-proof.md"), redact(table, [cookie]) + "\n");
    console.log(table);
  }
}

main()
  .then(() => process.exit(rows.length === 6 && rows.every((r) => r.held) ? 0 : 1))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
