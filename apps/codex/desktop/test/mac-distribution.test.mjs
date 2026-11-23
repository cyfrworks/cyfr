// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The Mac distribution's owner (scripts/mac-distribution.mjs) against
// stand-ins for macOS's security and LibreSSL's openssl and for the worker
// that packs and signs: what a failed build leaves, the keychain's removal
// and where the secret inputs may go.

import assert from "node:assert/strict"
import {chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync} from "node:fs"
import {createRequire} from "node:module"
import {tmpdir} from "node:os"
import path from "node:path"
import {test as anyTest} from "node:test"
import {fileURLToPath} from "node:url"

import {Refused, hide, redact} from "../scripts/check-package.mjs"
import {distribute} from "../scripts/mac-distribution.mjs"

// The stand-ins are shell scripts and the bound perl's, a Mac's or Linux's.
const test = (name, fn) => anyTest(name, {skip: process.platform === "win32"}, fn)

const desktop = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const plist = createRequire(path.join(desktop, "node_modules", "app-builder-lib", "package.json"))("plist")

const team = "AB12CD34EF"
const secrets = {
  APPLE_CERTIFICATE: Buffer.concat([Buffer.from([0x30, 0x82]), Buffer.from("the certificate's own private bytes")]).toString("base64"),
  APPLE_CERTIFICATE_PASSWORD: "correct horse battery staple",
  APPLE_ID: "someone.private@example.com",
  APPLE_PASSWORD: "abcd-efgh-ijkl-mnop"
}
const profileBytes = Buffer.from([0x30, 0x82, 0x00, 0x10])
const inputs = {...secrets, APPLE_SIGNING_IDENTITY: `Developer ID Application: CYFR Works Inc. (${team})`, APPLE_TEAM_ID: team,
  APPLE_PROVISIONING_PROFILE: profileBytes.toString("base64")}

// Each secret as a careless tool or log could print it: whole, quoted,
// escaped for a shell, and cut into its words.
function spellings(value) {
  const words = value.split(/[^A-Za-z0-9+/]+/).filter((w) => w.length >= 4)
  return [value, `"${value}"`, `'${value}'`, value.replace(/ /g, "\\ "), ...words]
}
const printedAnywhere = (text) => Object.values(secrets).flatMap(spellings).filter((s) => text.includes(s))

// A folder of stand-ins: `security` and `openssl` that log every command
// line, the worker, and an --out folder.
function rig(t, {failAt = "", worker = "ok", searchList = "/Users/runner/Library/Keychains/login.keychain-db"} = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), "cyfr-distribution-"))
  t.after(() => rmSync(dir, {recursive: true, force: true}))
  const bin = path.join(dir, "bin")
  mkdirSync(bin)
  const log = path.join(dir, "log")
  writeFileSync(log, "")
  writeFileSync(path.join(dir, "profile.plist"), plist.build({
    ProvisionsAllDevices: true, TeamIdentifier: [team], ExpirationDate: new Date(Date.now() + 86400000),
    Entitlements: {"com.apple.application-identifier": `${team}.run.cyfr.desktop`, "com.apple.developer.team-identifier": team,
      "keychain-access-groups": [`${team}.*`]}
  }))
  writeFileSync(path.join(dir, "secrets.json"), JSON.stringify(secrets))
  // Every stand-in echoes every secret before it answers, as a tool that
  // prints its input would; nothing of it may reach a sentence.
  const echo = `node -e 'const s=require(process.argv[1]);for(const v of Object.values(s)){console.error(v,JSON.stringify(v),v.split(" ").join("\\\\ "))}' ${path.join(dir, "secrets.json")}`
  writeFileSync(path.join(bin, "security"), `#!/bin/sh
printf 'security %s\\n' "$*" >> ${log}
${echo}
case "$1" in
  cms) cat ${path.join(dir, "profile.plist")} ;;
  create-keychain) eval "k=\\$$#"; : > "$k" ;;
  delete-keychain) rm -f "$2" ;;
  list-keychains) [ "$3" = -s ] || [ -z "${searchList}" ] || echo '    "${searchList}"' ;;
esac
[ "$1" = "${failAt}" ] && exit 9
exit 0
`)
  writeFileSync(path.join(bin, "openssl"), `#!/bin/sh
printf 'openssl %s\\n' "$*" >> ${log}
${echo}
if [ "$2" = -export ]; then cat > "$6"; else cat; fi
`)
  for (const f of ["security", "openssl"]) chmodSync(path.join(bin, f), 0o755)
  const workerScript = path.join(dir, "worker.mjs")
  writeFileSync(workerScript, `
import {mkdirSync, readFileSync, writeFileSync} from "node:fs"
import {spawn} from "node:child_process"
import path from "node:path"
const args = process.argv.slice(2)
const out = args[args.indexOf("--out") + 1]
const config = JSON.parse(readFileSync(args[args.indexOf("--worker") + 1], "utf8"))
writeFileSync(${JSON.stringify(log)}, "worker " + args.join(" ") + "\\n", {flag: "a"})
mkdirSync(out, {recursive: true})
const image = path.join(out, "cyfr-desktop_1.0.0_darwin_arm64.dmg")
const secrets = JSON.parse(readFileSync(${JSON.stringify(path.join(dir, "secrets.json"))}, "utf8"))
for (const v of Object.values(secrets)) console.log("echo:", v, JSON.stringify(v), v.split(" ").join("\\\\ "))
const mode = ${JSON.stringify(worker)}
if (mode === "half") { writeFileSync(image, "half a DMG"); process.exit(1) }
if (mode === "hang") {
  const c = spawn("sleep", ["60"], {stdio: "ignore"})
  writeFileSync(${JSON.stringify(path.join(dir, "grandchild"))}, String(c.pid))
  setTimeout(() => {}, 60000)
} else {
  writeFileSync(image, "a whole DMG")
  writeFileSync(config.result, JSON.stringify({helper: "ab".repeat(32)}))
}
`)
  const out = path.join(dir, "out")
  mkdirSync(out)
  const dest = path.join(out, "cyfr-desktop_1.0.0_darwin_arm64.dmg")
  return {dir, bin, log, out, dest, worker: {command: process.execPath, args: [workerScript], minutes: 0.05}}
}

async function run(r, {env = inputs, check = async () => {}} = {}) {
  const path0 = process.env.PATH
  process.env.PATH = `${r.bin}:${path0}`
  const printed = []
  try {
    await distribute({env: {...env, PATH: process.env.PATH}, dest: r.dest, worker: r.worker, openssl: path.join(r.bin, "openssl"),
      check, notarise: async () => {}, print: (text) => printed.push(text)})
    return {printed: printed.join("")}
  } catch (e) {
    return {printed: printed.join(""), error: e}
  } finally {
    process.env.PATH = path0
  }
}

const leftovers = (r) => readdirSync(r.out).filter((n) => n.startsWith(".cyfr-signing-"))

test("a refused build leaves no DMG, not even the one from before", async (t) => {
  const r = rig(t)
  writeFileSync(r.dest, "an earlier build's DMG")
  const {error} = await run(r, {env: {...inputs, APPLE_PROVISIONING_PROFILE: ""}})
  assert.ok(error instanceof Refused && /APPLE_PROVISIONING_PROFILE is not set/.test(error.message), String(error))
  assert.equal(existsSync(r.dest), false)
  assert.deepEqual(leftovers(r), [])
})

test("a packer that writes half a DMG and fails leaves no DMG and no keychain", async (t) => {
  const r = rig(t, {worker: "half"})
  writeFileSync(r.dest, "an earlier build's DMG")
  const {error} = await run(r)
  assert.ok(error instanceof Refused && /packing and signing the app failed \(exit 1\)/.test(error.message), String(error))
  assert.equal(existsSync(r.dest), false)
  assert.deepEqual(leftovers(r), [])
  const calls = readFileSync(r.log, "utf8")
  assert.match(calls, /^security delete-keychain \S+signing\.keychain-db$/m)
  assert.match(calls, /^security list-keychains -d user -s \/Users\/runner\/Library\/Keychains\/login\.keychain-db$/m, "the search list restored")
})

test("a DMG that fails the check is not published", async (t) => {
  const r = rig(t)
  const {error} = await run(r, {check: async () => { throw new Refused("the image is refused") }})
  assert.ok(error instanceof Refused && /the image is refused/.test(error.message), String(error))
  assert.equal(existsSync(r.dest), false)
  assert.deepEqual(leftovers(r), [])
})

test("a failure after the key's import leaves no keychain", async (t) => {
  for (const failAt of ["create-keychain", "import", "set-key-partition-list"]) {
    const r = rig(t, {failAt})
    const {error} = await run(r)
    assert.ok(error instanceof Refused, `${failAt}: ${error}`)
    const calls = readFileSync(r.log, "utf8").split("\n")
    assert.ok(calls.some((c) => /^security delete-keychain \S+signing\.keychain-db$/.test(c)), `${failAt}: the keychain was not deleted`)
    assert.equal(calls.some((c) => c.startsWith("worker ")), false, failAt)
    assert.deepEqual(leftovers(r), [], failAt)
  }
})

test("a packer that outlives its bound is stopped with all it started", async (t) => {
  const r = rig(t, {worker: "hang"})
  const started = Date.now()
  const {error} = await run(r)
  assert.ok(error instanceof Refused && /packing and signing the app did not finish in 0\.05 minutes/.test(error.message), String(error))
  assert.ok(Date.now() - started < 20000)
  const grandchild = Number(readFileSync(path.join(r.dir, "grandchild"), "utf8"))
  assert.throws(() => process.kill(grandchild, 0), {code: "ESRCH"}, "the packer's own child was stopped with it")
  assert.equal(existsSync(r.dest), false)
  assert.deepEqual(leftovers(r), [])
})

test("no secret reaches a command line, a printed line or a refusal, whole or in parts", async (t) => {
  const r = rig(t)
  const {printed, error} = await run(r)
  assert.equal(error, undefined)
  assert.equal(readFileSync(r.dest, "utf8"), "a whole DMG", "published by the rename")
  assert.deepEqual(leftovers(r), [])
  assert.match(printed, /echo: \*\*\*/, "the worker's echo was printed, hidden")
  assert.deepEqual(printedAnywhere(printed), [], "printed")
  const calls = readFileSync(r.log, "utf8")
  assert.deepEqual(printedAnywhere(calls), [], "on a command line")
  // The tools' own words, which carry every secret, in a refusal.
  const refused = await run(rig(t, {failAt: "import"}))
  assert.match(refused.error.message, /^the identity was not imported: /)
  assert.deepEqual(printedAnywhere(refused.error.message), [], "in a refusal")
})

test("the redactor hides a value whole, quoted, escaped, wrapped and in its words", () => {
  hide(["pass phrase words", "QUJDREVGR0hJSktM\nTU5PUFFSU1RVVldY"])
  for (const text of ["pass phrase words", "'pass phrase words'", "pass\\ phrase\\ words", "the phrase was words",
    "QUJDREVGR0hJSktM", "TU5PUFFSU1RVVldY"]) {
    assert.equal(/pass phrase|phrase|words|QUJD|TU5P/.test(redact(text)), false, text)
  }
  assert.equal(redact("nothing secret here"), "nothing secret here")
})

test("an empty keychain search list is a failure, not a list to restore", async (t) => {
  const r = rig(t, {searchList: ""})
  const {error} = await run(r)
  assert.ok(error instanceof Refused && /the keychain search list read as empty/.test(error.message), String(error))
  const calls = readFileSync(r.log, "utf8")
  assert.doesNotMatch(calls, /list-keychains -d user -s/, "the list was neither set nor emptied")
  assert.match(calls, /^security delete-keychain /m)
  assert.deepEqual(leftovers(r), [])
})
