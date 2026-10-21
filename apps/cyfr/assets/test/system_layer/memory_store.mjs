// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

/** A store in memory, with the same calls. */
export function memoryStore(record = null, pendingRecord = null, certifyRecord = null, preparedRecord = null) {
  let held = record
  let pending = pendingRecord
  let asked = certifyRecord
  let prepared = preparedRecord
  return {
    load: async () => held,
    save: async (next) => (held = next),
    clear: async () => (held = null),
    saveIf: async (clientId, next) => (held && held.clientId === clientId ? ((held = next), true) : false),
    clearIf: async (clientId) => (held && held.clientId === clientId ? ((held = null), true) : false),
    loadPrepared: async () => prepared,
    savePrepared: async (next) => (prepared = next),
    clearPrepared: async () => (prepared = null),
    loadPending: async () => pending,
    savePending: async (next) => (pending = next),
    clearPending: async () => (pending = null),
    loadCertify: async () => asked,
    saveCertify: async (next) => (asked = next),
    clearCertify: async () => (asked = null)
  }
}
