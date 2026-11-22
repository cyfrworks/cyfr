// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The passkey road's kept content storage, which exactly one CYFR owns: its
// origin, scheme, host and port, since CYFRs on two ports of one host
// share their cookies. This is the one record of that owner and the one
// way a CYFR's pages come into that storage: main keeps to a CYFR, and so
// loads or lets a window load anything of it, only once `take` made it
// the owner, and loads a CYFR's root through `loadRoot` alone.

import {closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, writeSync} from "node:fs"
import path from "node:path"

// How many times a clear goes over the storage. A closing page's scripts
// write until its process has gone, also after a clear that began once
// the window was destroyed, and no header rule sees those writes: the
// second pass takes them, and no measured case had any left after it. A
// response to such a page sets nothing (policy.js documentHeaders).
const PASSES = 2

/**
 * The kept storage of session `ses`, its owner recorded in `file`; `say`
 * hears why a clear failed in what the app itself knows: the name of the
 * call that threw, never the text of its error, or each cookie left by its
 * name and site, never its value.
 */
export function keptStorage(ses, file, say) {
  const owner = () => {
    try {
      return readFileSync(file, "utf8")
    } catch {
      return "" // none recorded, so every CYFR is another
    }
  }
  const holds = (home) => owner() === new URL(home).origin

  function record(origin) {
    mkdirSync(path.dirname(file), {recursive: true})
    const next = `${file}.next`
    const fd = openSync(next, "w", 0o600)
    try {
      writeSync(fd, origin)
      fsyncSync(fd)
    } finally {
      closeSync(fd)
    }
    renameSync(next, file)
  }

  /** Whether all the storage kept is gone, on disk too. */
  async function clear() {
    let call
    let left
    try {
      for (let pass = 0; pass < PASSES; pass++) {
        call = "clearStorageData"
        await ses.clearStorageData()
        call = "clearCache"
        await ses.clearCache()
        call = "flushStore"
        await ses.cookies.flushStore()
        // The engine's promise does not say that it deleted: the cookies do.
        call = "cookies.get"
        left = await ses.cookies.get({})
        if (left.length === 0) return true
      }
      say(`not cleared: left ${left.map((c) => `${c.name} at ${c.domain}`).join(", ")}`)
    } catch {
      say(`not cleared: ${call} threw`)
    }
    return false
  }

  /**
   * Make the CYFR main wants the owner: it is already, or the storage is
   * cleared and the one `wanted` names when the clear has ended is recorded
   * as its own. One clear serves every proposal that replaced the one it
   * began for: it empties the whole storage, whoever it began for, and
   * nothing of any CYFR loads meanwhile, since main keeps to a CYFR only
   * once it is open (states.js kept) and an open one takes no proposal.
   * In that order an app that dies between leaves empty storage under the
   * last owner, never the last owner's storage under this one. `answer`
   * hears whether it is taken in the turn the owner is read or recorded,
   * so no proposal comes between the two.
   */
  async function take(wanted, answer) {
    let taken = false
    try {
      if (holds(wanted())) taken = true
      else if (await clear()) {
        record(new URL(wanted()).origin)
        taken = true
      }
    } catch {
      taken = false
    }
    answer(taken)
  }

  /** Load the root of the CYFR at `home` into window `w`, only as the owner's. */
  function loadRoot(w, home) {
    if (!holds(home)) return false
    Promise.resolve(w.loadURL(`${home}/`)).catch(() => {})
    return true
  }

  return {clear, take, loadRoot}
}
