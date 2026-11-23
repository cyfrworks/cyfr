// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {mkdtempSync, readFileSync, rmSync} from "node:fs"
import {tmpdir} from "node:os"
import path from "node:path"
import {test} from "node:test"

import {Refused} from "../scripts/check-package.mjs"
import {APPLE, REHEARSAL, checkProfile, entitlements, ignoring, kindOf, signingInputs, tool, webauthnGroup} from "../scripts/mac-sign.mjs"

const team = "AB12CD34EF"
const der = Buffer.from([0x30, 0x82, 0x01, 0x00]).toString("base64")
const secret = "s3cret-value-never-printed"
const p8 = "-----BEGIN PRIVATE KEY-----\nTUlHVEFnRUFNQk1HQnlxR1NNNDlBZ0VHQ0NxR1NNNDlBd0VIQkhrd2R3SUJBUVFn\n-----END PRIVATE KEY-----\n"
const keyId = "2X9R4HXF34"
const issuer = "57246542-96fe-1a63-e053-0824d011072a"
const real = {APPLE_CERTIFICATE: der, APPLE_CERTIFICATE_PASSWORD: secret, APPLE_SIGNING_IDENTITY: `Developer ID Application: CYFR Works Inc. (${team})`,
  APPLE_TEAM_ID: team, APPLE_PROVISIONING_PROFILE: der, APPLE_API_KEY: Buffer.from(p8).toString("base64"),
  APPLE_API_KEY_ID: keyId, APPLE_API_ISSUER: issuer}
const rehearsal = {CYFR_REHEARSAL_CERTIFICATE: der, CYFR_REHEARSAL_CERTIFICATE_PASSWORD: secret,
  CYFR_REHEARSAL_SIGNING_IDENTITY: `Developer ID Application: CYFR Rehearsal (${team})`, CYFR_REHEARSAL_TEAM_ID: team,
  CYFR_REHEARSAL_PROVISIONING_PROFILE: der}

// A refusal that names `name` and none of the inputs' values.
const refusal = (name) => (e) => e instanceof Refused && e.message.includes(name) &&
  !Object.values({...real, ...rehearsal}).some((v) => e.message.includes(v))

test("a distribution build takes every Apple input, and its group from the team", () => {
  const got = signingInputs(real)
  assert.equal(got.identity, `CYFR Works Inc. (${team})`)
  assert.equal(got.team, team)
  assert.equal(got.group, `${team}.run.cyfr.desktop.webauthn`)
  assert.deepEqual(got.notary, {key: p8, keyId, issuer})
  assert.equal(got.rehearsed, false)
  assert.deepEqual(got.profile, Buffer.from(der, "base64"))
})

test("a distribution build refuses each missing Apple input, naming it and no value", () => {
  for (const name of APPLE) {
    for (const value of [undefined, ""]) {
      assert.throws(() => signingInputs({...real, [name]: value}), refusal(name), `${name}=${JSON.stringify(value)}`)
    }
  }
  assert.throws(() => signingInputs({...real, APPLE_TEAM_ID: "ab12-cd34"}),
    (e) => refusal("APPLE_TEAM_ID")(e) && !e.message.includes("ab12-cd34"))
  assert.throws(() => signingInputs({...real, APPLE_PROVISIONING_PROFILE: Buffer.from("<plist/>").toString("base64")}),
    refusal("APPLE_PROVISIONING_PROFILE"))
  assert.throws(() => signingInputs({...real, APPLE_CERTIFICATE: Buffer.from("PEM").toString("base64")}), refusal("APPLE_CERTIFICATE"))
  assert.throws(() => signingInputs({...real, APPLE_API_KEY: Buffer.from("not a key").toString("base64")}), refusal("APPLE_API_KEY"))
  assert.throws(() => signingInputs({...real, APPLE_API_KEY_ID: "short"}), refusal("APPLE_API_KEY_ID"))
  assert.throws(() => signingInputs({...real, APPLE_API_ISSUER: "not-a-uuid"}), refusal("APPLE_API_ISSUER"))
  // The Apple ID and its password are read by nothing.
  assert.deepEqual(signingInputs({...real, APPLE_ID: "someone@example.com", APPLE_PASSWORD: secret}).notary, {key: p8, keyId, issuer})
})

// The Apple inputs, exactly: the notary's team key, and no Apple ID.
test("the Apple inputs are the identity, the profile and the notary's team key", () => {
  assert.deepEqual(APPLE, ["APPLE_CERTIFICATE", "APPLE_CERTIFICATE_PASSWORD", "APPLE_SIGNING_IDENTITY", "APPLE_TEAM_ID",
    "APPLE_PROVISIONING_PROFILE", "APPLE_API_KEY", "APPLE_API_KEY_ID", "APPLE_API_ISSUER"])
})

test("a rehearsal takes its own inputs, refuses any Apple input beside them and notarises with nothing", () => {
  const got = signingInputs(rehearsal, {rehearse: true})
  assert.equal(got.rehearsed, true)
  assert.equal(got.notary, null)
  for (const name of REHEARSAL) assert.throws(() => signingInputs({...rehearsal, [name]: ""}, {rehearse: true}), refusal(name))
  for (const name of APPLE) {
    // Present at all, even empty, as a workflow sets a missing secret.
    assert.throws(() => signingInputs({...rehearsal, [name]: ""}, {rehearse: true}), refusal(name), name)
  }
  assert.throws(() => signingInputs({...rehearsal, ...real}, {rehearse: true}), (e) => APPLE.every((n) => refusal(n)(e)), "every Apple input")
  // Nor does a release build take a rehearsal's inputs for its own.
  assert.throws(() => signingInputs(rehearsal), refusal("APPLE_CERTIFICATE"))
})

const group = webauthnGroup(team)
const profile = (change = {}) => ({
  ProvisionsAllDevices: true, TeamIdentifier: [team], ExpirationDate: new Date("2027-11-23T00:00:00Z"),
  ...change,
  Entitlements: {"com.apple.application-identifier": `${team}.run.cyfr.desktop`, "com.apple.developer.team-identifier": team,
    "keychain-access-groups": [`${team}.*`], ...change.Entitlements}
})
const now = new Date("2026-11-23T00:00:00Z")

test("the app's Developer ID profile passes, with the group exactly or the team's wildcard", () => {
  checkProfile(profile(), {team, group, now})
  checkProfile(profile({Entitlements: {"keychain-access-groups": [group]}}), {team, group, now})
})

test("a wrong profile is refused", () => {
  const cases = {
    "a development profile": profile({ProvisionsAllDevices: undefined, ProvisionedDevices: ["00008103-000A"]}),
    "another team's": profile({TeamIdentifier: ["ZZ99ZZ99ZZ"]}),
    "another team's entitlement": profile({Entitlements: {"com.apple.developer.team-identifier": "ZZ99ZZ99ZZ"}}),
    "another app's": profile({Entitlements: {"com.apple.application-identifier": `${team}.run.cyfr.other`}}),
    "no keychain groups": profile({Entitlements: {"keychain-access-groups": undefined}}),
    "another group": profile({Entitlements: {"keychain-access-groups": [`${team}.run.cyfr.desktop.other`]}}),
    "another team's wildcard": profile({Entitlements: {"keychain-access-groups": ["ZZ99ZZ99ZZ.*"]}}),
    "expired": profile({ExpirationDate: new Date("2026-11-22T23:59:59Z")}),
    "no expiry": profile({ExpirationDate: undefined})
  }
  for (const [name, p] of Object.entries(cases)) assert.throws(() => checkProfile(p, {team, group, now}), Refused, name)
  assert.throws(() => checkProfile(undefined, {team, group, now}), Refused, "nothing decoded")
})

test("only the app holds the group; the helpers hold V8's JIT; nothing holds a device", () => {
  const want = entitlements(team, group)
  assert.deepEqual(want.main, {"com.apple.security.cs.allow-jit": true, "com.apple.application-identifier": `${team}.run.cyfr.desktop`,
    "com.apple.developer.team-identifier": team, "keychain-access-groups": [group]})
  assert.deepEqual(want.helper, {"com.apple.security.cs.allow-jit": true})
  assert.deepEqual(want.none, {})
  for (const dict of Object.values(want)) {
    assert.ok(!Object.keys(dict).some((k) => /device|personal-information|disable-library-validation|unsigned-executable/.test(k)))
  }
})

test("each signed file is the kind its place makes it", () => {
  const app = "/out/mac-arm64/CYFR.app"
  const kinds = {
    [app]: "main",
    [`${app}/Contents/MacOS/CYFR`]: "main",
    [`${app}/Contents/Frameworks/CYFR Helper.app`]: "helper",
    [`${app}/Contents/Frameworks/CYFR Helper (GPU).app/Contents/MacOS/CYFR Helper (GPU)`]: "helper",
    [`${app}/Contents/Frameworks/CYFR Helper (Plugin).app`]: "helper",
    [`${app}/Contents/Frameworks/CYFR Helper (Renderer).app/Contents/MacOS/CYFR Helper (Renderer)`]: "helper",
    [`${app}/Contents/Resources/cyfr`]: "none",
    [`${app}/Contents/Frameworks/Electron Framework.framework`]: "none",
    [`${app}/Contents/Frameworks/Electron Framework.framework/Versions/A/Helpers/chrome_crashpad_handler`]: "none",
    [`${app}/Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt`]: "none",
    [`${app}/Contents/Frameworks/CYFR Helper (GPU).app/Contents/Info.plist`]: "none",
    [`${app}/Contents/Frameworks/CYFR Helper (Evil).app`]: "none"
  }
  for (const [file, kind] of Object.entries(kinds)) assert.equal(kindOf(app, file), kind, file)
  // The app as a temporary folder spelled with "//" names it, its files
  // as a walk joins them.
  for (const [file, kind] of Object.entries(kinds)) {
    assert.equal(kindOf("/out//mac-arm64/CYFR.app", file), kind, `${file} under an unnormalised app`)
    assert.equal(kindOf(app, file.replace("/out/", "/out//")), kind, `${file} unnormalised`)
  }
})

// Each step that could wait on a person, or on Apple, ends in a sentence
// within its bound, and what it started ends with it.
test("a tool that outlives its bound is refused, and everything it started is stopped", {skip: process.platform === "win32"}, (t) => {
  const dir = mkdtempSync(path.join(tmpdir(), "cyfr-bound-"))
  t.after(() => rmSync(dir, {recursive: true, force: true}))
  const pid = path.join(dir, "pid")
  const started = Date.now()
  assert.throws(() => tool("sh", ["-c", `sleep 30 & echo $! > ${pid}; wait`], 1),
    (e) => e instanceof Refused && e.message === "sh -c did not answer in 1 seconds")
  assert.ok(Date.now() - started < 10000, "the bound held")
  const grandchild = Number(readFileSync(pid, "utf8"))
  assert.ok(gone(grandchild), "the tool's own child was stopped with it")
  assert.equal(tool("true", []).ok, true)
  assert.deepEqual(tool("sh", ["-c", "echo said; exit 3"]), {ok: false, status: 3, out: "said\n", err: ""})
  assert.throws(() => tool("cyfr-no-such-tool", []), (e) => e instanceof Refused && /could not be run/.test(e.message))
})

// Electron's signing skips the cyfr the recipe signed first, and what
// electron-builder skips, through one function: an array would be dropped.
test("Electron's signing skips the signed cyfr and what electron-builder skips", () => {
  const app = "/out/mac-arm64/CYFR.app"
  const helper = `${app}/Contents/Resources/cyfr`
  const builders = (file) => file.endsWith(".kext")
  for (const given of [builders, [builders], undefined]) {
    const skip = ignoring(given, helper)
    assert.equal(typeof skip, "function")
    assert.equal(skip(helper), true)
    assert.equal(skip(`${app}/Contents/MacOS/CYFR`), false)
    assert.equal(skip(`${app}/Contents/Resources/cyfr.other`), false)
    if (given) assert.equal(skip(`${app}/Contents/Library/x.kext`), true)
  }
  assert.equal(ignoring(/\.kext$/, helper)(`${app}/a.kext`), true)
  // However either path is spelled.
  assert.equal(ignoring(undefined, "/out//mac-arm64/CYFR.app/Contents/Resources/cyfr")(helper), true)
  assert.equal(ignoring(undefined, helper)("/out/mac-arm64//CYFR.app/Contents/./Resources/cyfr"), true)
})

// Whether the process `pid` has ended within five seconds: a killed child
// lingers until whoever adopted it collects it, so this waits for that.
function gone(pid) {
  const until = Date.now() + 5000
  for (;;) {
    try {
      process.kill(pid, 0)
      const state = (() => { try { return readFileSync(`/proc/${pid}/stat`, "utf8").split(") ")[1]?.[0] } catch { return null } })()
      if (state === "Z") return true
    } catch (e) {
      if (e.code === "ESRCH") return true
      throw e
    }
    if (Date.now() > until) return false
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50)
  }
}
