// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The grant proof, run in the official Playwright image by run.sh against a
// `cyfr` release behind the harness's HTTPS front (README.md). One person,
// in Chromium, grants the tincture grant-probe on the console's Components
// page. Each step is one row of the record; the proof fails when a row does
// not hold, and stops at the first row a later one rests on.
//
//   prism_grant  the grant made in Prism's system layer, one host narrowed
//                away and interactive the one origin admitted: the head
//                holds exactly that
//   cli_digest   the same decisions previewed from the command line answer
//                the commit digest the head was committed under
//   background   a version asking to keep running when hidden: the person's
//                run is asked to grant again, and the sheet shows the
//                background row; granted, the head holds it
//   reworded     a version that only rewords its need's reason: the same
//                shape digest, and the run is admitted under the grant it
//                had, nothing asked
//   revocation   the profile revoked in the console: the next admission is
//                refused, timed from the revocation's answer
//
// The server's part of a step — publishing a version, reading the head and
// the plan, an admission, the revocation and the command line's preview —
// is run.sh's, asked for through OUT_DIR (`ask-N.json`, answered
// `answer-N.json`).
//
// Usage: node proof.mjs HOMES_FILE SEGMENT COOKIE OUT_DIR

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { launchBrowser, readHomes, signedIn, sleep, startProxy, waitFor } from "../browser/lib.mjs";

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
  return JSON.parse(readFileSync(answer, "utf8"));
}

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

async function confirm(page) {
  await page.locator(`${layer} [data-test="prompt-confirm"]`).click();
  await page.waitForFunction(() => !document.getElementById("system-layer-dialog")?.open, null, {
    timeout: 30_000,
  });
}

async function main() {
  const proxy = await startProxy(null, readHomes(homesFile));
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
    const first = await sheet(page);

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
      writeFileSync(join(outDir, "prism-grant-frames.json"), JSON.stringify(frames.slice(-40), null, 1));
      row("prism_grant", false, "the sheet never showed the narrowed preview",
        { first, narrowed, host_narrowed: hostNarrowed, host_sent: hostEvent });
      return;
    }
    await confirm(page);
    const head = await ask({ op: "head" });
    record.prism_grant = {
      first, narrowed, head,
      host_checkbox: { unticked_in_browser: hostUnticked, narrowed_by_home: hostNarrowed, sent: hostEvent },
    };

    const egress = narrowed.rows.find((r) => r.kind === "egress");
    const storage = narrowed.rows.find((r) => r.kind === "storage");
    if (!row("prism_grant",
      first.origins.length === 1 && first.origins[0] === "interactive" &&
        hostUnticked && hostSent && egress && /narrowed by you/.test(egress.text) &&
        storage && storage.text.includes(PICKED) && /narrowed by you/.test(storage.text) &&
        head.revision === 1 && JSON.stringify(head.admitted_origins) === JSON.stringify(["interactive"]) &&
        JSON.stringify(head.domains) === JSON.stringify([KEPT]) &&
        JSON.stringify(head.paths) === JSON.stringify([PICKED]),
      "granted in Prism, a host unticked and the folder narrowed through the picker, interactive alone",
      { origins: first.origins, admits: narrowed.admits, paths: head.paths, domains: head.domains,
        host_checkbox: record.prism_grant.host_checkbox })) return;

    // -----------------------------------------------------------------------
    // cli_digest
    // -----------------------------------------------------------------------
    // Exactly what the sheet decided: the host left ticked and the picked
    // folder.
    const subset = { egress: { domains: [KEPT] }, storage: { paths: [PICKED] } };
    const decisions = { ref: REF, subset: { [REF]: subset }, origins: ["interactive"] };
    const cli = await ask({ op: "cli_preview", decisions });
    record.cli_digest = { decisions, cli, head_digest: head.commit_digest };
    row("cli_digest", cli.commit_digest && cli.commit_digest === head.commit_digest,
      "the command line's preview of the same decisions answers the head's commit digest",
      { cli: cli.commit_digest || cli, head: head.commit_digest });

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
    record.background = { plan, asking, again, regranted, admitted };
    if (!row("background",
      plan.background === true && plan.shape_digest !== head.shape_digest &&
        asking.admitted === false && asking.refusal === "consent_required" &&
        frame && /background/.test(frame.text) &&
        regranted.revision === 2 && JSON.stringify(regranted.admitted_origins) === JSON.stringify(["interactive"]) &&
        admitted.admitted === true && admitted.consent_id === regranted.consent_id,
      "a version asking to run in the background is shown and asked again; granted, it runs",
      { asking, frame: frame && frame.text, origins_kept: again.origins, regranted: regranted.revision })) return;

    // -----------------------------------------------------------------------
    // reworded
    // -----------------------------------------------------------------------
    await ask({ op: "publish", version: "1.2.0", variant: "reworded" });
    const reworded = await ask({ op: "plan" });
    const still = await ask({ op: "admit" });
    const unchanged = await ask({ op: "head" });
    record.reworded = { reworded, still, unchanged };
    row("reworded",
      reworded.shape_digest === regranted.shape_digest && still.admitted === true &&
        still.consent_id === regranted.consent_id && unchanged.revision === 2,
      "a reworded reason changes no shape digest and asks nothing",
      { shape: reworded.shape_digest === regranted.shape_digest, still, revision: unchanged.revision });

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
    writeFileSync(join(outDir, "grant-proof.json"), JSON.stringify({ rows, record }, null, 2));
    const table = ["| Step | Held | What |", "|---|---|---|",
      ...rows.map((r) => `| \`${r.step}\` | ${r.held ? "held" : "FAILED"} | ${r.what} |`)].join("\n");
    writeFileSync(join(outDir, "grant-proof.md"), table + "\n");
    console.log(table);
  }
}

main()
  .then(() => process.exit(rows.length === 5 && rows.every((r) => r.held) ? 0 : 1))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
