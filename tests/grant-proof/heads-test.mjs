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
  changedCopies, digestCopies, flowsHeld, grantedHeld, previewCopies, previewHeld, regrantHeld, revokedHeld, sameHead,
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

test("a head with no hosts or flows, as the answer for no profile, still has copies, each refused", () => {
  const none = { profile_id: null };
  const copies = changedCopies(none, DROPPED);
  assert.equal(copies.length, 5);
  for (const copy of copies) assert.equal(grantedHeld(copy, firstGrant), false, JSON.stringify(copy));
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
  shape: basePlan, digest: first.commit_digest, origins: ["interactive"], domains: [KEPT], paths: ["data/probe/notes/"],
  flows: [`files_by_grant to ${KEPT}`],
};

test("the head the first grant commits is held whole: revision 1, the decisions made, the plan's shape, a profile and a consent", () => {
  assert.equal(grantedHeld(first, firstGrant), true);
});

test("a first head with a field changed, missing or added is refused", () => {
  const { paths: _paths, ...withoutPaths } = first;
  const copies = [
    ...changedCopies(first, DROPPED),
    ...digestCopies(first),
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

test("a first grant asked under a malformed shape, or with no digest to bind it, refuses every head", () => {
  for (const bad of [undefined, null, "", "sha256:wrong"]) {
    assert.equal(grantedHeld({ ...first, shape_digest: bad }, { ...firstGrant, shape: bad }), false, `shape ${bad}`);
    assert.equal(grantedHeld({ ...first, commit_digest: bad }, { ...firstGrant, digest: bad }), false, `digest ${bad}`);
  }
});

// The command line's preview after the first grant, as
// `Sanctum.Consent.Commit.preview/2` answers it.
const PROOF_TOKEN = "Tq3xY0b_5Zr-8Kp2mW9vLc4HdJ7sFa1NoE6uRgViBkQ";
const preview = {
  v: 1, commit_digest: first.commit_digest, expected_consent_revision: 1, origins: ["interactive"], removed: [],
  proof: PROOF_TOKEN,
  rows: [
    { kind: "egress", node: "tincture:local.grant-probe", narrowed: true,
      values: { domains: [KEPT], methods: ["GET"], schemes: ["https"], private_ips: [] } },
    { kind: "storage", node: "tincture:local.grant-probe", narrowed: true,
      values: { paths: ["data/probe/notes/"], actions: ["read"] } },
    { kind: "exits", node: "tincture:local.grant-probe", narrowed: false,
      values: { exit: KEPT, flows: ["files_by_grant"] } },
  ],
};
const previewWant = { digest: first.commit_digest, revision: 1, origins: ["interactive"], domains: [KEPT], paths: ["data/probe/notes/"] };

test("the command line's preview is held whole: version 1, the digest and revision, the origins, nothing removed, a proof of the home's form, the narrowed rows", () => {
  assert.equal(PROOF_TOKEN.length, 43);
  assert.equal(previewHeld(preview, previewWant), true);
});

test("a preview with version 2, expected revision 99 and an empty proof is refused, and so is each change alone", () => {
  assert.equal(previewHeld({ ...preview, v: 2, expected_consent_revision: 99, proof: "" }, previewWant), false);
  for (const change of [{ v: 2 }, { expected_consent_revision: 99 }, { proof: "" }]) {
    assert.equal(previewHeld({ ...preview, ...change }, previewWant), false, JSON.stringify(change));
  }
});

test("each copy of a preview changes it and is refused", () => {
  const copies = previewCopies(preview, DROPPED);
  assert.equal(copies.length, 17);
  for (const copy of copies) {
    assert.equal(sameHead(copy, preview), false, JSON.stringify(copy));
    assert.equal(previewHeld(copy, previewWant), false, JSON.stringify(copy));
  }
});

test("a preview with a malformed proof, an unnarrowed or doubled row, or a row of another shape is refused", () => {
  const [egress, storage, exits] = preview.rows;
  const copies = [
    { ...preview, proof: PROOF_TOKEN.slice(1) },
    { ...preview, proof: `${PROOF_TOKEN.slice(1)}+` },
    { ...preview, proof: null },
    { ...preview, rows: [egress, egress, storage, exits] },
    { ...preview, rows: [egress, exits] },
    { ...preview, rows: [egress, { ...storage, narrowed: false }, exits] },
    { ...preview, rows: [egress, storage, { ...exits, also: true }] },
    { ...preview, rows: [egress, storage, { ...exits, narrowed: "no" }] },
    { ...preview, rows: [egress, storage, null] },
    { ...preview, rows: "rows" },
  ];
  for (const copy of copies) assert.equal(previewHeld(copy, previewWant), false, JSON.stringify(copy));
  for (const want of [{ ...previewWant, revision: 2 }, { ...previewWant, digest: digest("7") }, { ...previewWant, revision: undefined }]) {
    assert.equal(previewHeld(preview, want), false, JSON.stringify(want));
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

test("an admission or a plan is compared whole: another value, a missing field or an added one differs", () => {
  const admitted = { admitted: true, consent_id: regranted.consent_id };
  assert.equal(sameHead({ ...admitted }, admitted), true);
  for (const other of [
    { ...admitted, consent_id: flowHead.consent_id }, { admitted: true }, { ...admitted, refusal: "consent_required" },
    { admitted: false, refusal: "consent_required" },
  ]) assert.equal(sameHead(other, admitted), false, JSON.stringify(other));
  const plan = { shape_digest: shape, background: true };
  for (const other of [{ ...plan, background: false }, { shape_digest: shape }, { ...plan, rows: [] }]) {
    assert.equal(sameHead(other, plan), false, JSON.stringify(other));
  }
  for (const other of [null, undefined, "admitted", [admitted]]) assert.equal(sameHead(other, admitted), false);
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
