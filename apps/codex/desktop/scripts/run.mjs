// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The one place the Mac distribution's recipe starts a process.
//
// run() starts a tool and waits for it within its bound. Its output reaches
// the caller only when the tool exited 0 inside that bound; a failed or
// outrun call is a refusal carrying the caller's sentence and the exit
// status, and nothing the tool printed. A call handed a secret (by its
// environment, a file or its standard input) gives the caller only what
// `read` parses out of its output, never the text itself, so no way a tool
// rewrites a secret can reach a sentence. A bound that runs out stops the
// tool and everything beneath it, however deep and whatever process group
// each joined (stopTree), before the refusal returns.

import {spawn} from "node:child_process"

import {Refused, redact} from "./check-package.mjs"

/**
 * Run `cmd` with `args` within `seconds`, saying `what` on refusal.
 * Options: `input` (standard input), `env`, `secret` (the call was handed
 * a secret), `read` (parses the output on success; for a secret call the
 * only thing returned), `stream` (prints each output line through it as it
 * comes, for a call handed no secret). Resolves to {out, err} (or read's
 * answer) on exit 0; rejects with Refused otherwise.
 */
export function run(cmd, args, {what, seconds = 120, input, env, secret = false, read, stream} = {}) {
  if (!what) throw new Error("run needs the sentence its refusal says")
  if (secret && stream) throw new Error("a call handed a secret prints nothing of its own")
  return new Promise((resolve, reject) => {
    let child
    try {
      child = spawn(cmd, args, {env, stdio: [input === undefined ? "ignore" : "pipe", "pipe", "pipe"]})
    } catch {
      reject(new Refused(`${what}: ${cmd} could not be run`))
      return
    }
    const out = []
    const err = []
    const lines = (from, into) => {
      let held = ""
      from.setEncoding("utf8")
      from.on("data", (chunk) => {
        into.push(chunk)
        if (!stream) return
        held += chunk
        const at = held.lastIndexOf("\n")
        if (at >= 0) { stream(held.slice(0, at + 1)); held = held.slice(at + 1) }
      })
      from.on("end", () => { if (stream && held) stream(held + "\n") })
    }
    lines(child.stdout, out)
    lines(child.stderr, err)
    if (input !== undefined) {
      child.stdin.on("error", () => {})
      child.stdin.end(input)
    }
    let outran = false
    let started = true
    let unstopped = []
    const timer = setTimeout(async () => {
      outran = true
      unstopped = await stopTree(child.pid)
    }, seconds * 1000)
    child.on("error", () => { started = false })
    child.on("close", async (code, signal) => {
      clearTimeout(timer)
      if (outran) {
        // The tree is stopped before the refusal returns.
        unstopped = [...unstopped, ...await stopTree(child.pid)]
        reject(new Refused(unstopped.length ? `${what}: did not finish in ${seconds} seconds, and ${unstopped.length} of what it ` +
          `started could not be stopped` : `${what}: did not finish in ${seconds} seconds`))
      } else if (!started) {
        reject(new Refused(`${what}: ${cmd} could not be run`))
      } else if (code !== 0) {
        reject(new Refused(`${what}: exit ${code ?? `by signal ${signal}`}`))
      } else if (read) {
        try {
          resolve(read(out.join(""), err.join("")))
        } catch {
          reject(new Refused(`${what}: its answer is not in the form it gives`))
        }
      } else {
        resolve(secret ? undefined : {out: out.join(""), err: err.join("")})
      }
    })
  })
}

// The process table as {pid, ppid, pgid} rows, read by ps (macOS and Linux
// spell its columns alike).
async function table() {
  const {out} = await run("ps", ["-A", "-o", "pid=", "-o", "ppid=", "-o", "pgid="], {what: "the process list was not read", seconds: 20})
  return out.split("\n").map((l) => l.trim().split(/\s+/).map(Number)).filter((r) => r.length === 3 && r.every(Number.isInteger))
    .map(([pid, ppid, pgid]) => ({pid, ppid, pgid}))
}

/**
 * Stop `root` and every process beneath it, however deep: each is frozen
 * (SIGSTOP) so it starts nothing more, the tree is read again until it
 * holds no new process, then each, and each process group one of them
 * leads, is killed. This process's own group is never signalled. Resolves
 * to the processes that could not be signalled; one already gone is
 * stopped.
 */
export async function stopTree(root) {
  const failed = []
  const signal = (target, name) => {
    try { process.kill(target, name) } catch (e) { if (e.code !== "ESRCH") failed.push(target) }
  }
  const seen = new Map()
  for (let round = 0; round < 20; round++) {
    const rows = await table()
    const own = rows.find((r) => r.pid === process.pid)?.pgid
    const below = new Set([root])
    let grew = true
    while (grew) {
      grew = false
      for (const r of rows) if (below.has(r.ppid) && !below.has(r.pid)) { below.add(r.pid); grew = true }
    }
    let fresh = false
    for (const r of rows) {
      if (!below.has(r.pid) || seen.has(r.pid)) continue
      fresh = true
      seen.set(r.pid, r.pgid === r.pid && r.pgid !== own ? r.pgid : null)
      signal(r.pid, "SIGSTOP")
    }
    if (!fresh) break
  }
  for (const [pid, group] of seen) {
    if (group) signal(-group, "SIGKILL")
    signal(pid, "SIGKILL")
  }
  return failed
}

/** The recipe's one way to print: every line through redact(). */
export function say(text, {to = process.stdout} = {}) {
  to.write(redact(text))
}
