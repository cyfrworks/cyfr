// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The head predicates of the grant proof (proof.mjs): what two heads hold in
// common, and what the head after the flows grant holds. They are kept apart
// from the proof so heads-test.mjs can run them on heads without a browser.

const DIGEST = /^sha256:[0-9a-f]{64}$/;

// Arrays as sets, so an extra or a missing flow, domain or path differs.
export const sameSet = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());

// Two heads hold the same fields, arrays as sets and every other field exactly.
export const sameHead = (a, b) =>
  [...new Set([...Object.keys(a), ...Object.keys(b)])].every((k) =>
    Array.isArray(a[k]) && Array.isArray(b[k]) ? sameSet(a[k], b[k]) : a[k] === b[k]);

// The head after the flows grant: one revision on from the regranted head, its
// consent new and its digest the one `digest` names, the command line's preview
// of the decisions the grant committed. Its flows are exactly the two granted
// and every other field is the regranted head's, with the flows version's shape.
// No digest to bind to refuses every head, and so does a head with no digest.
export const flowsHeld = (head, { regranted, shape, kept, digest }) =>
  DIGEST.test(digest) && typeof head.consent_id === "string" && head.consent_id !== regranted.consent_id &&
  head.commit_digest !== regranted.commit_digest &&
  sameHead({ ...head, consent_id: regranted.consent_id },
    { ...regranted, revision: regranted.revision + 1, shape_digest: shape, commit_digest: digest,
      flows: [`files_by_grant to ${kept}`, `outside to ${kept}`] });
