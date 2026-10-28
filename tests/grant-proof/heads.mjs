// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The head predicates of the grant proof (proof.mjs): what two heads hold in
// common, what the head the first grant commits holds, and what the head after
// the flows grant holds, with the copies of a head each must refuse. They are
// kept apart from the proof so heads-test.mjs can run them on heads without a
// browser.

const DIGEST = /^sha256:[0-9a-f]{64}$/;
const PROFILE = /^prof_[0-9a-f-]{36}$/;
const CONSENT = /^cons_[0-9a-f-]{36}$/;

// Arrays as sets, so an extra or a missing flow, domain or path differs.
export const sameSet = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());

// Two heads hold the same fields, arrays as sets and every other field exactly.
export const sameHead = (a, b) =>
  [...new Set([...Object.keys(a), ...Object.keys(b)])].every((k) =>
    Array.isArray(a[k]) && Array.isArray(b[k]) ? sameSet(a[k], b[k]) : a[k] === b[k]);

// Copies of a head a change of permission would leave behind, each of which
// a row's predicate must refuse: another revision, a host added or removed,
// and a flow added or removed.
export const changedCopies = (head, dropped) => [
  { ...head, revision: head.revision + 1 },
  { ...head, domains: [...head.domains, dropped] },
  { ...head, domains: head.domains.slice(1) },
  { ...head, flows: [...head.flows, `outside to ${dropped}`] },
  { ...head, flows: head.flows.slice(1) },
];

// Copies of a head committed under no digest, an empty or malformed one, a
// well-formed digest no preview answered, and `previous`, the digest the head
// before it held.
export const digestCopies = (head, previous) =>
  [null, "", "sha256:wrong", `sha256:${"0".repeat(64)}`, previous].map((commit_digest) => ({ ...head, commit_digest }));

// The head the first grant commits: revision 1 and exactly the decisions the
// person made (origins, hosts, folders and flows, as sets), under the shape the
// version's plan asks, held by an owner profile and a consent of their own.
// Its commit digest is well formed here; the cli_digest row binds it to the
// command line's preview of the same decisions.
export const grantedHeld = (head, { shape, origins, domains, paths, flows }) =>
  PROFILE.test(head.profile_id) && CONSENT.test(head.consent_id) && DIGEST.test(head.commit_digest) &&
  DIGEST.test(shape) &&
  sameHead(head, {
    profile_id: head.profile_id, consent_id: head.consent_id, commit_digest: head.commit_digest,
    revision: 1, shape_digest: shape, admitted_origins: origins, domains, paths, flows,
  });

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
