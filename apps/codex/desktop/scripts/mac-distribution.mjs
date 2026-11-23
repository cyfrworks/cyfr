// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The owner of a Mac distribution build (build.mjs --distribution on
// macOS): everything the build makes and leaves is this module's, and so is
// every sentence it prints.
//
//   - The DMG at --out is removed first, whatever follows, and a DMG appears
//     there again only by a rename once the finished image has passed the
//     check (mac-sign.mjs checkDmg); a refused or failed build leaves none,
//     neither a partial one nor the one from before.
//   - The build works in a folder of its own beside the DMG (mode 0700),
//     removed with everything in it on every exit.
//   - The signing keychain lives in that folder. Its removal, and the
//     restoring of the account's keychain search list, are registered
//     before the keychain or the list changes, so no failure after either
//     can leave them.
//   - No value of a secret input reaches a command line or a sentence. The
//     certificate is opened from standard input with its password in the
//     environment (openssl's -passin env:, openssl-passphrase-options(1);
//     LibreSSL's openssl(1), "Pass phrase arguments") and wrapped again under
//     a password made for this run, which is the only one `security import
//     -P` sees (security(1) takes the passphrase as an argument alone); the
//     keychain's password is made for this run too. Every line the build
//     and its tools print, and every refusal, passes through redact()
//     (check-package.mjs), which knows every input's value. The identity's
//     name and the team ID are in every signed app and are printed; the
//     profile and the WebAuthn group are shipped inside the app.
//   - The packing and signing run in a child process (build.mjs --worker)
//     that leads a process group of its own; when its bound runs out the
//     whole group is killed, and so is every tool's (mac-sign.mjs tool).

import {spawn} from "node:child_process"
import {randomBytes} from "node:crypto"
import {chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync} from "node:fs"
import path from "node:path"
import {fileURLToPath} from "node:url"

import {Refused, hide, redact} from "./check-package.mjs"
import {checkDmg, checkProfile, decodeProfile, must, notarize, signingInputs, tool} from "./mac-sign.mjs"

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))

// electron-builder's own keychain of Apple's intermediate certificates,
// which its builds put on the search list for codesign to build a
// Developer ID chain; this build does the same with a copy of its own.
const ROOT_CERTS = path.join(root, "node_modules", "app-builder-lib", "certs", "root_certs.keychain")

/**
 * The account's keychain search list, as `security list-keychains -d user`
 * prints it: one quoted path a line.
 */
export function searchList(printed) {
  return printed.split("\n").map((line) => line.trim().replace(/^"(.*)"$/, "$1")).filter((line) => line !== "")
}

/**
 * Run `command` with `args` as a process group of its own, its output
 * printed line by line through redact() by `print`, within `minutes`:
 * its exit status, or Refused when the bound ran out and the group was
 * killed.
 */
export function supervise(command, args, {env, minutes, print, what}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {env, detached: true, stdio: ["ignore", "pipe", "pipe"]})
    // A group already gone is stopped; one that could not be signalled is
    // not, and says so.
    let unkilled = null
    const kill = () => {
      try { process.kill(-child.pid, "SIGKILL") } catch (e) { if (e.code !== "ESRCH") unkilled = e }
    }
    process.once("exit", kill)
    const lines = (stream) => {
      let held = ""
      stream.setEncoding("utf8")
      stream.on("data", (chunk) => {
        held += chunk
        const at = held.lastIndexOf("\n")
        if (at < 0) return
        print(redact(held.slice(0, at + 1)))
        held = held.slice(at + 1)
      })
      stream.on("end", () => { if (held) print(redact(held + "\n")) })
    }
    lines(child.stdout)
    lines(child.stderr)
    let outran = false
    const timer = setTimeout(() => { outran = true; kill() }, minutes * 60000)
    child.on("error", (e) => { clearTimeout(timer); reject(new Refused(`${what} could not start: ${e.message}`)) })
    child.on("close", (code, signal) => {
      clearTimeout(timer)
      process.removeListener("exit", kill)
      // What the child left running in its group goes with it.
      kill()
      if (unkilled) reject(new Refused(`${what} could not be stopped: ${unkilled.code}`))
      else if (outran) reject(new Refused(`${what} did not finish in ${minutes} minutes`))
      else resolve(code ?? 128 + (signal ? 9 : 0))
    })
  })
}

/**
 * Build, sign, check and publish the Mac distribution's DMG at `dest`.
 * `env` holds the inputs (mac-sign.mjs signingInputs); `worker` is
 * {command, args, minutes}, the packing and signing, run with --out and
 * --worker CONFIG appended; `openssl` the tool that opens the certificate
 * (/usr/bin/openssl, LibreSSL); `notarise` and `check` the finished
 * image's notarisation and check (mac-sign.mjs notarize and checkDmg);
 * `print` where every line goes. Throws Refused, leaving no DMG at dest.
 */
export async function distribute({env, dest, rehearse = false, worker, openssl = "/usr/bin/openssl", check = checkDmg,
  notarise = notarize, print = (text) => process.stdout.write(text)}) {
  rmSync(dest, {force: true})
  const inputs = signingInputs(env, {rehearse})
  const keychainPassword = randomBytes(24).toString("hex")
  const wrapPassword = randomBytes(24).toString("hex")
  hide([inputs.certificate, inputs.certificatePassword, inputs.appleId, inputs.applePassword, keychainPassword, wrapPassword])
  checkProfile(decodeProfile(inputs.profile), inputs)

  const out = path.dirname(dest)
  mkdirSync(out, {recursive: true})
  const work = mkdtempSync(path.join(out, ".cyfr-signing-"))
  chmodSync(work, 0o700)
  const keychain = path.join(work, "signing.keychain-db")
  const undo = [() => rmSync(work, {recursive: true, force: true})]
  const cleanup = () => {
    const failed = []
    while (undo.length) {
      try { undo.pop()() } catch (e) { failed.push(redact(e.message)) }
    }
    return failed
  }
  process.once("exit", cleanup)
  let failure = null
  try {
    // The keychain goes, if it came to be, before the folder holding it.
    undo.push(() => {
      if (!existsSync(keychain)) return
      const r = tool("security", ["delete-keychain", keychain], 60)
      rmSync(keychain, {force: true})
      if (!r.ok) throw new Refused(`the signing keychain was not deleted: ${(r.err || r.out).trim()}`)
    })
    const certificate = Buffer.from(inputs.certificate, "base64")
    const pem = must(openssl, ["pkcs12", "-in", "/dev/stdin", "-passin", "env:CYFR_CERTIFICATE_PASSWORD", "-nodes"],
      "the certificate does not open with its password", 60,
      {input: certificate, env: {PATH: env.PATH ?? process.env.PATH, CYFR_CERTIFICATE_PASSWORD: inputs.certificatePassword}}).out
    const wrapped = path.join(work, "identity.p12")
    must(openssl, ["pkcs12", "-export", "-in", "/dev/stdin", "-out", wrapped, "-passout", "env:CYFR_WRAP_PASSWORD",
      "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"],
    "the certificate was not wrapped for the keychain", 60, {input: pem, env: {PATH: env.PATH ?? process.env.PATH, CYFR_WRAP_PASSWORD: wrapPassword}})
    chmodSync(wrapped, 0o600)

    must("security", ["create-keychain", "-p", keychainPassword, keychain], "the signing keychain was not made", 60)
    must("security", ["unlock-keychain", "-p", keychainPassword, keychain], "the signing keychain was not unlocked", 60)
    must("security", ["set-keychain-settings", keychain], "the signing keychain would lock itself", 60)
    must("security", ["import", wrapped, "-k", keychain, "-P", wrapPassword, "-T", "/usr/bin/codesign"],
      "the identity was not imported", 60)
    rmSync(wrapped, {force: true})
    must("security", ["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", keychainPassword, keychain],
      "the identity's key was not opened to codesign", 60)
    const before = searchList(must("security", ["list-keychains", "-d", "user"], "the keychain search list was not read", 60).out)
    // An account always has a search list; an empty answer restored would
    // empty it.
    if (before.length === 0) throw new Refused("the keychain search list read as empty")
    const roots = path.join(work, "root_certs.keychain")
    copyFileSync(ROOT_CERTS, roots)
    undo.push(() => must("security", ["list-keychains", "-d", "user", "-s", ...before], "the keychain search list was not restored", 60))
    must("security", ["list-keychains", "-d", "user", "-s", keychain, roots, ...before], "the signing keychain is not on the search list", 60)

    const profile = path.join(work, "embedded.provisionprofile")
    writeFileSync(profile, inputs.profile, {mode: 0o600})
    const result = path.join(work, "result.json")
    const config = path.join(work, "config.json")
    writeFileSync(config, JSON.stringify({identity: inputs.identity, team: inputs.team, group: inputs.group, profile, keychain,
      rehearsed: inputs.rehearsed, result}), {mode: 0o600})
    // The packing sees no secret input: its keychain is unlocked already.
    const workerEnv = Object.fromEntries(Object.entries(process.env).filter(([name]) => !/^(APPLE_|CYFR_REHEARSAL_|CSC_)/.test(name)))
    const built = path.join(work, "out")
    const status = await supervise(worker.command, [...worker.args, "--out", built, "--worker", config],
      {env: workerEnv, minutes: worker.minutes, print, what: "packing and signing the app"})
    if (status !== 0) throw new Refused(`packing and signing the app failed (exit ${status})`)
    let helper
    try { ({helper} = JSON.parse(readFileSync(result, "utf8"))) } catch { throw new Refused("packing and signing the app left no result") }
    const image = path.join(built, path.basename(dest))
    if (!existsSync(image)) throw new Refused(`packing and signing the app left no ${path.basename(dest)}`)
    if (!inputs.rehearsed) await notarise(image, inputs)
    await check(image, {...inputs, helper}, {rehearsed: inputs.rehearsed})
    renameSync(image, dest)
    print(`the bundled cyfr is signed as sha256 ${helper}\n`)
  } catch (e) {
    failure = e
  }
  process.removeListener("exit", cleanup)
  const failed = cleanup()
  if (failed.length) {
    rmSync(dest, {force: true})
    const after = failure ? `, after ${failure instanceof Refused ? failure.message : "a fault"}` : ""
    throw new Refused(`the build did not leave things as it found them: ${failed.join("; ")}${after}`)
  }
  if (failure) throw failure
}
