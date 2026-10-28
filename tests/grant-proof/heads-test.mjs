// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The grant proof's head predicates (heads.mjs), on heads shaped as the proof
// records them. The head the flows grant commits is held under the digest the
// command line previews for its decisions, and refused under any other digest,
// or with a flow, a domain, a revision or a consent the grant does not hold.
//
// Usage: node --test tests/grant-proof/heads-test.mjs

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  changedCopies, digestCopies, flowsHeld, grantedHeld, regrantHeld, revokedHeld, sameHead,
} from "./heads.mjs";

const KEPT = "alpha.grant.test";
const DROPPED = "beta.grant.test";
const digest = (hex) => `sha256:${hex.repeat(64)}`;
// An id as the home writes one: its kind's prefix and a UUID.
const id = (prefix, n) => `${prefix}_0000000${n}-0000-7000-8000-000000000000`;

const regranted = {
  revision: 2, consent_id: id("cons", 2), profile_id: id("prof", 1), admitted_origins: ["interactive"],
  domains: [KEPT], paths: ["data/probe/notes/"], flows: [`files_by_grant to ${KEPT}`],
  shape_digest: digest("1"), commit_digest: digest("2"),
};
const shape = digest("3");
const previewed = digest("4");
const flowHead = {
  revision: 3, consent_id: id("cons", 3), profile_id: id("prof", 1), admitted_origins: ["interactive"],
  domains: [KEPT], paths: ["data/probe/notes/"], flows: [`files_by_grant to ${KEPT}`, `outside to ${KEPT}`],
  shape_digest: shape, commit_digest: previewed,
};
const grant = { regranted, shape, kept: KEPT, digest: previewed };

test("the head the flows grant commits is held under the digest its decisions preview to", () => {
  assert.equal(flowsHeld(flowHead, grant), true);
});

test("a head committed under no digest, an empty or malformed one, or another digest is refused", () => {
  const { commit_digest: _omitted, ...withoutDigest } = flowHead;
  const others = [null, "", "sha256:wrong", digest("0"), regranted.commit_digest, undefined];
  for (const bad of [withoutDigest, ...others.map((commit_digest) => ({ ...flowHead, commit_digest }))]) {
    assert.equal(flowsHeld(bad, grant), false, `commit_digest ${JSON.stringify(bad.commit_digest)}`);
  }
});

test("with no digest to bind the head to, every head is refused", () => {
  const { commit_digest: _omitted, ...withoutDigest } = flowHead;
  for (const missing of [undefined, null, "", "sha256:wrong"]) {
    assert.equal(flowsHeld(flowHead, { ...grant, digest: missing }), false, `digest ${JSON.stringify(missing)}`);
    assert.equal(flowsHeld(withoutDigest, { ...grant, digest: missing }), false, `digest ${JSON.stringify(missing)}`);
  }
});

test("a head with an extra flow, an added domain or another revision is refused", () => {
  const copies = [
    { ...flowHead, flows: [...flowHead.flows, `outside to ${DROPPED}`] },
    { ...flowHead, domains: [...flowHead.domains, DROPPED] },
    { ...flowHead, revision: flowHead.revision + 1 },
  ];
  for (const copy of copies) assert.equal(flowsHeld(copy, grant), false);
});

test("a head with a host or a flow removed is refused, beside one with a host or a flow added", () => {
  const removed = [{ ...flowHead, domains: [] }, { ...flowHead, flows: [`outside to ${KEPT}`] }];
  for (const copy of removed) assert.equal(flowsHeld(copy, grant), false, JSON.stringify(copy));
  for (const copy of changedCopies(flowHead, DROPPED)) assert.equal(flowsHeld(copy, grant), false, JSON.stringify(copy));
  for (const copy of changedCopies(regranted, DROPPED)) assert.equal(sameHead(copy, regranted), false, JSON.stringify(copy));
});

test("the changed copies are another revision and a host and a flow each added and removed", () => {
  const [revision, hostAdded, hostRemoved, flowAdded, flowRemoved] = changedCopies(flowHead, DROPPED);
  assert.equal(revision.revision, flowHead.revision + 1);
  assert.deepEqual(hostAdded.domains, [KEPT, DROPPED]);
  assert.deepEqual(hostRemoved.domains, []);
  assert.deepEqual(flowAdded.flows, [...flowHead.flows, `outside to ${DROPPED}`]);
  assert.deepEqual(flowRemoved.flows, [`outside to ${KEPT}`]);
  assert.deepEqual(digestCopies(flowHead, regranted.commit_digest).map((copy) => copy.commit_digest),
    [null, "", "sha256:wrong", digest("0"), regranted.commit_digest]);
});

test("a head that keeps the regranted head's consent is refused", () => {
  assert.equal(flowsHeld({ ...flowHead, consent_id: regranted.consent_id }, grant), false);
});

const basePlan = digest("5");
const first = {
  revision: 1, consent_id: id("cons", 1), profile_id: id("prof", 1), admitted_origins: ["interactive"],
  domains: [KEPT], paths: ["data/probe/notes/"], flows: [`files_by_grant to ${KEPT}`],
  shape_digest: basePlan, commit_digest: digest("6"),
};
const firstGrant = {
  shape: basePlan, origins: ["interactive"], domains: [KEPT], paths: ["data/probe/notes/"],
  flows: [`files_by_grant to ${KEPT}`],
};

test("the head the first grant commits is held whole: revision 1, the decisions made, the plan's shape, a profile and a consent", () => {
  assert.equal(grantedHeld(first, firstGrant), true);
});

test("a first head with a field changed, missing or added is refused", () => {
  const { paths: _paths, ...withoutPaths } = first;
  const copies = [
    ...changedCopies(first, DROPPED),
    { ...first, shape_digest: digest("7") },
    { ...first, admitted_origins: ["interactive", "programmatic"] },
    { ...first, paths: ["data/probe/"] },
    { ...first, commit_digest: "sha256:wrong" },
    { ...first, commit_digest: null },
    { ...first, profile_id: null },
    { ...first, profile_id: "prof_probe" },
    { ...first, consent_id: undefined },
    { ...first, consent_id: id("prof", 1) },
    { ...first, background: true },
    withoutPaths,
  ];
  for (const copy of copies) assert.equal(grantedHeld(copy, firstGrant), false, JSON.stringify(copy));
});

test("a first grant asked under a malformed shape refuses every head", () => {
  for (const shape of [undefined, null, "", "sha256:wrong"]) {
    assert.equal(grantedHeld({ ...first, shape_digest: shape }, { ...firstGrant, shape }), false, `shape ${shape}`);
  }
});

test("the head a re-grant commits is the head before it one revision on, under a new consent, the new shape and the previewed digest", () => {
  const regrant = { before: first, shape: digest("8"), digest: digest("9") };
  const head = { ...first, revision: 2, consent_id: id("cons", 2), shape_digest: digest("8"), commit_digest: digest("9") };
  assert.equal(regrantHeld(head, regrant), true);
  const copies = [
    ...changedCopies(head, DROPPED),
    ...digestCopies(head, first.commit_digest),
    { ...head, consent_id: first.consent_id },
    { ...head, consent_id: "cons_new" },
    { ...head, profile_id: id("prof", 2) },
    { ...head, shape_digest: first.shape_digest },
    { ...head, admitted_origins: ["interactive", "programmatic"] },
    { ...head, paths: [] },
    { ...head, background: true },
  ];
  for (const copy of copies) assert.equal(regrantHeld(copy, regrant), false, JSON.stringify(copy));
  for (const missing of [undefined, null, "", "sha256:wrong"]) {
    assert.equal(regrantHeld(head, { ...regrant, digest: missing }), false, `digest ${missing}`);
    assert.equal(regrantHeld({ ...head, shape_digest: missing }, { ...regrant, shape: missing }), false, `shape ${missing}`);
  }
});

test("two heads hold the same fields, arrays as sets", () => {
  assert.equal(sameHead({ ...regranted, domains: [KEPT, DROPPED] }, { ...regranted, domains: [DROPPED, KEPT] }), true);
  assert.equal(sameHead({ ...regranted, domains: [KEPT, DROPPED] }, regranted), false);
  assert.equal(sameHead({ ...regranted, paths: [] }, regranted), false);
});

const revokedAnswer = {
  before: { admitted: true, consent_id: flowHead.consent_id }, refused: { admitted: false, refusal: ":no_profile" },
  attempts: 1, refused_after_us: 95,
};
const revocation = { consent: flowHead.consent_id, refusal: ":no_profile", boundUs: 5_000_000 };

test("a revocation's answer is held whole: admitted before under the last consent, refused next for want of a profile, one attempt, within the bound", () => {
  for (const refused_after_us of [95, 0, 5_000_000]) {
    assert.equal(revokedHeld({ ...revokedAnswer, refused_after_us }, revocation), true, `${refused_after_us} us`);
  }
});

test("a revocation's answer with a field changed, missing or added is refused", () => {
  const { attempts: _attempts, ...withoutAttempts } = revokedAnswer;
  const copies = [
    { ...revokedAnswer, attempts: 2 },
    { ...revokedAnswer, attempts: 0 },
    withoutAttempts,
    { ...revokedAnswer, before: { admitted: true, consent_id: regranted.consent_id } },
    { ...revokedAnswer, before: { admitted: false, refusal: ":no_profile" } },
    { ...revokedAnswer, before: null },
    { ...revokedAnswer, refused: { admitted: false, refusal: "consent_required" } },
    { ...revokedAnswer, refused: { admitted: true, consent_id: flowHead.consent_id } },
    { ...revokedAnswer, refused: { admitted: false, refusal: ":no_profile", reason: "revoked" } },
    { ...revokedAnswer, refused: null },
    { ...revokedAnswer, refused_after_us: 5_000_001 },
    { ...revokedAnswer, refused_after_us: -1 },
    { ...revokedAnswer, refused_after_us: 1.5 },
    { ...revokedAnswer, refused_after_us: "95" },
    { ...revokedAnswer, also: true },
  ];
  for (const copy of copies) assert.equal(revokedHeld(copy, revocation), false, JSON.stringify(copy));
  for (const answer of [null, undefined, [], "revoked"]) assert.equal(revokedHeld(answer, revocation), false);
});
