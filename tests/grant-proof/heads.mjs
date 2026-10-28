// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The head predicates of the grant proof (proof.mjs): what two heads hold in
// common, what the head the first grant commits holds, what the head a
// re-grant commits holds, and what a revocation answers, with the copies of a
// head each must refuse. They are kept apart from the proof so heads-test.mjs
// can run them on heads without a browser.

const DIGEST = /^sha256:[0-9a-f]{64}$/;
const PROFILE = /^prof_[0-9a-f-]{36}$/;
const CONSENT = /^cons_[0-9a-f-]{36}$/;
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// Arrays as sets, so an extra or a missing flow, domain or path differs.
export const sameSet = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());

// Two heads hold the same fields, arrays as sets and every other field exactly.
// Anything but an object holds no head.
export const sameHead = (a, b) =>
  isObject(a) && isObject(b) &&
  [...new Set([...Object.keys(a), ...Object.keys(b)])].every((k) =>
    Array.isArray(a[k]) && Array.isArray(b[k]) ? sameSet(a[k], b[k]) : a[k] === b[k]);

// Copies of a head a change of permission would leave behind, each of which
// a row's predicate must refuse: another revision, a host added or removed,
// and a flow added or removed. A head with no hosts or flows, as the answer
// for no profile is, still has its copies, so its row records the refusal
// rather than the proof throwing before it.
export const changedCopies = (head, dropped) => {
  const domains = Array.isArray(head.domains) ? head.domains : [];
  const flows = Array.isArray(head.flows) ? head.flows : [];
  return [
    { ...head, revision: head.revision + 1 },
    { ...head, domains: [...domains, dropped] },
    { ...head, domains: domains.slice(1) },
    { ...head, flows: [...flows, `outside to ${dropped}`] },
    { ...head, flows: flows.slice(1) },
  ];
};

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

// The head a re-grant commits: `before`, the head it replaces, one revision
// on, under a consent of its own, the shape the new version's plan asks and
// `digest`, the command line's preview of the decisions the grant committed.
// `changes` are its only other differences; the profile and every other field
// are `before`'s. No digest to bind to refuses every head, and so does a head
// with no digest.
export const regrantHeld = (head, { before, shape, digest, changes = {} }) =>
  DIGEST.test(digest) && DIGEST.test(shape) && CONSENT.test(head.consent_id) &&
  head.consent_id !== before.consent_id && head.commit_digest !== before.commit_digest &&
  sameHead({ ...head, consent_id: before.consent_id },
    { ...before, ...changes, revision: before.revision + 1, shape_digest: shape, commit_digest: digest });

// The head after the flows grant: a re-grant of the regranted head whose flows
// are exactly the two granted.
export const flowsHeld = (head, { regranted, shape, kept, digest }) =>
  regrantHeld(head, {
    before: regranted, shape, digest, changes: { flows: [`files_by_grant to ${kept}`, `outside to ${kept}`] },
  });

// The revocation's answer, whole: the admission asked before it, admitted
// under `consent`; the first admission asked after it, refused with
// `refusal`; one attempt; and the time from the revocation's answer to that
// refusal, a whole number of microseconds within `boundUs`.
export const revokedHeld = (answer, { consent, refusal, boundUs }) =>
  isObject(answer) && sameSet(Object.keys(answer), ["attempts", "before", "refused", "refused_after_us"]) &&
  sameHead(answer.before, { admitted: true, consent_id: consent }) &&
  sameHead(answer.refused, { admitted: false, refusal }) &&
  answer.attempts === 1 && Number.isInteger(answer.refused_after_us) &&
  answer.refused_after_us >= 0 && answer.refused_after_us <= boundUs;
