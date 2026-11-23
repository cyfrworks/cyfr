// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The Mac app's distribution signing: what a distribution build of the
// app (build.mjs --distribution) takes from its environment, the
// entitlements each signed file gets, the provisioning profile's check,
// and the check of the finished DMG.
//
// A distribution build signs with the Developer ID identity in
// APPLE_CERTIFICATE (a base64 .p12, opened by APPLE_CERTIFICATE_PASSWORD;
// APPLE_SIGNING_IDENTITY names it, APPLE_TEAM_ID is its team), embeds
// APPLE_PROVISIONING_PROFILE (a base64 Developer ID .provisionprofile),
// which authorises the app's WebAuthn keychain group TEAM.run.cyfr.desktop.webauthn,
// and notarises with APPLE_ID and its app-specific APPLE_PASSWORD. A
// rehearsal (--rehearse) takes the same inputs under CYFR_REHEARSAL_*
// names, for a self-made identity and profile, notarises nothing, and is
// refused when any APPLE_* input is in its environment, so one build never
// mixes the two. No message names an input's value.
//
// Each Mach-O file and bundle is signed with the hardened runtime and a
// secure timestamp, the bundled cyfr first: checked again as the verified
// one, signed, and its signed bytes' SHA-256 kept, which the finished app
// must hold. CYFR.app gets the main entitlements (V8's JIT, the
// application and team identifiers and the WebAuthn group, which the
// profile must authorise); the four helper apps get the JIT alone;
// everything else, the bundled cyfr among it, gets none. No file gets a
// camera, microphone or other device entitlement.
//
//   node scripts/mac-sign.mjs check DMG|APP --cyfr-sha256 HEX [--rehearsed]
//
// checks a built DMG, or an app, against the same inputs (a rehearsal's
// names with --rehearsed): every signature, its entitlements, the embedded
// profile and the bundled cyfr, whose signed SHA-256 the build printed;
// without --rehearsed also Apple's notarisation, stapled
// to the DMG and to the app, and Gatekeeper's assessment of both, which no
// rehearsed DMG passes.

import {spawnSync} from "node:child_process"
import {createHash} from "node:crypto"
import {lstatSync, mkdtempSync, openSync, readFileSync, readSync, closeSync, readdirSync, rmSync, writeFileSync} from "node:fs"
import {createRequire} from "node:module"
import {tmpdir} from "node:os"
import path from "node:path"
import {fileURLToPath} from "node:url"
import {parseArgs} from "node:util"

import {Refused} from "./check-package.mjs"

export const APP_ID = "run.cyfr.desktop"

// electron-builder's own copies of the property list reader and of
// Electron's signing and notarising, the versions package-lock.json pins.
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
export const need = createRequire(path.join(root, "node_modules", "app-builder-lib", "package.json"))
const plist = need("plist")

export const APPLE = ["APPLE_CERTIFICATE", "APPLE_CERTIFICATE_PASSWORD", "APPLE_SIGNING_IDENTITY", "APPLE_TEAM_ID",
  "APPLE_ID", "APPLE_PASSWORD", "APPLE_PROVISIONING_PROFILE"]
export const REHEARSAL = ["CYFR_REHEARSAL_CERTIFICATE", "CYFR_REHEARSAL_CERTIFICATE_PASSWORD", "CYFR_REHEARSAL_SIGNING_IDENTITY",
  "CYFR_REHEARSAL_TEAM_ID", "CYFR_REHEARSAL_PROVISIONING_PROFILE"]

/** The WebAuthn keychain group the app's passkeys live in, for team. */
export const webauthnGroup = (team) => `${team}.${APP_ID}.webauthn`

/**
 * The signing inputs in env: {certificate, certificatePassword, identity,
 * team, group, profile (bytes), appleId, applePassword (null when
 * rehearsed), rehearsed}. Throws Refused naming the input, never its value.
 */
export function signingInputs(env, {rehearse = false} = {}) {
  if (rehearse) {
    const real = APPLE.filter((name) => env[name] !== undefined)
    if (real.length) throw new Refused(`a rehearsal takes no Apple input, and ${real.join(", ")} is set`)
  }
  const names = rehearse ? REHEARSAL : APPLE
  for (const name of names) if (!env[name]) throw new Refused(`${name} is not set`)
  const [certificate, certificatePassword, identity, team, profile] = names.filter((n) => !/^APPLE_(ID|PASSWORD)$/.test(n))
  if (!/^[A-Z0-9]{10}$/.test(env[team])) throw new Refused(`${team} is not a team ID`)
  const p12 = Buffer.from(env[certificate], "base64")
  if (p12[0] !== 0x30) throw new Refused(`${certificate} is not a base64 .p12`)
  const bytes = Buffer.from(env[profile], "base64")
  if (bytes[0] !== 0x30) throw new Refused(`${profile} is not a base64 provisioning profile`)
  return {
    certificate: env[certificate], certificatePassword: env[certificatePassword],
    // electron-builder takes the identity's name without its kind.
    identity: env[identity].replace(/^Developer ID Application: /, ""),
    team: env[team], group: webauthnGroup(env[team]), profile: bytes,
    appleId: rehearse ? null : env.APPLE_ID, applePassword: rehearse ? null : env.APPLE_PASSWORD, rehearsed: rehearse
  }
}

/**
 * Check a decoded provisioning profile (its property list, as plist reads
 * it) against the team and group: a Developer ID profile of that team, for
 * this app, authorising the group, not expired. Throws Refused.
 */
export function checkProfile(profile, {team, group, now = new Date()}) {
  const entitlements = profile?.Entitlements ?? {}
  if (profile?.ProvisionsAllDevices !== true) throw new Refused("the provisioning profile is not a Developer ID profile")
  if (!Array.isArray(profile.TeamIdentifier) || !profile.TeamIdentifier.includes(team)) {
    throw new Refused("the provisioning profile is for another team")
  }
  if (entitlements["com.apple.developer.team-identifier"] !== team) throw new Refused("the provisioning profile is for another team")
  if (entitlements["com.apple.application-identifier"] !== `${team}.${APP_ID}`) {
    throw new Refused(`the provisioning profile is not for ${APP_ID}`)
  }
  const groups = entitlements["keychain-access-groups"]
  if (!Array.isArray(groups) || !groups.some((g) => g === group || g === `${team}.*`)) {
    throw new Refused("the provisioning profile does not authorise the app's WebAuthn group")
  }
  if (!(profile.ExpirationDate instanceof Date) || profile.ExpirationDate <= now) {
    throw new Refused("the provisioning profile has expired")
  }
}

/** The entitlements of each kind of signed file, for team and group. */
export function entitlements(team, group) {
  return {
    main: {
      "com.apple.security.cs.allow-jit": true,
      "com.apple.application-identifier": `${team}.${APP_ID}`,
      "com.apple.developer.team-identifier": team,
      "keychain-access-groups": [group]
    },
    helper: {"com.apple.security.cs.allow-jit": true},
    none: {}
  }
}

const HELPER = /^Contents\/Frameworks\/CYFR Helper( \((GPU|Plugin|Renderer)\))?\.app(\/Contents\/MacOS\/[^/]+)?$/

/**
 * Which entitlements the file at `file` (an absolute path) inside the app
 * at `app` gets: "main" for the app and its executable, "helper" for a
 * helper app and its executable, "none" for every other. Either path may
 * be spelled unnormalised, as a temporary folder ending in "/" makes it.
 */
export function kindOf(app, file) {
  const inside = path.relative(app, file).replaceAll("\\", "/")
  if (inside === "" || inside === "Contents/MacOS/CYFR") return "main"
  return HELPER.test(inside) ? "helper" : "none"
}

/** The three entitlement files, written in dir: {main, helper, none} paths. */
export function writeEntitlements(dir, team, group) {
  const out = {}
  for (const [kind, dict] of Object.entries(entitlements(team, group))) {
    out[kind] = path.join(dir, `entitlements.${kind}.plist`)
    writeFileSync(out[kind], plist.build(dict))
  }
  return out
}

/**
 * What Electron's signing skips: what electron-builder's `ignore` skips,
 * and the cyfr at `helper`, which is signed already. One function, as
 * @electron/osx-sign 1.3.3 drops an `ignore` given as an array
 * (validateOptsIgnore in its sign.js) and would sign cyfr a second time.
 */
export function ignoring(ignore, helper) {
  const skipped = [ignore ?? []].flat()
  const signed = path.resolve(helper)
  return (file) => path.resolve(file) === signed ||
    skipped.some((it) => (typeof it === "function" ? it(file) : file.match(it) !== null))
}

/**
 * electron-builder's mac.sign for a distribution build, given the
 * entitlement files, the verified cyfr's SHA-256 and `signed`, where the
 * signed cyfr's SHA-256 is kept as signed.helper. The bundled cyfr is
 * checked again, then signed with the hardened runtime, a timestamp and no
 * entitlements; then Electron's own signing signs every other file inside
 * out, with the entitlements of its kind, and embeds the profile.
 */
export function signer(files, verified, signed) {
  return async (opts) => {
    const helper = path.join(opts.app, "Contents", "Resources", "cyfr")
    if (sha256(helper) !== verified) throw new Refused("CYFR.app/Contents/Resources/cyfr is not the verified cyfr")
    must("codesign", ["--sign", opts.identity, "--force", ...(opts.keychain ? ["--keychain", opts.keychain] : []),
      "--timestamp", "--options", "runtime", helper], "the bundled cyfr was not signed")
    signed.helper = sha256(helper)
    const {signAsync} = need("@electron/osx-sign")
    await signAsync({...opts, preAutoEntitlements: false, preEmbedProvisioningProfile: true,
      ignore: ignoring(opts.ignore, helper),
      optionsForFile: (file) => ({hardenedRuntime: true, entitlements: files[kindOf(opts.app, file)]})})
  }
}

/**
 * Run a macOS tool that could wait on a person (a keychain's prompt, a
 * mounted image, Apple's servers): {ok, out, err}, or Refused when it has
 * not answered in `seconds`.
 */
export function tool(cmd, args, seconds = 120) {
  const r = spawnSync(cmd, args, {encoding: "utf8", timeout: seconds * 1000, killSignal: "SIGKILL"})
  if (r.error?.code === "ETIMEDOUT") throw new Refused(`${cmd} ${args[0]} did not answer in ${seconds} seconds`)
  if (r.error) throw r.error
  return {ok: r.status === 0, out: r.stdout, err: r.stderr}
}

// A tool's run that must succeed, or Refused saying `what`.
function must(cmd, args, what, seconds) {
  const r = tool(cmd, args, seconds)
  if (!r.ok) throw new Refused(`${what}: ${(r.err || r.out).trim()}`)
  return r
}

/**
 * The promise `work`, or Refused saying `what` when it has not settled in
 * `minutes`: electron-builder's build and Apple's notary run in this
 * process, where a timer is their bound.
 */
export function within(work, minutes, what) {
  let timer
  const bound = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Refused(`${what} did not finish in ${minutes} minutes`)), minutes * 60000)
  })
  return Promise.race([work, bound]).finally(() => clearTimeout(timer))
}

/** The decoded property list of a provisioning profile's bytes (macOS). */
export function decodeProfile(bytes) {
  const dir = mkdtempSync(path.join(tmpdir(), "cyfr-profile-"))
  try {
    writeFileSync(path.join(dir, "p"), bytes)
    return plist.parse(must("security", ["cms", "-D", "-i", path.join(dir, "p")], "the provisioning profile does not decode").out)
  } finally {
    rmSync(dir, {recursive: true, force: true})
  }
}

const MACHO = new Set(["feedface", "feedfacf", "cefaedfe", "cffaedfe", "cafebabe", "bebafeca"])
function isMachO(file) {
  const fd = openSync(file, "r")
  try {
    const head = Buffer.alloc(4)
    return readSync(fd, head, 0, 4, 0) === 4 && MACHO.has(head.toString("hex"))
  } finally {
    closeSync(fd)
  }
}

/** The app, its nested bundles and Mach-O files, inner first; no link is followed. */
export function signedCode(app) {
  const out = []
  const walk = (at) => {
    for (const name of readdirSync(at)) {
      const p = path.join(at, name)
      const st = lstatSync(p)
      if (st.isSymbolicLink()) continue
      if (st.isDirectory()) {
        walk(p)
        if (/\.(app|framework)$/.test(name)) out.push(p)
      } else if (isMachO(p)) out.push(p)
    }
  }
  walk(app)
  out.push(app)
  return out
}

const codesign = (args) => tool("codesign", args)
const sha256 = (file) => createHash("sha256").update(readFileSync(file)).digest("hex")


/**
 * Check a signed CYFR.app at `app`: it embeds the supplied profile, which
 * checkProfile passes for the team and group and which lists the app's
 * signing certificate; each signature verifies strictly, is by that
 * certificate, hardened and timestamped, with exactly its kind's
 * entitlements; the bundled cyfr is the one the build signed, whose
 * SHA-256 is `helper`.
 * Throws Refused naming the first difference.
 */
export function checkApp(app, {helper, team, group, profile}) {
  must("codesign", ["--verify", "--deep", "--strict", "--verbose=2", app], "CYFR.app's signature does not verify")
  const embedded = path.join(app, "Contents", "embedded.provisionprofile")
  let bytes
  try { bytes = readFileSync(embedded) } catch { throw new Refused("CYFR.app embeds no provisioning profile") }
  if (!bytes.equals(profile)) throw new Refused("CYFR.app embeds another provisioning profile")
  const decoded = decodeProfile(profile)
  checkProfile(decoded, {team, group})
  const want = entitlements(team, group)
  const dir = mkdtempSync(path.join(tmpdir(), "cyfr-signed-"))
  try {
    // The first certificate of a signature is its signer's.
    let read = 0
    const signer = (file) => {
      const prefix = path.join(dir, `c${read++}.`)
      must("codesign", ["-d", `--extract-certificates=${prefix}`, file], `${path.basename(file)}'s certificate was not read`)
      return readFileSync(`${prefix}0`)
    }
    const leaf = signer(app)
    if (!(decoded.DeveloperCertificates ?? []).some((c) => Buffer.from(c).equals(leaf))) {
      throw new Refused("the provisioning profile does not list CYFR.app's signing certificate")
    }
    for (const file of signedCode(app)) checkSignature(app, file, leaf, signer, want)
    if (!helper) throw new Refused("the build did not sign the bundled cyfr")
    if (sha256(path.join(app, "Contents", "Resources", "cyfr")) !== helper) {
      throw new Refused("CYFR.app/Contents/Resources/cyfr is not the cyfr the build signed")
    }
  } finally {
    rmSync(dir, {recursive: true, force: true})
  }
}

// One signed file of the app: signed by the app's certificate (`leaf`;
// `signer` reads a file's), hardened, timestamped, with exactly the
// entitlements of its kind.
function checkSignature(app, file, leaf, signer, want) {
  const name = path.relative(path.dirname(app), file)
  const shown = codesign(["-d", "--verbose=2", file])
  if (!shown.ok) throw new Refused(`${name} is not signed`)
  if (!leaf.equals(signer(file))) throw new Refused(`${name} is not signed by CYFR.app's certificate`)
  if (!/^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)/m.test(shown.err)) throw new Refused(`${name} lacks the hardened runtime`)
  if (!/^Timestamp=/m.test(shown.err)) throw new Refused(`${name} has no secure timestamp`)
  const listed = codesign(["-d", "--entitlements", "-", "--xml", file])
  const got = listed.out.trim() ? plist.parse(listed.out) : {}
  if (JSON.stringify(sorted(got)) !== JSON.stringify(sorted(want[kindOf(app, file)]))) {
    throw new Refused(`${name} has entitlements other than its own`)
  }
}

function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted)
  if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map((k) => [k, sorted(value[k])]))
  return value
}

/**
 * Check the built DMG (or the app) at `file`: signed, and its CYFR.app as
 * checkApp checks it; unless `rehearsed`, both notarised with the ticket
 * stapled and accepted by Gatekeeper. Throws Refused.
 */
export function checkDmg(file, expect, {rehearsed = false} = {}) {
  const release = (app) => {
    checkApp(app, expect)
    if (rehearsed) return
    must("xcrun", ["stapler", "validate", app], "CYFR.app has no stapled notarisation")
    must("spctl", ["--assess", "--type", "execute", app], "Gatekeeper refuses CYFR.app")
  }
  if (path.extname(file) === ".app") return release(file)
  must("codesign", ["--verify", "--strict", file], "the DMG's signature does not verify")
  if (!rehearsed) {
    must("xcrun", ["stapler", "validate", file], "the DMG has no stapled notarisation")
    must("spctl", ["--assess", "--type", "open", "--context", "context:primary-signature", file], "Gatekeeper refuses the DMG")
  }
  const mount = mkdtempSync(path.join(tmpdir(), "cyfr-dmg-"))
  must("hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount, file], "the DMG does not mount", 300)
  try {
    release(path.join(mount, "CYFR.app"))
  } finally {
    tool("hdiutil", ["detach", mount], 120)
    rmSync(mount, {recursive: true, force: true})
  }
}

/** Notarise the signed DMG at `dmg` and staple its ticket. */
export async function notarizeDmg(dmg, inputs) {
  const {notarize} = need("@electron/notarize")
  await notarize({appPath: dmg, appleId: inputs.appleId, appleIdPassword: inputs.applePassword, teamId: inputs.team})
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const {values, positionals} = parseArgs({allowPositionals: true,
    options: {"cyfr-sha256": {type: "string"}, rehearsed: {type: "boolean", default: false}}})
  if (positionals[0] !== "check" || !positionals[1] || !/^[0-9a-f]{64}$/.test(values["cyfr-sha256"] ?? "")) {
    console.error("usage: node scripts/mac-sign.mjs check DMG|APP --cyfr-sha256 HEX [--rehearsed]")
    process.exit(64)
  }
  try {
    const names = values.rehearsed ? REHEARSAL : APPLE
    const team = process.env[names[3]]
    const profile = Buffer.from(process.env[names[names.length - 1]] ?? "", "base64")
    if (!team || !profile.length) throw new Refused(`${names[3]} and ${names[names.length - 1]} are needed`)
    checkDmg(positionals[1], {helper: values["cyfr-sha256"], team, group: webauthnGroup(team), profile}, {rehearsed: values.rehearsed})
    console.log(`checked ${path.basename(positionals[1])}${values.rehearsed ? " (rehearsed)" : ""}`)
  } catch (e) {
    if (!(e instanceof Refused)) throw e
    console.error(`refused: ${e.message}`)
    process.exit(1)
  }
}
