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

/** The kept storage of session `ses`, its owner recorded in `file`. */
export function keptStorage(ses, file) {
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
    try {
      await ses.clearStorageData()
      await ses.clearCache()
      await ses.cookies.flushStore()
      // The engine's promise does not say that it deleted: the cookies do.
      return (await ses.cookies.get({})).length === 0
    } catch {
      return false
    }
  }

  /**
   * Make the CYFR at `home` the owner: it is already, or the storage is
   * cleared and only then recorded as its own. In that order an app that
   * dies between leaves empty storage under the last owner, never the last
   * owner's storage under this one.
   */
  async function take(home) {
    try {
      if (holds(home)) return true
      if (!await clear()) return false
      record(new URL(home).origin)
      return true
    } catch {
      return false
    }
  }

  /** Load the root of the CYFR at `home` into window `w`, only as the owner's. */
  function loadRoot(w, home) {
    if (!holds(home)) return false
    Promise.resolve(w.loadURL(`${home}/`)).catch(() => {})
    return true
  }

  return {clear, take, loadRoot}
}
