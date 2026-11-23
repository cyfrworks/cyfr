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
// and notarises with the team's App Store Connect API key: APPLE_API_KEY
// (the .p8, base64), APPLE_API_KEY_ID and APPLE_API_ISSUER. A
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
import {closeSync, lstatSync, mkdtempSync, openSync, readFileSync, readSync, readdirSync, realpathSync, rmSync, writeFileSync} from "node:fs"
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
  "APPLE_PROVISIONING_PROFILE", "APPLE_API_KEY", "APPLE_API_KEY_ID", "APPLE_API_ISSUER"]
export const REHEARSAL = ["CYFR_REHEARSAL_CERTIFICATE", "CYFR_REHEARSAL_CERTIFICATE_PASSWORD", "CYFR_REHEARSAL_SIGNING_IDENTITY",
  "CYFR_REHEARSAL_TEAM_ID", "CYFR_REHEARSAL_PROVISIONING_PROFILE"]

/** The WebAuthn keychain group the app's passkeys live in, for team. */
export const webauthnGroup = (team) => `${team}.${APP_ID}.webauthn`

/**
 * The signing inputs in env: {certificate, certificatePassword, identity,
 * team, group, profile (bytes), rehearsed, notary}, notary being the App
 * Store Connect team key the notary takes, {key (the .p8's text), keyId,
 * issuer}, or null when rehearsed. Throws Refused naming the input, never
 * its value.
 */
export function signingInputs(env, {rehearse = false} = {}) {
  if (rehearse) {
    const real = APPLE.filter((name) => env[name] !== undefined)
    if (real.length) throw new Refused(`a rehearsal takes no Apple input, and ${real.join(", ")} is set`)
  }
  const names = rehearse ? REHEARSAL : APPLE
  for (const name of names) if (!env[name]) throw new Refused(`${name} is not set`)
  const [certificate, certificatePassword, identity, team, profile] = names
  if (!/^[A-Z0-9]{10}$/.test(env[team])) throw new Refused(`${team} is not a team ID`)
  const p12 = Buffer.from(env[certificate], "base64")
  if (p12[0] !== 0x30) throw new Refused(`${certificate} is not a base64 .p12`)
  const bytes = Buffer.from(env[profile], "base64")
  if (bytes[0] !== 0x30) throw new Refused(`${profile} is not a base64 provisioning profile`)
  let notary = null
  if (!rehearse) {
    const key = Buffer.from(env.APPLE_API_KEY, "base64").toString("utf8")
    if (!/^-----BEGIN PRIVATE KEY-----\r?\n[A-Za-z0-9+/=\r\n]+-----END PRIVATE KEY-----\s*$/.test(key)) {
      throw new Refused("APPLE_API_KEY is not a base64 App Store Connect .p8 key")
    }
    if (!/^[A-Z0-9]{10}$/.test(env.APPLE_API_KEY_ID)) throw new Refused("APPLE_API_KEY_ID is not an App Store Connect key ID")
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(env.APPLE_API_ISSUER)) {
      throw new Refused("APPLE_API_ISSUER is not an issuer ID")
    }
    notary = {key, keyId: env.APPLE_API_KEY_ID, issuer: env.APPLE_API_ISSUER}
  }
  return {
    certificate: env[certificate], certificatePassword: env[certificatePassword],
    // electron-builder takes the identity's name without its kind.
    identity: env[identity].replace(/^Developer ID Application: /, ""),
    team: env[team], group: webauthnGroup(env[team]), profile: bytes,
    rehearsed: rehearse, notary
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

// A tool's bound: the tool runs as the leader of a process group of its
// own, and when it has not ended in SECONDS the whole group is killed, so
// nothing it started outlives its bound. Exit 142 says the bound ran out.
const BOUND = `
my $seconds = shift @ARGV;
my $pid = fork;
die "cannot fork\\n" unless defined $pid;
if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127 }
setpgrp($pid, $pid);
local $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid($pid, 0); exit 142 };
alarm $seconds;
waitpid($pid, 0);
alarm 0;
kill "KILL", -$pid;
exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
`

/**
 * Run a tool that could wait on a person (a keychain's prompt, a mounted
 * image, Apple's servers) within `seconds`: {ok, out, err}, its output as
 * the tool gave it, for reading; Refused when the bound ran out, the tool
 * and everything it started then killed. `options` may give its standard
 * input (`input`) and environment (`env`).
 */
export function tool(cmd, args, seconds = 120, {input, env} = {}) {
  const r = spawnSync("perl", ["-e", BOUND, String(seconds), cmd, ...args],
    {encoding: "utf8", input, env, maxBuffer: 64 * 1024 * 1024})
  if (r.error) throw r.error
  if (r.status === 142) throw new Refused(`${cmd} ${args[0] ?? ""} did not answer in ${seconds} seconds`.replace(/ +$/, ""))
  if (r.status === 127 && !r.stdout && !r.stderr) throw new Refused(`${cmd} could not be run`)
  return {ok: r.status === 0, status: r.status, out: r.stdout, err: r.stderr}
}

// A tool's run that must succeed, or Refused saying `what` and the tool's
// own words, which the refusal hides as it hides every input.
export function must(cmd, args, what, seconds, options) {
  const r = tool(cmd, args, seconds, options)
  if (!r.ok) throw new Refused(`${what}: ${(r.err || r.out || `exit ${r.status}`).trim()}`)
  return r
}

/** The decoded property list of a provisioning profile's bytes (macOS). */
export function decodeProfile(bytes) {
  const dir = mkdtempSync(path.join(tmpdir(), "cyfr-profile-"))
  try {
    writeFileSync(path.join(dir, "p"), bytes)
    const shown = must("security", ["cms", "-D", "-i", path.join(dir, "p")], "the provisioning profile does not decode").out
    try {
      return plist.parse(shown)
    } catch {
      throw new Refused("the provisioning profile does not decode to a property list")
    }
  } finally {
    rmSync(dir, {recursive: true, force: true})
  }
}

// Every Mach-O header there is: thin 32- and 64-bit and fat 32- and 64-bit,
// each in both byte orders.
const MACHO = new Set(["feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"])
// The data a signed Electron app holds, by kind: Electron's resources
// (.pak, .dat, .bin, .asar, .icns, .json, .nib, .plist, PkgInfo), and a
// signature's own files.
const DATA = /\.(pak|dat|bin|asar|icns|json|nib|plist)$/
const DATA_NAMES = new Set(["PkgInfo", "embedded.provisionprofile"])

function head(file) {
  const fd = openSync(file, "r")
  try {
    const bytes = Buffer.alloc(4)
    return readSync(fd, bytes, 0, 4, 0) === 4 ? bytes.toString("hex") : ""
  } finally {
    closeSync(fd)
  }
}

/**
 * Every file of the app at `app`, each of a kind: {code, data, links}.
 * Code is every Mach-O file, its bundles (.app, .framework) and the app,
 * inner first; data is a file of a kind DATA names, or a signature's
 * _CodeSignature/CodeResources; a link is one whose target stays inside
 * the app. Anything else is refused, so no file passes by default.
 */
export function classify(app) {
  const root = realpathSync(app)
  const out = {code: [], data: [], links: []}
  const walk = (at) => {
    for (const name of readdirSync(at)) {
      const p = path.join(at, name)
      const st = lstatSync(p)
      const shown = path.relative(path.dirname(app), p)
      if (st.isSymbolicLink()) {
        let target
        try { target = realpathSync(p) } catch { throw new Refused(`${shown} is a link to nothing`) }
        const inside = path.relative(root, target)
        if (inside.startsWith("..") || path.isAbsolute(inside)) throw new Refused(`${shown} is a link out of the app`)
        out.links.push(p)
      } else if (st.isDirectory()) {
        walk(p)
        if (/\.(app|framework)$/.test(name)) out.code.push(p)
      } else if (!st.isFile()) {
        throw new Refused(`${shown} is neither a file, a folder nor a link`)
      } else if (MACHO.has(head(p))) {
        out.code.push(p)
      } else if (DATA.test(name) || DATA_NAMES.has(name) || (name === "CodeResources" && path.basename(at) === "_CodeSignature")) {
        out.data.push(p)
      } else {
        throw new Refused(`${shown} is of no kind a signed CYFR.app holds`)
      }
    }
  }
  walk(app)
  out.code.push(app)
  return out
}

/** The app's code, inner first: classify(app).code. */
export const signedCode = (app) => classify(app).code

const codesign = (args) => tool("codesign", args)
const sha256 = (file) => createHash("sha256").update(readFileSync(file)).digest("hex")

/**
 * Check a signed CYFR.app at `app`: every file is of a known kind; it
 * embeds the supplied profile, which checkProfile passes for the team and
 * group and which lists the app's signing certificate; each signature
 * verifies strictly, is by that certificate, hardened and timestamped,
 * with exactly its kind's entitlements as read; the bundled cyfr is the
 * one the build signed, whose SHA-256 is `helper`. Throws Refused naming
 * the first difference.
 */
export function checkApp(app, {helper, team, group, profile}) {
  const code = signedCode(app)
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
      try { return readFileSync(`${prefix}0`) } catch { throw new Refused(`${path.basename(file)} carries no certificate`) }
    }
    const leaf = signer(app)
    if (!(decoded.DeveloperCertificates ?? []).some((c) => Buffer.from(c).equals(leaf))) {
      throw new Refused("the provisioning profile does not list CYFR.app's signing certificate")
    }
    for (const file of code) checkSignature(app, file, leaf, signer, want)
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
// entitlements of its kind. An entitlement read that failed or that is not
// a property list refuses the app; only a read that succeeded with nothing
// to say means none.
function checkSignature(app, file, leaf, signer, want) {
  const name = path.relative(path.dirname(app), file)
  const shown = codesign(["-d", "--verbose=2", file])
  if (!shown.ok) throw new Refused(`${name} is not signed`)
  if (!leaf.equals(signer(file))) throw new Refused(`${name} is not signed by CYFR.app's certificate`)
  if (!/^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)/m.test(shown.err)) throw new Refused(`${name} lacks the hardened runtime`)
  if (!/^Timestamp=/m.test(shown.err)) throw new Refused(`${name} has no secure timestamp`)
  const listed = codesign(["-d", "--entitlements", "-", "--xml", file])
  if (!listed.ok) throw new Refused(`${name}'s entitlements were not read (exit ${listed.status})`)
  let got = {}
  if (listed.out.trim()) {
    try {
      got = plist.parse(listed.out)
    } catch {
      got = null
    }
    if (!got || typeof got !== "object" || Array.isArray(got)) throw new Refused(`${name}'s entitlements are not a property list`)
  }
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
 * stapled and accepted by Gatekeeper. The image is detached again, and a
 * detach that failed refuses too. Throws Refused.
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
  let failed = null
  try {
    release(path.join(mount, "CYFR.app"))
  } catch (e) {
    failed = e
  }
  const detached = tool("hdiutil", ["detach", mount], 120)
  if (detached.ok) rmSync(mount, {recursive: true, force: true})
  if (failed) throw failed
  if (!detached.ok) throw new Refused(`the DMG stays mounted at ${mount}: ${(detached.err || detached.out).trim()}`)
}

/**
 * Notarise the signed app or DMG at `file` with the team key `notary`
 * ({key, keyId, issuer}) and staple its ticket, working in `dir`, a folder
 * of the build's own. notarytool takes an App Store Connect key as the
 * path of its private key, --key, with --key-id and --issuer, which are
 * identifiers (notarytool(1)); Apple's notary takes team keys alone
 * ("Individual keys aren't able to use ... notaryTool", Creating API Keys
 * for App Store Connect API). The private key is a file, mode 0600, for
 * the one command, and is removed after it whatever it answered. An app is
 * sent as a zip of itself and its ticket stapled to the app. Anything but
 * an accepted submission, a submission that did not end within its bound
 * and a ticket that was not stapled refuse.
 */
export function notarize(file, notary, dir) {
  const name = path.basename(file)
  let sent = file
  if (path.extname(file) === ".app") {
    sent = path.join(dir, `${name}.zip`)
    must("ditto", ["-c", "-k", "--keepParent", file, sent], `${name} was not zipped for the notary`, 600)
  }
  const key = path.join(dir, "notary-key.p8")
  writeFileSync(key, notary.key, {mode: 0o600})
  let answer
  try {
    const auth = ["--key", key, "--key-id", notary.keyId, "--issuer", notary.issuer]
    const r = tool("xcrun", ["notarytool", "submit", sent, ...auth, "--wait", "--timeout", "25m", "--output-format", "json"], 27 * 60)
    try { answer = JSON.parse(r.out) } catch { answer = null }
    if (!answer || typeof answer.status !== "string") {
      throw new Refused(`${name} was not notarised: the notary answered no status (exit ${r.status}): ${(r.err || r.out).trim()}`)
    }
    if (answer.status !== "Accepted") {
      const log = answer.id ? tool("xcrun", ["notarytool", "log", answer.id, ...auth], 300) : null
      throw new Refused(`${name} was not notarised: ${answer.status}${answer.message ? `, ${answer.message}` : ""}` +
        (log?.ok ? `\n${log.out.trim()}` : ""))
    }
  } finally {
    rmSync(key, {force: true})
    if (sent !== file) rmSync(sent, {force: true})
  }
  must("xcrun", ["stapler", "staple", file], `${name}'s ticket was not stapled`, 300)
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
    const profile = Buffer.from(process.env[names[4]] ?? "", "base64")
    if (!team || !profile.length) throw new Refused(`${names[3]} and ${names[4]} are needed`)
    checkDmg(positionals[1], {helper: values["cyfr-sha256"], team, group: webauthnGroup(team), profile}, {rehearsed: values.rehearsed})
    console.log(`checked ${path.basename(positionals[1])}${values.rehearsed ? " (rehearsed)" : ""}`)
  } catch (e) {
    if (!(e instanceof Refused)) throw e
    console.error(`refused: ${e.message}`)
    process.exit(1)
  }
}
