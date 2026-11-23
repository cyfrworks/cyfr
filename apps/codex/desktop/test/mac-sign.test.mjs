// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {test} from "node:test"

import {Refused} from "../scripts/check-package.mjs"
import {APPLE, REHEARSAL, checkProfile, entitlements, kindOf, signingInputs, webauthnGroup} from "../scripts/mac-sign.mjs"

const team = "AB12CD34EF"
const der = Buffer.from([0x30, 0x82, 0x01, 0x00]).toString("base64")
const secret = "s3cret-value-never-printed"
const real = {APPLE_CERTIFICATE: der, APPLE_CERTIFICATE_PASSWORD: secret, APPLE_SIGNING_IDENTITY: `Developer ID Application: CYFR Works Inc. (${team})`,
  APPLE_TEAM_ID: team, APPLE_ID: "someone@example.com", APPLE_PASSWORD: secret, APPLE_PROVISIONING_PROFILE: der}
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
  assert.equal(got.appleId, real.APPLE_ID)
  assert.equal(got.applePassword, secret)
  assert.equal(got.rehearsed, false)
  assert.deepEqual(got.profile, Buffer.from(der, "base64"))
})

test("a distribution build refuses each missing Apple input, naming it and no value", () => {
  for (const name of APPLE) {
    for (const value of [undefined, ""]) {
      assert.throws(() => signingInputs({...real, [name]: value}), refusal(name), `${name}=${JSON.stringify(value)}`)
    }
  }
  assert.throws(() => signingInputs({...real, APPLE_TEAM_ID: "not a team"}), refusal("APPLE_TEAM_ID"))
  assert.throws(() => signingInputs({...real, APPLE_PROVISIONING_PROFILE: Buffer.from("<plist/>").toString("base64")}),
    refusal("APPLE_PROVISIONING_PROFILE"))
  assert.throws(() => signingInputs({...real, APPLE_CERTIFICATE: Buffer.from("PEM").toString("base64")}), refusal("APPLE_CERTIFICATE"))
})

test("a rehearsal takes its own inputs, refuses any Apple input beside them and notarises with nothing", () => {
  const got = signingInputs(rehearsal, {rehearse: true})
  assert.equal(got.rehearsed, true)
  assert.equal(got.appleId, null)
  assert.equal(got.applePassword, null)
  for (const name of REHEARSAL) assert.throws(() => signingInputs({...rehearsal, [name]: ""}, {rehearse: true}), refusal(name))
  for (const name of APPLE) {
    // Present at all, even empty, as a workflow sets a missing secret.
    assert.throws(() => signingInputs({...rehearsal, [name]: ""}, {rehearse: true}), refusal(name), name)
  }
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
})
