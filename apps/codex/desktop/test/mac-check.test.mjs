// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The signed app's check (scripts/mac-sign.mjs checkApp) against a
// stand-in codesign and security over an app of its own making: a reading
// that failed is a failure, and no file passes by default.

import assert from "node:assert/strict"
import {createHash} from "node:crypto"
import {chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync} from "node:fs"
import {createRequire} from "node:module"
import {tmpdir} from "node:os"
import path from "node:path"
import {test as anyTest} from "node:test"
import {fileURLToPath} from "node:url"

import {Refused} from "../scripts/check-package.mjs"
import {APP_ID, checkApp, entitlements, notarize, webauthnGroup} from "../scripts/mac-sign.mjs"

// The stand-ins are shell scripts, a Mac's or Linux's.
const test = (name, fn) => anyTest(name, {skip: process.platform === "win32"}, fn)

const desktop = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const plist = createRequire(path.join(desktop, "node_modules", "app-builder-lib", "package.json"))("plist")
const team = "AB12CD34EF"
const group = webauthnGroup(team)
const profile = Buffer.from([0x30, 0x82, 0x00, 0x20])
const leaf = Buffer.from("the app's signing certificate")
const thin64 = Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 1, 2, 3, 4])
const fat64 = Buffer.from([0xca, 0xfe, 0xba, 0xbf, 0, 0, 0, 2])

// An app as a signed CYFR.app is laid out, and a codesign that answers for
// it: every file signed by `leaf`, hardened and timestamped, with its
// kind's entitlements, except where `ent` (file name -> "exit73" or
// "garbled") says otherwise and where `bare` names a file that is not
// hardened.
function rig(t, {ent = {}, bare = ""} = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), "cyfr-check-"))
  t.after(() => rmSync(dir, {recursive: true, force: true}))
  const app = path.join(dir, "CYFR.app")
  const put = (rel, bytes, mode = 0o644) => {
    mkdirSync(path.dirname(path.join(app, rel)), {recursive: true})
    writeFileSync(path.join(app, rel), bytes)
    chmodSync(path.join(app, rel), mode)
  }
  put("Contents/MacOS/CYFR", thin64)
  put("Contents/Resources/cyfr", Buffer.concat([thin64, Buffer.from("cyfr")]))
  put("Contents/Resources/app.asar", "archive")
  put("Contents/Info.plist", "<plist/>")
  put("Contents/PkgInfo", "APPL????")
  put("Contents/embedded.provisionprofile", profile)
  put("Contents/_CodeSignature/CodeResources", "<plist/>")
  // The licences electron-builder moves in beside the app's resources.
  put("Contents/Resources/LICENSE.electron.txt", "MIT")
  put("Contents/Resources/LICENSES.chromium.html", "<html/>")
  const bin = path.join(dir, "bin")
  mkdirSync(bin)
  writeFileSync(path.join(dir, "main.xml"), plist.build(entitlements(team, group).main))
  writeFileSync(path.join(dir, "leaf"), leaf)
  writeFileSync(path.join(dir, "profile.xml"), plist.build({ProvisionsAllDevices: true, TeamIdentifier: [team],
    ExpirationDate: new Date(Date.now() + 86400000), DeveloperCertificates: [leaf],
    Entitlements: {"com.apple.application-identifier": `${team}.${APP_ID}`, "com.apple.developer.team-identifier": team,
      "keychain-access-groups": [group]}}))
  const cases = Object.entries(ent).map(([name, how]) => `  */${name}) ${how === "exit73" ? "exit 73" : "echo '<plist><dict><key>'; exit 0"} ;;`).join("\n")
  writeFileSync(path.join(bin, "codesign"), `#!/bin/sh
eval "file=\\$$#"
case "$1 $2" in
  "--verify "*) exit 0 ;;
  "-d --extract-certificates="*) cp ${path.join(dir, "leaf")} "\${2#--extract-certificates=}0"; exit 0 ;;
  "-d --verbose=2")
    case "$file" in */${bare || "no-such-file"}) flags="0x0(none)" ;; *) flags="0x10000(runtime)" ;; esac
    echo "CodeDirectory v=20500 size=1 flags=$flags hashes=1+1 location=embedded" >&2
    echo "Timestamp=Nov 24, 2026" >&2; exit 0 ;;
  "-d --entitlements")
    case "$file" in
${cases}
      */CYFR.app|*/MacOS/CYFR) cat ${path.join(dir, "main.xml")} ;;
    esac
    exit 0 ;;
esac
exit 1
`)
  writeFileSync(path.join(bin, "security"), `#!/bin/sh\ncat ${path.join(dir, "profile.xml")}\n`)
  for (const f of ["codesign", "security"]) chmodSync(path.join(bin, f), 0o755)
  const helper = createHash("sha256").update(Buffer.concat([thin64, Buffer.from("cyfr")])).digest("hex")
  const check = async () => {
    const before = process.env.PATH
    process.env.PATH = `${bin}:${before}`
    try {
      await checkApp(app, {helper, team, group, profile})
    } finally {
      process.env.PATH = before
    }
  }
  return {app, put, check}
}

const refused = (pattern) => (e) => e instanceof Refused && pattern.test(e.message)

test("a signed app whose every file is of a known kind passes", async (t) => {
  const r = rig(t)
  symlinkSync("Contents/Info.plist", path.join(r.app, "Info.plist"))
  await r.check()
})

test("an entitlement read that failed, or that is not a property list, refuses the app", async (t) => {
  await assert.rejects(() => rig(t, {ent: {cyfr: "exit73"}}).check(),
    refused(/^CYFR\.app\/Contents\/Resources\/cyfr's entitlements were not read: exit 73$/))
  await assert.rejects(() => rig(t, {ent: {cyfr: "garbled"}}).check(),
    refused(/^CYFR\.app\/Contents\/Resources\/cyfr's entitlements are not a property list$/))
})

test("every Mach-O header there is makes a file code that is checked", async (t) => {
  const r = rig(t, {bare: "libfat.dylib"})
  r.put("Contents/Frameworks/libfat.dylib", fat64)
  await assert.rejects(() => r.check(), refused(/^CYFR\.app\/Contents\/Frameworks\/libfat\.dylib lacks the hardened runtime$/))
  for (const magic of ["feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"]) {
    const m = rig(t, {bare: "lib.dylib"})
    m.put("Contents/Frameworks/lib.dylib", Buffer.concat([Buffer.from(magic, "hex"), Buffer.from([0, 0, 0, 0])]))
    await assert.rejects(() => m.check(), refused(/lib\.dylib lacks the hardened runtime$/), magic)
  }
})

test("a file of no kind a signed app holds refuses it, and so does a link out of it", async (t) => {
  const script = rig(t)
  script.put("Contents/Resources/launch.sh", "#!/bin/sh\n")
  await assert.rejects(() => script.check(), refused(/^CYFR\.app\/Contents\/Resources\/launch\.sh is of no kind a signed CYFR\.app holds$/))
  const out = rig(t)
  symlinkSync("/etc/hosts", path.join(out.app, "Contents", "hosts"))
  await assert.rejects(() => out.check(), refused(/^CYFR\.app\/Contents\/hosts is a link out of the app$/))
  // One refusal names every such file, not the first alone.
  const many = rig(t)
  many.put("Contents/Resources/one.sh", "#!/bin/sh\n")
  many.put("Contents/Resources/two.py", "print()\n")
  await assert.rejects(() => many.check(), refused(/^CYFR\.app\/Contents\/Resources\/one\.sh is of no kind a signed CYFR\.app holds; CYFR\.app\/Contents\/Resources\/two\.py is of no kind a signed CYFR\.app holds$/))
  const dangling = rig(t)
  symlinkSync("nothing-here", path.join(dangling.app, "Contents", "gone"))
  await assert.rejects(() => dangling.check(), refused(/is a link to nothing$/))
})

// The notary (scripts/mac-sign.mjs notarize) against a stand-in xcrun and
// ditto: the team key's private half is a file, mode 0600, only for the
// one command, never on its command line; only an accepted submission,
// from an exit 0, with its ticket stapled passes; and nothing notarytool
// says, handed the key as it is, reaches a refusal.
function notaryRig(t, {status = "Accepted", exit = 0, staple = 0, speak = ""} = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), "cyfr-notary-"))
  t.after(() => rmSync(dir, {recursive: true, force: true}))
  const bin = path.join(dir, "bin")
  const work = path.join(dir, "work")
  mkdirSync(bin)
  mkdirSync(work)
  const log = path.join(dir, "log")
  writeFileSync(log, "")
  // How a tool might give back the key it read: whole, wrapped at 16
  // columns (Sol's), reversed, or as base64.
  const speech = {whole: 'cat "$key"', fold: 'fold -w 16 "$key"', reversed: 'rev "$key"', base64: 'base64 < "$key"'}[speak] ?? ":"
  writeFileSync(path.join(bin, "xcrun"), `#!/bin/sh
printf 'xcrun %s\\n' "$*" >> ${log}
if [ "$1 $2" = "notarytool submit" ]; then
  key=$(echo "$*" | sed -n 's/.* --key \\([^ ]*\\) .*/\\1/p')
  mode=$(stat -c %a "$key" 2>/dev/null || stat -f %Lp "$key")
  printf 'key %s %s\\n' "$mode" "$(head -1 "$key")" >> ${log}
  ${speech} >&2
  ${speech}
  echo '{"id":"2efe2717-52ef-43a5-96dc-0797e4ca1041","status":"${status}","message":"Processing complete"}'
  exit ${exit}
fi
if [ "$1 $2" = "stapler staple" ]; then printf 'stapled\\n' >> ${log}; exit ${staple}; fi
exit 1
`)
  writeFileSync(path.join(bin, "ditto"), `#!/bin/sh\nprintf 'ditto %s\\n' "$*" >> ${log}\n: > "$5"\n`)
  for (const f of ["xcrun", "ditto"]) chmodSync(path.join(bin, f), 0o755)
  const app = path.join(dir, "CYFR.app")
  mkdirSync(app)
  const run = async (file = app) => {
    const before = process.env.PATH
    process.env.PATH = `${bin}:${before}`
    try {
      await notarize(file, notary, work)
    } finally {
      process.env.PATH = before
    }
  }
  return {run, log, work, dmg: path.join(dir, "cyfr.dmg")}
}
const body = "TUlHVEFnRUFNQk1HQnlxR1NNNDlBZ0VHQ0NxR1NNNDlBd0VIQkhrd2R3SUJBUVFn"
const notary = {key: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`, keyId: "2X9R4HXF34",
  issuer: "57246542-96fe-1a63-e053-0824d011072a"}
// Any trace of the key's body in `text`, however it was cut or turned.
const traces = (text) => {
  const flat = text.replace(/\s+/g, "")
  const turned = [body, [...body].reverse().join(""), Buffer.from(body).toString("base64").slice(0, 24)]
  return turned.filter((t) => flat.includes(t) || flat.includes(t.slice(0, 16)) || flat.includes(t.slice(-16)))
}

test("the notary's key is a private file for the one command, and no command line carries it", async (t) => {
  const r = notaryRig(t)
  await r.run()
  const calls = readFileSync(r.log, "utf8")
  assert.match(calls, /^ditto -c -k --keepParent \S+CYFR\.app \S+CYFR\.app\.zip$/m, "an app goes as a zip of itself")
  assert.match(calls, /^xcrun notarytool submit \S+CYFR\.app\.zip --key \S+notary-key\.p8 --key-id 2X9R4HXF34 --issuer 57246542-96fe-1a63-e053-0824d011072a --wait --timeout 25m --output-format json$/m)
  assert.match(calls, /^key 600 -----BEGIN PRIVATE KEY-----$/m, "the key was there, mode 0600, during the command")
  assert.match(calls, /^xcrun stapler staple \S+CYFR\.app$/m)
  assert.deepEqual(traces(calls.split("\n").filter((l) => !l.startsWith("key ")).join("\n")), [], "the key on a command line")
  assert.deepEqual(readdirSync(r.work), [], "the key and the zip are gone")
})

test("a tool handed the key never speaks: whole, wrapped, reversed or as base64, none of it reaches a refusal", async (t) => {
  for (const speak of ["whole", "fold", "reversed", "base64"]) {
    const r = notaryRig(t, {speak, exit: 9})
    const e = await r.run(r.dmg).then(() => null, (e) => e)
    assert.ok(e instanceof Refused, speak)
    assert.equal(e.message, "cyfr.dmg was not notarised: exit 9", speak)
    assert.deepEqual(traces(e.message), [], speak)
    assert.deepEqual(readdirSync(r.work), [], speak)
  }
})

test("only an accepted submission from an exit 0, with its ticket stapled, passes", async (t) => {
  // Sol's: an accepted answer from a notarytool that failed.
  const failed = notaryRig(t, {exit: 73})
  await assert.rejects(() => failed.run(failed.dmg), refused(/^cyfr\.dmg was not notarised: exit 73$/))
  assert.doesNotMatch(readFileSync(failed.log, "utf8"), /stapled/, "nothing is stapled after a failed submission")
  const invalid = notaryRig(t, {status: "Invalid"})
  await assert.rejects(() => invalid.run(invalid.dmg),
    refused(/^cyfr\.dmg was not notarised: the notary's answer is Invalid; xcrun notarytool log 2efe2717-52ef-43a5-96dc-0797e4ca1041 shows why$/))
  assert.doesNotMatch(readFileSync(invalid.log, "utf8"), /stapled/)
  const unstapled = notaryRig(t, {staple: 65})
  await assert.rejects(() => unstapled.run(unstapled.dmg), refused(/^cyfr\.dmg's ticket was not stapled: exit 65$/))
  for (const r of [failed, invalid, unstapled]) assert.deepEqual(readdirSync(r.work), [])
})

// Data cannot run: whatever can is code, and an app's code is Mach-O.
test("a file the roster takes as data but that can run refuses the app", async (t) => {
  const script = rig(t)
  // Sol's: an executable script named as V8's snapshot.
  script.put("Contents/Frameworks/snapshot_blob.bin", "#!/bin/sh\nprintf 'dummy script ran\\n'\n", 0o700)
  await assert.rejects(() => script.check(), refused(/^CYFR\.app\/Contents\/Frameworks\/snapshot_blob\.bin can run, so it is code, and it is no Mach-O$/))
  const shebang = rig(t)
  shebang.put("Contents/Resources/run.pak", "#!/usr/bin/env node\n", 0o644)
  await assert.rejects(() => shebang.check(), refused(/run\.pak begins as a script does, so it is code, and it is no Mach-O$/))
  const executable = rig(t)
  executable.put("Contents/Resources/locale.pak", "PAK data", 0o755)
  await assert.rejects(() => executable.check(), refused(/locale\.pak can run, so it is code, and it is no Mach-O$/))
  const machO = rig(t, {bare: "snapshot_blob.bin"})
  machO.put("Contents/Frameworks/snapshot_blob.bin", thin64, 0o755)
  await assert.rejects(() => machO.check(), refused(/snapshot_blob\.bin lacks the hardened runtime$/), "a Mach-O by any name is code")
})
