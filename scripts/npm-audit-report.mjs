// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Runs `npm audit` for the package in the working directory and reports its
// advisories without failing on them, while failing on any audit that did
// not complete.
//
// Usage (from the package directory): node ../../scripts/npm-audit-report.mjs
//
// This file is the only classifier of an npm audit's outcome. A completed
// audit is npm exit 0 or 1 (1 means advisories at or above the audit level)
// with a complete JSON object on stdout that is not npm's operational-error
// envelope (`{"error": {...}}`, which npm prints for registry, network and
// lockfile failures, also with exit 1). Only a completed audit passes, with
// or without advisories. Any other exit, a signal, a missing npm, and
// invalid, truncated or error-envelope output fail: an audit that did not
// complete is not clean coverage. NPM_AUDIT_BIN replaces the npm executable
// (default `npm`) so tests can run this classifier against a fake npm.

import { spawn } from "node:child_process";

const npm = process.env.NPM_AUDIT_BIN || "npm";
const args = ["audit", "--json", "--audit-level=high"];
const severities = ["critical", "high", "moderate", "low", "info"];

function fail(message, stderr = "") {
  process.stderr.write(`npm-audit-report: ${message}\n`);
  if (stderr.trim() !== "") process.stderr.write(`npm-audit-report: npm stderr:\n${stderr}`);
  // exitCode rather than exit(): exit() can cut off output still queued for a pipe.
  process.exitCode = 1;
}

function classify(code, signal, stdout, stderr) {
  const command = `${npm} ${args.join(" ")}`;

  if (signal !== null) return fail(`${command} was terminated by ${signal}`, stderr);
  if (code !== 0 && code !== 1) return fail(`${command} exited ${code}`, stderr);

  if (stdout.trim() === "") return fail(`${command} exited ${code} with no report`, stderr);

  let report;
  try {
    report = JSON.parse(stdout);
  } catch (error) {
    return fail(`${command} exited ${code} with invalid or incomplete JSON: ${error.message}`, stderr);
  }

  if (report === null || typeof report !== "object" || Array.isArray(report)) {
    return fail(`${command} exited ${code} with JSON that is not a report object`, stderr);
  }

  if (Object.hasOwn(report, "error")) {
    const detail = report.error && typeof report.error === "object" ? report.error : {};
    const what = [detail.code, detail.summary].filter((part) => typeof part === "string" && part !== "");
    return fail(
      `${command} exited ${code} with an error instead of a report` +
        (what.length > 0 ? `: ${what.join(": ")}` : "") +
        `\n${JSON.stringify(report.error, null, 2)}`,
      stderr
    );
  }

  if (stderr !== "") process.stderr.write(stderr);

  const counts = report.metadata?.vulnerabilities;
  if (counts !== null && typeof counts === "object") {
    const parts = severities
      .filter((severity) => Number.isInteger(counts[severity]))
      .map((severity) => `${severity} ${counts[severity]}`);
    if (Number.isInteger(counts.total)) parts.push(`total ${counts.total}`);
    process.stdout.write(`npm audit completed (advisories are report-only): ${parts.join(", ")}\n`);
  } else {
    process.stdout.write("npm audit completed (advisories are report-only): report carries no severity counts\n");
  }

  process.stdout.write(stdout.endsWith("\n") ? stdout : `${stdout}\n`);
  process.exitCode = 0;
}

let settled = false;
const stdoutChunks = [];
const stderrChunks = [];

const child = spawn(npm, args, { stdio: ["ignore", "pipe", "pipe"], shell: false });

child.stdout.on("data", (chunk) => stdoutChunks.push(chunk));
child.stderr.on("data", (chunk) => stderrChunks.push(chunk));

child.on("error", (error) => {
  if (settled) return;
  settled = true;
  fail(`could not run ${npm}: ${error.message}`);
});

child.on("close", (code, signal) => {
  if (settled) return;
  settled = true;
  classify(
    code,
    signal,
    Buffer.concat(stdoutChunks).toString("utf8"),
    Buffer.concat(stderrChunks).toString("utf8")
  );
});
