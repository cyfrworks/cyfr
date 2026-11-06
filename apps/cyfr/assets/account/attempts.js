// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// An account being made, kept in this browser's localStorage under its
// identifier from the moment its passkey exists until the account is
// registered, its key appended and its name claimed, so a tab closed on
// the way resumes from the same bytes once the person types their
// recovery code. It holds only what is public once sent: the name, the
// signed genesis and `add_key`, and the step reached; never the code or
// its secret. An attempt older than 24 hours is dropped.

const PREFIX = "cyfr-account-attempt:"
export const LIFETIME_MS = 24 * 60 * 60 * 1000

/** The attempts `storage` holds, over the clock `now`; every call survives a storage that throws or is absent. */
export function attempts(storage, now) {
  const keys = () => {
    try {
      return Array.from({length: storage.length}, (_, i) => storage.key(i)).filter((key) => key?.startsWith(PREFIX))
    } catch (_error) {
      return []
    }
  }
  const drop = (key) => {
    try {
      storage.removeItem(key)
    } catch (_error) {
      // A storage that refuses keeps nothing worth dropping.
    }
  }

  return {
    /** The attempts still open, oldest first; expired or unreadable ones are removed. */
    list() {
      const open = []
      for (const key of keys()) {
        let attempt
        try {
          attempt = JSON.parse(storage.getItem(key))
        } catch (_error) {
          attempt = null
        }
        if (attempt && typeof attempt.created_at === "number" && now() - attempt.created_at < LIFETIME_MS) open.push(attempt)
        else drop(key)
      }
      return open.sort((a, b) => a.created_at - b.created_at)
    },

    save(attempt) {
      try {
        storage.setItem(PREFIX + attempt.identifier, JSON.stringify(attempt))
      } catch (_error) {
        // Without storage a closed tab cannot resume; the attempt goes on in this one.
      }
    },

    remove(identifier) {
      drop(PREFIX + identifier)
    }
  }
}
