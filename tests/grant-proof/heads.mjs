// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The head predicates of the grant proof (proof.mjs): what two heads hold in
// common, what the head the first grant commits holds, what the head a
// re-grant commits holds, and what a revocation answers, with the copies of a
// head each must refuse. They are kept apart from the proof so heads-test.mjs
// can run them on heads without a browser.

const DIGEST = /^sha256:[0-9a-f]{64}$/;
// An id as the home mints one: its kind's prefix and a UUIDv7
// (`Prima.UUID7`), version nibble 7 and variant 8, 9, a or b.
const UUID7 = "[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
const PROFILE = new RegExp(`^prof_${UUID7}$`);
const CONSENT = new RegExp(`^cons_${UUID7}$`);
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
// A commit proof: 32 random bytes the home mints for one commit, URL-safe
// base64 without padding (`Sanctum.Consent.Proof.mint_token/0`).
const PROOF = /^[A-Za-z0-9_-]{43}$/;
const PREVIEW_KEYS = ["commit_digest", "expected_consent_revision", "origins", "proof", "removed", "rows", "v"];
const ROW_KEYS = ["kind", "narrowed", "node", "values"];

// Arrays as sets, so an extra or a missing flow, domain or path differs.
export const sameSet = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());

// Two heads hold the same fields, arrays as sets and every other field exactly.
// Anything but an object holds no head.
export const sameHead = (a, b) =>
  isObject(a) && isObject(b) &&
  [...new Set([...Object.keys(a), ...Object.keys(b)])].every((k) =>
    Array.isArray(a[k]) && Array.isArray(b[k]) ? sameSet(a[k], b[k]) : a[k] === b[k]);

// The copies that change their object: a copy equal to it changed nothing,
// and a row that refused it would show nothing, so it is not made.
const changing = (object, copies) => copies.filter((copy) => !sameHead(copy, object));

// Copies of a head a change of permission would leave behind, each of which
// a row's predicate must refuse: another revision, a host added or removed,
// and a flow added or removed (no removal from an empty list, which changes
// nothing). A head with no hosts or flows, as the answer for no profile is,
// still has its copies, so its row records the refusal rather than the proof
// throwing before it.
export const changedCopies = (head, dropped) => {
  const domains = Array.isArray(head.domains) ? head.domains : [];
  const flows = Array.isArray(head.flows) ? head.flows : [];
  return changing(head, [
    { ...head, revision: head.revision + 1 },
    { ...head, domains: [...domains, dropped] },
    { ...head, domains: domains.slice(1) },
    { ...head, flows: [...flows, `outside to ${dropped}`] },
    { ...head, flows: flows.slice(1) },
  ]);
};

// Copies of a head committed under no digest, an empty or malformed one, a
// well-formed digest no preview answered, and `previous`, when given, the
// digest the head before it held; none that is the head's own digest.
export const digestCopies = (head, previous) =>
  changing(head, [null, "", "sha256:wrong", `sha256:${"0".repeat(64)}`, ...(previous === undefined ? [] : [previous])]
    .map((commit_digest) => ({ ...head, commit_digest })));

// The head the first grant commits: revision 1 and exactly the decisions the
// person made (origins, hosts, folders and flows, as sets), under the shape the
// version's plan asks and `digest`, the command line's preview of the same
// decisions, held by an owner profile and a consent of their own.
export const grantedHeld = (head, { shape, digest, origins, domains, paths, flows }) =>
  PROFILE.test(head.profile_id) && CONSENT.test(head.consent_id) && DIGEST.test(digest) && DIGEST.test(shape) &&
  sameHead(head, {
    profile_id: head.profile_id, consent_id: head.consent_id, commit_digest: digest,
    revision: 1, shape_digest: shape, admitted_origins: origins, domains, paths, flows,
  });

// The one row of `kind` among a preview's rows, or none.
const onlyRow = (rows, kind) => {
  const of = rows.filter((row) => isObject(row) && row.kind === kind);
  return of.length === 1 ? of[0] : null;
};

// The command line's preview of a grant's decisions, whole
// (`Sanctum.Consent.Commit.preview/2`): document version 1, `digest`, the
// head's `revision` as the one a commit must find, exactly the origins
// granted, no binding removed from the head, and a single-use proof of the
// form the home mints, which nothing here can derive. Its rows are the
// version's ask under the decisions, which the digest binds: each has the
// documented keys, and the one host row and the one folder row are narrowed to
// exactly `domains` and `paths`.
export const previewHeld = (answer, { digest, revision, origins, domains, paths }) => {
  if (!isObject(answer) || !sameSet(Object.keys(answer), PREVIEW_KEYS) || !Array.isArray(answer.rows)) return false;
  const egress = onlyRow(answer.rows, "egress");
  const storage = onlyRow(answer.rows, "storage");
  return answer.v === 1 && DIGEST.test(digest) && answer.commit_digest === digest &&
    Number.isInteger(revision) && answer.expected_consent_revision === revision &&
    Array.isArray(answer.origins) && sameSet(answer.origins, origins) &&
    Array.isArray(answer.removed) && answer.removed.length === 0 &&
    typeof answer.proof === "string" && PROOF.test(answer.proof) &&
    answer.rows.length > 0 &&
    answer.rows.every((row) => isObject(row) && sameSet(Object.keys(row), ROW_KEYS) && typeof row.kind === "string" &&
      typeof row.node === "string" && isObject(row.values) && typeof row.narrowed === "boolean") &&
    egress !== null && egress.narrowed === true && Array.isArray(egress.values.domains) &&
    sameSet(egress.values.domains, domains) &&
    storage !== null && storage.narrowed === true && Array.isArray(storage.values.paths) &&
    sameSet(storage.values.paths, paths);
};

// Copies of a preview's answer, each of which its row must refuse: another
// document version, another expected revision, an empty or malformed proof,
// those three at once, another origin, a binding removed, a field added or
// missing, the host or folder row widened, the host row not narrowed, no rows,
// and its digest copies. A copy equal to the answer changes nothing, so none
// is made.
export const previewCopies = (answer, dropped) => {
  if (!isObject(answer)) return [];
  const { proof: _proof, ...withoutProof } = answer;
  const rows = Array.isArray(answer.rows) ? answer.rows : [];
  const rowsWith = (kind, change) => rows.map((row) => (isObject(row) && row.kind === kind ? change(row) : row));
  const widened = (field, extra) => (row) =>
    ({ ...row, values: { ...row.values, [field]: [...(row.values?.[field] ?? []), extra] } });
  return changing(answer, [
    { ...answer, v: 2 },
    { ...answer, expected_consent_revision: 99 },
    { ...answer, proof: "" },
    { ...answer, proof: `${answer.proof}=` },
    { ...answer, v: 2, expected_consent_revision: 99, proof: "" },
    { ...answer, origins: [...(answer.origins ?? []), "programmatic"] },
    { ...answer, removed: [{ need: "feed" }] },
    { ...answer, also: true },
    withoutProof,
    { ...answer, rows: rowsWith("egress", widened("domains", dropped)) },
    { ...answer, rows: rowsWith("storage", widened("paths", "data/probe/")) },
    { ...answer, rows: rowsWith("egress", (row) => ({ ...row, narrowed: false })) },
    { ...answer, rows: [] },
    ...digestCopies(answer),
  ]);
};

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
