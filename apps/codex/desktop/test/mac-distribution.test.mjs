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
import {APP_ID} from "../scripts/mac-sign.mjs"

// The stand-ins are shell scripts and the bound perl's, a Mac's or Linux's.
const test = (name, fn) => anyTest(name, {skip: process.platform === "win32"}, fn)

const desktop = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const plist = createRequire(path.join(desktop, "node_modules", "app-builder-lib", "package.json"))("plist")

const team = "AB12CD34EF"
const p8 = "-----BEGIN PRIVATE KEY-----\nTUlHVEFnRUFNQk1HQnlxR1NNNDlBZ0VHQ0NxR1NNNDlBd0VIQkhrd2R3SUJBUVFn\n-----END PRIVATE KEY-----\n"
// The secret inputs, and the notary's key as its text, which the build
// decodes.
const secrets = {
  APPLE_CERTIFICATE: Buffer.concat([Buffer.from([0x30, 0x82]), Buffer.from("the certificate's own private bytes")]).toString("base64"),
  APPLE_CERTIFICATE_PASSWORD: "correct horse battery staple",
  APPLE_API_KEY: Buffer.from(p8).toString("base64"),
  p8
}
const profileBytes = Buffer.from([0x30, 0x82, 0x00, 0x10])
const inputs = {APPLE_CERTIFICATE: secrets.APPLE_CERTIFICATE, APPLE_CERTIFICATE_PASSWORD: secrets.APPLE_CERTIFICATE_PASSWORD,
  APPLE_API_KEY: secrets.APPLE_API_KEY, APPLE_API_KEY_ID: "2X9R4HXF34", APPLE_API_ISSUER: "57246542-96fe-1a63-e053-0824d011072a",
  APPLE_SIGNING_IDENTITY: `Developer ID Application: CYFR Works Inc. (${team})`, APPLE_TEAM_ID: team,
  APPLE_PROVISIONING_PROFILE: profileBytes.toString("base64")}

// Each secret as a careless tool or log could print it: whole, quoted,
// escaped for a shell, and cut into its words.
function spellings(value) {
  const words = value.split(/[^A-Za-z0-9+/]+/).filter((w) => w.length >= 4)
  return [value, `"${value}"`, `'${value}'`, value.replace(/\\/g, "\\\\").replace(/ /g, "\\ "), ...words]
}
const printedAnywhere = (text) => Object.values(secrets).flatMap(spellings).filter((s) => text.includes(s))

// A folder of stand-ins: `security` and `openssl` that log every command
// line and the environment each was handed, the worker, a `ps` that fails
// or hangs when `ps` asks for one, and an --out folder.
function rig(t, {failAt = "", worker = "ok", ps = "", searchList = "/Users/runner/Library/Keychains/login.keychain-db"} = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), "cyfr-distribution-"))
  t.after(() => rmSync(dir, {recursive: true, force: true}))
  const bin = path.join(dir, "bin")
  mkdirSync(bin)
  const log = path.join(dir, "log")
  writeFileSync(log, "")
  const envs = path.join(dir, "envs")
  writeFileSync(envs, "")
  const handed = (tool) => `printf '=== ${tool}\\n' >> ${envs}; env >> ${envs}`
  writeFileSync(path.join(dir, "profile.plist"), plist.build({
    ProvisionsAllDevices: true, TeamIdentifier: [team], ExpirationDate: new Date(Date.now() + 86400000),
    Entitlements: {"com.apple.application-identifier": `${team}.${APP_ID}`, "com.apple.developer.team-identifier": team,
      "keychain-access-groups": [`${team}.*`]}
  }))
  writeFileSync(path.join(dir, "secrets.json"), JSON.stringify(secrets))
  // Every stand-in echoes every secret before it answers, as a tool that
  // prints its input would; nothing of it may reach a sentence.
  const echo = `node -e 'const s=require(process.argv[1]);for(const v of Object.values(s)){console.error(v,JSON.stringify(v),v.split(" ").join("\\\\ "))}' ${path.join(dir, "secrets.json")}`
  writeFileSync(path.join(bin, "security"), `#!/bin/sh
printf 'security %s\\n' "$*" >> ${log}
${handed("security")}
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
${handed("openssl")}
${echo}
out=""; prev=""; for a in "$@"; do [ "$prev" = -out ] && out="$a"; prev="$a"; done
if [ "$2" = -export ]; then [ -f "$4" ] && [ "$(stat -c %a "$4" 2>/dev/null || stat -f %Lp "$4")" = 600 ] || exit 8; cp "$4" "$out"; else cat > "$out"; fi
`)
  if (ps) writeFileSync(path.join(bin, "ps"), ps === "hang" ? "#!/bin/sh\nexec sleep 60\n" : "#!/bin/sh\nexit 1\n")
  for (const f of ["security", "openssl", ...(ps ? ["ps"] : [])]) chmodSync(path.join(bin, f), 0o755)
  const workerScript = path.join(dir, "worker.mjs")
  const marks = path.join(dir, "marks")
  mkdirSync(marks)
  const runModule = new URL("../scripts/run.mjs", import.meta.url).href
  writeFileSync(workerScript, `
import {spawn} from "node:child_process"
import {mkdirSync, readFileSync, writeFileSync} from "node:fs"
import path from "node:path"
import {run} from ${JSON.stringify(runModule)}
writeFileSync(${JSON.stringify(envs)}, "=== worker\\n" + Object.entries(process.env).map(([k, v]) => k + "=" + v + "\\n").join(""), {flag: "a"})
const args = process.argv.slice(2)
const out = args[args.indexOf("--out") + 1]
const config = JSON.parse(readFileSync(args[args.indexOf("--worker") + 1], "utf8"))
writeFileSync(${JSON.stringify(log)}, "worker " + config.phase + " " + args.join(" ") + "\\n", {flag: "a"})
mkdirSync(out, {recursive: true})
const image = path.join(out, "cyfr-desktop_1.0.0_darwin_arm64.dmg")
const secrets = JSON.parse(readFileSync(${JSON.stringify(path.join(dir, "secrets.json"))}, "utf8"))
for (const v of Object.values(secrets)) console.log("echo:", v, JSON.stringify(v), v.split(" ").join("\\\\ "))
const mode = ${JSON.stringify(worker)}
if (config.phase === "app") {
  if (mode === "deep") {
    // The packer starts a tool that starts a child, each marking it began
    // and, later, that it finished.
    const marks = ${JSON.stringify(marks)}
    writeFileSync(path.join(marks, "packer.pid"), String(process.pid))
    await run("/bin/sh", ["-c", "echo $$ > " + marks + "/tool.pid; (echo \\$\\$ > /dev/null; sh -c 'echo $$ > " + marks +
      "/child.pid; sleep 6; echo late > " + marks + "/child.finished') & sleep 6; echo late > " + marks + "/tool.finished"],
      {what: "the tool", seconds: 60})
    writeFileSync(path.join(marks, "packer.finished"), "late")
  }
  if (mode === "hang") {
    // A child that holds the packer's own output open, and outlives it
    // when no process list says it is there.
    const held = spawn("sleep", ["30"], {stdio: "inherit"})
    writeFileSync(path.join(${JSON.stringify(marks)}, "held.pid"), String(held.pid))
    await new Promise((resolve) => setTimeout(resolve, 60000))
  }
  const app = path.join(out, "mac-arm64", "CYFR.app")
  mkdirSync(app, {recursive: true})
  writeFileSync(config.result, JSON.stringify({helper: "ab".repeat(32), app}))
} else {
  if (mode === "half") { writeFileSync(image, "half a DMG"); process.exit(1) }
  writeFileSync(image, "a whole DMG")
}
`)
  const out = path.join(dir, "out")
  mkdirSync(out)
  const dest = path.join(out, "cyfr-desktop_1.0.0_darwin_arm64.dmg")
  return {dir, bin, log, envs, out, dest, marks, worker: {command: process.execPath, args: [workerScript], minutes: 0.05}}
}

// The owner holds the inputs in its own environment, as build.mjs's does.
async function run(r, {env = inputs, check = async () => {}} = {}) {
  const path0 = process.env.PATH
  process.env.PATH = `${r.bin}:${path0}`
  for (const [name, value] of Object.entries(env)) process.env[name] = value
  const printed = []
  try {
    await distribute({env: {...env, PATH: process.env.PATH}, dest: r.dest, worker: r.worker, openssl: path.join(r.bin, "openssl"),
      check, notarise: async () => {}, print: (text) => printed.push(text)})
    return {printed: printed.join("")}
  } catch (e) {
    return {printed: printed.join(""), error: e}
  } finally {
    process.env.PATH = path0
    for (const name of Object.keys(env)) delete process.env[name]
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
  assert.ok(error instanceof Refused && /^making and signing its DMG failed: exit 1$/.test(error.message), String(error))
  assert.equal(existsSync(r.dest), false)
  assert.deepEqual(leftovers(r), [])
  const calls = readFileSync(r.log, "utf8")
  assert.match(calls, /^security delete-keychain \S+signing\.keychain-db$/m)
  assert.match(calls, /^security list-keychains -d user -s \/Users\/runner\/Library\/Keychains\/login\.keychain-db$/m, "the search list restored")
})

test("a DMG that fails the check is not published", async (t) => {
  const r = rig(t)
  let publishedWhileChecked = null
  const {error} = await run(r, {check: async () => {
    publishedWhileChecked = existsSync(r.dest)
    throw new Refused("the image is refused")
  }})
  assert.equal(publishedWhileChecked, false, "the DMG stood at --out before its check")
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

test("a packer's bound stops the packer, the tool it started and the tool's child, before the refusal", async (t) => {
  const r = rig(t, {worker: "deep"})
  const started = Date.now()
  const {error} = await run(r)
  assert.ok(error instanceof Refused && /packing and signing the app failed: did not finish in 3 seconds/.test(error.message), String(error))
  assert.ok(Date.now() - started < 20000)
  // Gone as the refusal returns, each of the three.
  for (const name of ["packer", "tool", "child"]) {
    const pid = Number(readFileSync(path.join(r.marks, `${name}.pid`), "utf8"))
    assert.ok(goneNow(pid), `the ${name} outlived the refusal`)
  }
  // And none of them finishes later.
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 7000)
  assert.deepEqual(readdirSync(r.marks).filter((n) => n.endsWith(".finished")), [])
  assert.equal(existsSync(r.dest), false)
  assert.deepEqual(leftovers(r), [])
})

test("a bound whose process list cannot be read still ends, says so, and undoes the keychain and the search list", async (t) => {
  for (const ps of ["fail", "hang"]) {
    const r = rig(t, {worker: "hang", ps})
    t.after(() => { try { process.kill(Number(readFileSync(path.join(r.marks, "held.pid"), "utf8")), "SIGKILL") } catch {} })
    const started = Date.now()
    const {error} = await run(r)
    assert.equal(error?.message, "packing and signing the app failed: did not finish in 3 seconds, and the process list could not " +
      "be read, so what it started may still run", ps)
    assert.ok(Date.now() - started < 30000, `${ps}: the call ended within its bounds`)
    const calls = readFileSync(r.log, "utf8")
    assert.match(calls, /^security delete-keychain \S+signing\.keychain-db$/m, `${ps}: the keychain was deleted`)
    assert.match(calls, /^security list-keychains -d user -s \/Users\/runner\/Library\/Keychains\/login\.keychain-db$/m,
      `${ps}: the search list restored`)
    assert.equal(existsSync(r.dest), false)
    assert.deepEqual(leftovers(r), [])
  }
})

test("a tool is handed a secret only by a call that names it", async (t) => {
  const r = rig(t)
  const {error} = await run(r)
  assert.equal(error, undefined)
  const handed = readFileSync(r.envs, "utf8").split(/^=== /m).filter(Boolean).map((block) => {
    const [tool, ...lines] = block.split("\n").filter(Boolean)
    return {tool, lines, names: lines.map((l) => l.slice(0, l.indexOf("=")))}
  })
  assert.deepEqual([...new Set(handed.map((h) => h.tool))].sort(), ["openssl", "security", "worker"])
  for (const {tool, names, lines} of handed) {
    const inputsHanded = names.filter((n) => /^(APPLE_|CYFR_REHEARSAL_|CSC_|CYFR_BUILD_)/.test(n))
    assert.deepEqual(inputsHanded, tool === "worker" ? ["CYFR_BUILD_OWNER"] : [], `${tool} was handed ${inputsHanded}`)
    // openssl's one named secret is the only one any tool holds.
    const named = names.filter((n) => /^CYFR_(CERTIFICATE|WRAP)_PASSWORD$/.test(n))
    assert.equal(named.length, tool === "openssl" ? 1 : 0, tool)
    const rest = lines.filter((l) => !named.some((n) => l.startsWith(`${n}=`))).join("\n")
    assert.deepEqual(printedAnywhere(rest), [], `${tool} holds a secret its call did not name`)
  }
})

test("no secret reaches a command line, a printed line or a refusal, whole or in parts", async (t) => {
  const r = rig(t)
  const {printed, error} = await run(r)
  assert.equal(error, undefined)
  assert.equal(readFileSync(r.dest, "utf8"), "a whole DMG", "published by the rename")
  assert.deepEqual(leftovers(r), [])
  assert.match(printed, /echo: \*\*\*/, "the worker's echo was printed, hidden")
  assert.match(printed, /^built cyfr-desktop_1\.0\.0_darwin_arm64\.dmg in /m, "the last line too goes through the one printing function")
  assert.deepEqual(printedAnywhere(printed), [], "printed")
  const calls = readFileSync(r.log, "utf8")
  assert.deepEqual(printedAnywhere(calls), [], "on a command line")
  // The tools' own words, which carry every secret, in a refusal.
  const refused = await run(rig(t, {failAt: "import"}))
  assert.equal(refused.error.message, "the identity was not imported: exit 9")
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

// Whether the process `pid` has ended (or lingers only to be collected).
function goneNow(pid) {
  try {
    process.kill(pid, 0)
  } catch (e) {
    if (e.code === "ESRCH") return true
    throw e
  }
  try { return readFileSync(`/proc/${pid}/stat`, "utf8").split(") ")[1]?.[0] === "Z" } catch { return false }
}
