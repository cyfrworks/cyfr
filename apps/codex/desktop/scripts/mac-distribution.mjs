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
//   - No value of a secret input reaches a command line. The certificate is
//     opened from standard input with its password in openssl's
//     environment (-passin env:, openssl-passphrase-options(1); LibreSSL's
//     openssl(1), "Pass phrase arguments") into a mode-0600 file, and
//     wrapped again under a password made for this run, which is the only
//     one `security import -P` sees (security(1) takes a passphrase as an
//     argument alone); the keychain's password is made for this run too.
//     The notary's private key is a mode-0600 file for its one command.
//   - A tool is handed a secret only by a call that names it: run()'s
//     default environment is this process's without the inputs.
//   - A tool handed a secret never speaks: run() (run.mjs) gives back only
//     what the recipe parses from it, and a failed call only its exit
//     status. Everything printed goes through redact() as a second line.
//     The identity's name and the team ID are in every signed app and are
//     printed; the profile and the WebAuthn group are shipped inside the app.
//   - The packing runs as a worker (build.mjs --worker) handed no secret,
//     in two phases: the app, packed and signed; then, once this owner has
//     notarised the app and stapled its ticket, its DMG, made and signed.
//     Each phase's bound, like every tool's, stops it and everything
//     beneath it (run.mjs stopTree).

import {randomBytes} from "node:crypto"
import {chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync} from "node:fs"
import path from "node:path"
import {fileURLToPath} from "node:url"

import {Refused, hide, redact} from "./check-package.mjs"
import {checkDmg, checkProfile, decodeProfile, notarize, signingInputs} from "./mac-sign.mjs"
import {run, say, withoutInputs} from "./run.mjs"

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
 * Build, sign, notarise, check and publish the Mac distribution's DMG at
 * `dest`. `env` holds the inputs (mac-sign.mjs signingInputs); `worker` is
 * {command, args, minutes}, the packing, run with --out and --worker CONFIG
 * appended and the owner's word in its environment; `openssl` the tool
 * that opens the certificate (/usr/bin/openssl, LibreSSL); `notarise` and
 * `check` the app's and image's notarisation and the image's check
 * (mac-sign.mjs notarize and checkDmg); `print` where every line goes,
 * through redact(). Throws Refused, leaving no DMG at dest.
 */
export async function distribute({env, dest, rehearse = false, worker, openssl = "/usr/bin/openssl", check = checkDmg,
  notarise = notarize, print = (text) => say(text)}) {
  const tell = (text) => print(redact(text))
  rmSync(dest, {force: true})
  const inputs = signingInputs(env, {rehearse})
  const keychainPassword = randomBytes(24).toString("hex")
  const wrapPassword = randomBytes(24).toString("hex")
  hide([inputs.certificate, inputs.certificatePassword, env.APPLE_API_KEY, inputs.notary?.key, keychainPassword, wrapPassword])
  checkProfile(await decodeProfile(inputs.profile), inputs)

  const out = path.dirname(dest)
  mkdirSync(out, {recursive: true})
  const work = mkdtempSync(path.join(out, ".cyfr-signing-"))
  chmodSync(work, 0o700)
  const keychain = path.join(work, "signing.keychain-db")
  const undo = [async () => rmSync(work, {recursive: true, force: true})]
  // A crash still takes the folder; the keychain and the search list are
  // undone, in order, on every other exit below.
  const lastResort = () => rmSync(work, {recursive: true, force: true})
  process.once("exit", lastResort)
  let failure = null
  try {
    // The keychain goes, if it came to be, before the folder holding it.
    undo.push(async () => {
      if (!existsSync(keychain)) return
      await run("security", ["delete-keychain", keychain], {what: "the signing keychain was not deleted", seconds: 60})
      rmSync(keychain, {force: true})
    })
    const opened = path.join(work, "identity.pem")
    const wrapped = path.join(work, "identity.p12")
    const pathOnly = env.PATH ?? process.env.PATH
    try {
      await run(openssl, ["pkcs12", "-in", "/dev/stdin", "-passin", "env:CYFR_CERTIFICATE_PASSWORD", "-nodes", "-out", opened],
        {what: "the certificate does not open with its password", seconds: 60, secret: true,
          input: Buffer.from(inputs.certificate, "base64"), env: {PATH: pathOnly, CYFR_CERTIFICATE_PASSWORD: inputs.certificatePassword}})
      chmodSync(opened, 0o600)
      // LibreSSL's pkcs12 -export opens its input once for the key and again
      // for the certificates, which a pipe cannot give twice (measured on
      // GitHub's macOS runner): the opened identity is a file.
      await run(openssl, ["pkcs12", "-export", "-in", opened, "-out", wrapped, "-passout", "env:CYFR_WRAP_PASSWORD",
        "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"],
      {what: "the certificate was not wrapped for the keychain", seconds: 60, secret: true,
        env: {PATH: pathOnly, CYFR_WRAP_PASSWORD: wrapPassword}})
    } finally {
      rmSync(opened, {force: true})
    }
    chmodSync(wrapped, 0o600)
    const keychainCall = (args, what) => run("security", args, {what, seconds: 60, secret: true})
    await keychainCall(["create-keychain", "-p", keychainPassword, keychain], "the signing keychain was not made")
    await keychainCall(["unlock-keychain", "-p", keychainPassword, keychain], "the signing keychain was not unlocked")
    await keychainCall(["set-keychain-settings", keychain], "the signing keychain would lock itself")
    await keychainCall(["import", wrapped, "-k", keychain, "-P", wrapPassword, "-T", "/usr/bin/codesign"], "the identity was not imported")
    rmSync(wrapped, {force: true})
    await keychainCall(["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", keychainPassword, keychain],
      "the identity's key was not opened to codesign")
    const before = await run("security", ["list-keychains", "-d", "user"], {what: "the keychain search list was not read", seconds: 60,
      read: searchList})
    // An account always has a search list; an empty answer restored would
    // empty it.
    if (before.length === 0) throw new Refused("the keychain search list read as empty")
    const roots = path.join(work, "root_certs.keychain")
    copyFileSync(ROOT_CERTS, roots)
    undo.push(() => run("security", ["list-keychains", "-d", "user", "-s", ...before],
      {what: "the keychain search list was not restored", seconds: 60}))
    await run("security", ["list-keychains", "-d", "user", "-s", keychain, roots, ...before],
      {what: "the signing keychain is not on the search list", seconds: 60})

    const profile = path.join(work, "embedded.provisionprofile")
    writeFileSync(profile, inputs.profile, {mode: 0o600})
    const owner = randomBytes(16).toString("hex")
    const built = path.join(work, "out")
    const result = path.join(work, "result.json")
    // The worker is handed no secret: its keychain is unlocked already.
    const workerEnv = withoutInputs(process.env)
    workerEnv.CYFR_BUILD_OWNER = owner
    const phase = async (name, extra = {}) => {
      const config = path.join(work, `${name}.json`)
      writeFileSync(config, JSON.stringify({phase: name, owner, ownerPid: process.pid, identity: inputs.identity, team: inputs.team,
        group: inputs.group, profile, keychain, rehearsed: inputs.rehearsed, result, ...extra}), {mode: 0o600})
      await run(worker.command, [...worker.args, "--out", built, "--worker", config],
        {what: `${name === "app" ? "packing and signing the app" : "making and signing its DMG"} failed`, seconds: worker.minutes * 60,
          env: workerEnv, stream: tell})
    }
    await phase("app")
    let helper, app
    try { ({helper, app} = JSON.parse(readFileSync(result, "utf8"))) } catch { throw new Refused("packing and signing the app left no result") }
    if (typeof app !== "string" || !existsSync(app)) throw new Refused("packing and signing the app left no CYFR.app")
    if (!inputs.rehearsed) await notarise(app, inputs.notary, work)
    await phase("dmg", {app})
    const image = path.join(built, path.basename(dest))
    if (!existsSync(image)) throw new Refused(`making the DMG left no ${path.basename(dest)}`)
    if (!inputs.rehearsed) await notarise(image, inputs.notary, work)
    await check(image, {...inputs, helper}, {rehearsed: inputs.rehearsed})
    renameSync(image, dest)
    tell(`the bundled cyfr is signed as sha256 ${helper}\n`)
    tell(`built ${path.basename(dest)}${inputs.rehearsed ? " (rehearsed: not notarised, not for release)" : ""} in ${out}\n`)
  } catch (e) {
    failure = e
  }
  process.removeListener("exit", lastResort)
  const failed = []
  while (undo.length) {
    try { await undo.pop()() } catch (e) { failed.push(e instanceof Refused ? e.message : "a fault") }
  }
  if (failed.length) {
    rmSync(dest, {force: true})
    const after = failure ? `, after ${failure instanceof Refused ? failure.message : "a fault"}` : ""
    throw new Refused(`the build did not leave things as it found them: ${failed.join("; ")}${after}`)
  }
  if (failure) {
    rmSync(dest, {force: true})
    throw failure
  }
}
