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
//                command line previews for the same decisions
//   reworded     a version that only rewords its need's reason: the same
//                shape digest, and the run is admitted under the grant it
//                had, nothing asked
//   flows        a version that lets one more class reach the host it keeps:
//                the person's run is asked to grant again, the sheet shows
//                that exit with the class unticked; ticked and granted, the
//                head holds the flow, under the digest the command line
//                previews for the same decisions
//   revocation   the profile revoked in the console: the next admission is
//                refused, timed from the revocation's answer
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
import { changedCopies, digestCopies, flowsHeld, grantedHeld, regrantHeld, sameHead } from "./heads.mjs";

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

// What the record keeps of a preview's answer: its commit digest, or, for an
// error, the error and the answer's key names, never its values. The answer
// carries a single-use proof.
const previewShown = (answer) =>
  answer.commit_digest || { error: answer.error ?? null, keys: Object.keys(answer).sort() };

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
    // The head the grant committed, held whole (`grantedHeld` in heads.mjs),
    // and the copies a change of permission would leave, each refused.
    const firstGrant = {
      shape: granted.shape_digest, origins: ["interactive"], domains: [KEPT], paths: [PICKED],
      flows: [`files_by_grant to ${KEPT}`],
    };
    const grantCopies = changedCopies(head, DROPPED);
    if (!row("prism_grant",
      promptSpoken && first.origins.length === 1 && first.origins[0] === "interactive" &&
        hostUnticked && hostSent && egress && /narrowed by you/.test(egress.text) &&
        storage && storage.text.includes(PICKED) && /narrowed by you/.test(storage.text) && exitsShown &&
        grantedHeld(head, firstGrant) && grantCopies.every((copy) => !grantedHeld(copy, firstGrant)),
      "the prompt a focused dialog described by its own sentence, every exit shown with its flows; granted in Prism, a host unticked and the folder narrowed through the picker, interactive alone, the dropped host's flow gone with it; the head is held whole under the version's shape, and a copy with another revision, or a host or flow added or removed, is refused",
      { spoken, origins: first.origins, admits: narrowed.admits, head, shape: granted.shape_digest,
        held: grantedHeld(head, firstGrant), copies_refused: grantCopies.map((copy) => !grantedHeld(copy, firstGrant)),
        exits_shown: exitsShown, host_checkbox: record.prism_grant.host_checkbox })) return;

    // -----------------------------------------------------------------------
    // cli_digest
    // -----------------------------------------------------------------------
    // Exactly what the sheet decided: the host left ticked and the picked
    // folder.
    const subset = { egress: { domains: [KEPT] }, storage: { paths: [PICKED] } };
    const decisions = { ref: REF, subset: { [REF]: subset }, origins: ["interactive"] };
    const cli = await ask({ op: "cli_preview", decisions });
    const cliShown = previewShown(cli);
    record.cli_digest = { decisions, cli: cliShown, head_digest: head.commit_digest };
    row("cli_digest", cli.commit_digest && cli.commit_digest === head.commit_digest,
      "the command line's preview of the same decisions answers the head's commit digest",
      { cli: cliShown, head: head.commit_digest });

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
    // The re-grant keeps the first grant's narrowing, so the same decisions,
    // previewed for this version, answer the digest it committed.
    const backgroundShown = await ask({ op: "cli_preview", decisions });
    const backgroundGrant = { before: head, shape: plan.shape_digest, digest: backgroundShown.commit_digest };
    const backgroundCopies = [...changedCopies(regranted, DROPPED), ...digestCopies(regranted, head.commit_digest)];
    record.background = { plan, asking, again, regranted, admitted, digest: previewShown(backgroundShown) };
    if (!row("background",
      plan.background === true && plan.shape_digest !== head.shape_digest &&
        sameHead(asking, { admitted: false, refusal: "consent_required" }) &&
        frame && /background/.test(frame.text) &&
        regrantHeld(regranted, backgroundGrant) &&
        backgroundCopies.every((copy) => !regrantHeld(copy, backgroundGrant)) &&
        sameHead(admitted, { admitted: true, consent_id: regranted.consent_id }),
      "a version asking to run in the background is shown and asked again; granted, the head is the first head one revision on, under a new consent, the version's shape and the digest the command line previews for the same decisions, every other field held, and it runs; a copy with another revision, a host or flow added or removed, or another digest is refused",
      { asking, frame: frame && frame.text, origins_kept: again.origins, head: regranted,
        digest: previewShown(backgroundShown), held: regrantHeld(regranted, backgroundGrant),
        copies_refused: backgroundCopies.map((copy) => !regrantHeld(copy, backgroundGrant)), admitted })) return;

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
      reworded.shape_digest === regranted.shape_digest && still.admitted === true &&
        still.consent_id === regranted.consent_id && sameHead(unchanged, regranted) &&
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
    record.flows = {
      flowed, flowAsking, flowSheet, flowHead, flowAdmitted,
      flowsShown: previewShown(flowsShown), flowsUnnarrowed: previewShown(flowsUnnarrowed),
    };
    // The head after the flows grant moves in revision, consent, digest and
    // shape, its flows are exactly the two granted, and its digest is the one
    // the preview answers (`flowsHeld` in heads.mjs). Every other field is the
    // head before it.
    const flowsCopies = [...changedCopies(flowHead, DROPPED), ...digestCopies(flowHead, regranted.commit_digest)];
    if (!row("flows",
      flowed.shape_digest !== reworded.shape_digest &&
        flowAsking.admitted === false && flowAsking.refusal === "consent_required" &&
        exitShown(flowSheet, KEPT, "outside") && exitShown(flowSheet, KEPT, "files_by_grant") &&
        openedOff && ticked && flowsHeld(flowHead, flowsGrant) &&
        flowsCopies.every((copy) => !flowsHeld(copy, flowsGrant)) &&
        flowAdmitted.admitted === true && flowAdmitted.consent_id === flowHead.consent_id,
      "a version letting one more class reach a host is asked again with that exit shown, the new flow unticked; ticked and granted, the head holds exactly its granted flows and every other field, under the digest the command line previews for the same decisions; copies with another revision, a host or flow added or removed, or another digest are refused",
      { asking: flowAsking, opened_off: openedOff, ticked, head: flowHead, digest: previewShown(flowsShown),
        unnarrowed: previewShown(flowsUnnarrowed),
        held: flowsHeld(flowHead, flowsGrant), copies_refused: flowsCopies.map((copy) => !flowsHeld(copy, flowsGrant)) })) return;

    // -----------------------------------------------------------------------
    // revocation
    // -----------------------------------------------------------------------
    const revoked = await ask({ op: "revoke", profile_id: regranted.profile_id });
    record.revocation = revoked;
    row("revocation",
      revoked.before && revoked.before.admitted === true && revoked.refused && revoked.attempts === 1,
      "a revocation refuses the next admission on the member that committed it",
      { refused: revoked.refused, attempts: revoked.attempts, refused_after_us: revoked.refused_after_us });
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
