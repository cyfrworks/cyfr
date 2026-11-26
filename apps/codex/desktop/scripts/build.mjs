// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Build the CYFR app's package for one platform:
//
//   node scripts/build.mjs --cyfr PATH --version VERSION --arch amd64|arm64 [--out DIR]
//                          [--distribution [--rehearse]]
//
// The production entry (src/main.js) is bundled into one main.js; the
// app is exactly app.asar/{package.json,main.js} beside the verified cyfr
// at PATH, which goes outside the archive as resources/cyfr[.exe]. Before
// anything is signed or packed every file of the unpacked app is checked
// against that staging and the pinned Electron distribution
// (check-package.mjs), and a package that differs is not made.
// The package is cyfr-desktop_VERSION_OS_ARCH, a DEB on Linux (installed
// at /opt/cyfr/CYFR, the bundled cyfr linked as /usr/bin/cyfr, its
// sandbox's AppArmor profile loaded, the app's update service's units in
// /usr/lib/systemd/system), a DMG on macOS and an MSI on
// Windows, for this machine's platform. The MSI installs for the person
// alone, puts its bundled cyfr on their PATH, uses no Restart Manager and
// refuses to install or remove while the app is open (msi-project.mjs).
//
// A pull request's build signs nothing. On macOS --distribution makes the
// package a person downloads: signed with the Developer ID identity, the
// provisioning profile that authorises the app's WebAuthn group embedded,
// notarised and stapled, then checked (mac-sign.mjs, which names its
// inputs). It refuses to finish without every input and never falls back
// to an unsigned package. --rehearse signs with a self-made identity and
// profile instead and notarises nothing; its DMG fails a release's check.
// This process then owns the build (mac-distribution.mjs) and runs the
// packing and signing as its worker, this script again with --worker
// CONFIG, which no person passes. Windows packages are unsigned either way.

import {createHash} from "node:crypto"
import {chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync} from "node:fs"
import path from "node:path"
import {fileURLToPath} from "node:url"
import {parseArgs} from "node:util"

import {build as bundle} from "esbuild"
import {Arch, Platform, build} from "electron-builder"

import {Refused, checkPackage, filesOf} from "./check-package.mjs"
import {distribute} from "./mac-distribution.mjs"
import {APP_ID, signer, writeEntitlements} from "./mac-sign.mjs"
import {say} from "./run.mjs"
import {cyfrMsiProject} from "./msi-project.mjs"

// Every file the package installs is root's alone to change.
process.umask(0o022)
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const {values} = parseArgs({options: {
  cyfr: {type: "string"}, version: {type: "string"}, arch: {type: "string"}, out: {type: "string", default: path.join(root, "dist")},
  distribution: {type: "boolean", default: false}, rehearse: {type: "boolean", default: false}, worker: {type: "string"}
}})
if (!values.cyfr || !values.version || !["amd64", "arm64"].includes(values.arch) || (values.rehearse && !values.distribution)) {
  say("usage: node scripts/build.mjs --cyfr PATH --version VERSION --arch amd64|arm64 [--out DIR] [--distribution [--rehearse]]\n",
    {to: process.stderr})
  process.exit(64)
}

// A refusal ends the build with its sentence; anything else is a fault.
function refuse(e) {
  if (!(e instanceof Refused)) throw e
  say(`refused: ${e.message}\n`, {to: process.stderr})
  process.exit(1)
}

const os = {linux: "linux", darwin: "darwin", win32: "windows"}[process.platform]
// A Mac is Apple silicon: CYFR builds nothing for an Intel Mac, and
// amd64 is Linux's and Windows'.
if (os === "darwin" && values.arch !== "arm64") {
  refuse(new Refused("CYFR runs on Apple silicon Macs, so a Mac package is built for arm64 alone"))
}
const artifact = `cyfr-desktop_${values.version}_${os}_${values.arch}.\${ext}`
const built = artifact.replace("${ext}", {linux: "deb", darwin: "dmg", windows: "msi"}[os])
if (values.rehearse && os !== "darwin") {
  refuse(new Refused("a rehearsal signs a Mac package, and this is not a Mac"))
}
// A Mac distribution: this process owns the build, its keychain, its
// folder and its every printed line, and the worker packs and signs.
if (values.distribution && os === "darwin" && !values.worker) {
  process.on("uncaughtException", (e) => {
    say(`${e?.stack ?? e}\n`, {to: process.stderr})
    process.exit(1)
  })
  try {
    await distribute({env: process.env, dest: path.join(path.resolve(values.out), built), rehearse: values.rehearse,
      worker: {command: process.execPath, minutes: 50, args: [fileURLToPath(import.meta.url), "--cyfr", path.resolve(values.cyfr),
        "--version", values.version, "--arch", values.arch, "--distribution", ...(values.rehearse ? ["--rehearse"] : [])]}})
  } catch (e) {
    refuse(e)
  }
  process.exit(0)
}
// The worker's part of a distribution, as its owner wrote it and on the
// owner's word alone (ownerConfig): the phase, the identity's name, team
// and group, the profile's path, the unlocked keychain's path, whether it
// is a rehearsal, where its result goes and, for the DMG, the notarised
// app.
let signing = null
if (values.worker) {
  try {
    signing = ownerConfig(values.worker, {distribution: values.distribution, os})
  } catch (e) {
    refuse(e)
  }
}
// A Windows identity, once there is one, is given to electron-builder
// here; until then nothing in the environment signs the Windows package.
if (os === "windows") for (const name of ["CSC_LINK", "CSC_KEY_PASSWORD", "WIN_CSC_LINK", "WIN_CSC_KEY_PASSWORD"]) delete process.env[name]
const pkg = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"))
const electronVersion = pkg.devDependencies.electron
const stage = path.join(values.out, "stage")
const app = path.join(stage, "app")
rmSync(stage, {recursive: true, force: true})
mkdirSync(app, {recursive: true})

await bundle({
  entryPoints: [path.join(root, "src", "main.js")], outfile: path.join(app, "main.js"), bundle: true,
  platform: "node", format: "cjs", target: "node22", external: ["electron"], legalComments: "none",
  // Touch ID keeps passkeys in the WebAuthn group, which only a signed
  // app whose profile authorises it may use.
  define: {__CYFR_WEBAUTHN_GROUP__: JSON.stringify(signing?.group ?? "")}
})
writeFileSync(path.join(app, "package.json"), JSON.stringify({
  name: pkg.name, productName: "CYFR", version: values.version, description: pkg.description,
  homepage: "https://cyfr.run", author: {name: "CYFR Works Inc."},
  license: pkg.license, main: "main.js"
}, null, 2) + "\n")

// The CYFR logo cyfr's own pages show, at 512 pixels, the icon's size.
copyFileSync(path.join(root, "..", "internal", "setup", "assets", "logo.png"), path.join(stage, "icon.png"))
chmodSync(path.join(stage, "icon.png"), 0o644)

const executable = os === "windows" ? "cyfr.exe" : "cyfr"
const helper = path.join(stage, executable)
copyFileSync(values.cyfr, helper)
const staged = {
  product: "CYFR",
  distribution: null,
  files: {"package.json": readFileSync(path.join(app, "package.json")), "main.js": readFileSync(path.join(app, "main.js"))},
  helper: {name: executable, sha256: createHash("sha256").update(readFileSync(helper)).digest("hex")}
}

// A distribution's entitlements, beside the staged app; electron-builder
// signs from the owner's keychain, and signs a pull request's build only
// when told to, as a distribution's is. The owner notarises the app
// between the two phases.
let mac = {identity: null, category: "public.app-category.productivity"}
const signed = {}
if (signing) {
  Object.assign(process.env, {CSC_KEYCHAIN: signing.keychain, CSC_FOR_PULL_REQUEST: "true"})
  mac = {...mac, identity: signing.identity, type: "distribution", provisioningProfile: signing.profile,
    sign: signer(writeEntitlements(stage, signing.team, signing.group), staged.helper.sha256, signed), notarize: false}
  // The app phase stops at the signed app; the DMG phase makes the
  // notarised app's image and signs it, packing and signing nothing again
  // (electron-builder's prepackaged skips both).
}
const target = signing?.phase === "app" ? "dir" : {linux: "deb", darwin: "dmg", windows: "msi"}[os]

// The Linux package's install script is electron-builder's own, which
// links the app and loads its AppArmor profile, with the bundled cyfr
// linked onto PATH after it and the app's update service's socket enabled
// at every configure (a reinstall after a removal is told the release
// before it). Its removal stops the socket and every request it accepted
// before the units go with the package.
const template = (name) => readFileSync(path.join(root, "node_modules", "app-builder-lib", "templates", "linux", name), "utf8")
const systemd = "[ -d /run/systemd/system ]"
writeFileSync(path.join(stage, "after-install.tpl"), template("after-install.tpl") +
  "\nln -sf '/opt/${sanitizedProductName}/resources/cyfr' /usr/bin/cyfr\n" +
  `if ${systemd}; then systemctl daemon-reload; systemctl enable --now cyfr-update.socket || true; fi\n`)
writeFileSync(path.join(stage, "before-remove.sh"), "#!/bin/sh\n" +
  `if [ "$1" = remove ] && ${systemd}; then systemctl disable --now cyfr-update.socket || true; systemctl stop 'cyfr-update@*.service' || true; fi\n`)
writeFileSync(path.join(stage, "after-remove.tpl"), template("after-remove.tpl") +
  "\nif [ \"$(readlink /usr/bin/cyfr)\" = '/opt/${sanitizedProductName}/resources/cyfr' ]; then rm -f /usr/bin/cyfr; fi\n" +
  `if ${systemd}; then systemctl daemon-reload; fi\n`)
// The units are staged root's alone to change, whatever the checkout's
// modes, as fpm keeps them.
const unit = (name) => {
  const file = path.join(stage, name)
  copyFileSync(path.join(root, "linux", name), file)
  chmodSync(file, 0o644)
  return `${file}=/usr/lib/systemd/system/${name}`
}

await build({
  targets: {linux: Platform.LINUX, darwin: Platform.MAC, windows: Platform.WINDOWS}[os]
    .createTarget(target, values.arch === "arm64" ? Arch.arm64 : Arch.x64),
  ...(signing?.phase === "dmg" ? {prepackaged: signing.app} : {}),
  config: {
    appId: APP_ID,
    // The Linux package installs at /opt/<this>/, which is /opt/cyfr; the
    // app's name everywhere a person reads it stays CYFR.
    productName: os === "linux" ? "cyfr" : "CYFR",
    electronVersion,
    directories: {app, output: values.out},
    files: ["package.json", "main.js"],
    asar: true,
    npmRebuild: false,
    nodeGypRebuild: false,
    extraResources: [{from: helper, to: executable}],
    artifactName: artifact,
    electronFuses: {
      runAsNode: false,
      enableCookieEncryption: true,
      enableNodeOptionsEnvironmentVariable: false,
      enableNodeCliInspectArguments: false,
      enableEmbeddedAsarIntegrityValidation: true,
      onlyLoadAppFromAsar: true,
      loadBrowserProcessSpecificV8Snapshot: false,
      grantFileProtocolExtraPrivileges: false,
      // Flipping fuses breaks the ad hoc signature an arm64 Mac app needs
      // to launch at all; an unsigned build is signed ad hoc again.
      resetAdHocDarwinSignature: os === "darwin" && values.arch === "arm64"
    },
    // The pinned Electron distribution as electron-builder extracted it,
    // before the app is added: the guard's roster of Electron's files.
    afterExtract: async (context) => {
      staged.distribution = filesOf(context.appOutDir)
    },
    afterPack: async (context) => {
      checkPackage(context.appOutDir, staged, os)
      // What is installed is root's alone to change, whatever this
      // machine's umask made of the copies.
      if (os === "linux") unwritableByOthers(context.appOutDir)
    },
    icon: path.join(stage, "icon.png"),
    linux: {executableName: "CYFR", category: "Network", maintainer: "CYFR Works Inc.",
      synopsis: "CYFR in a window of its own",
      vendor: "CYFR Works Inc.", desktop: {entry: {Name: "CYFR"}}},
    deb: {packageName: "cyfr-desktop",
      depends: ["libgtk-3-0", "libnotify4", "libnss3", "libxss1", "libxtst6", "xdg-utils", "libatspi2.0-0", "libuuid1",
        "libsecret-1-0", "libgbm1", "libasound2t64 | libasound2"],
      afterInstall: path.join(stage, "after-install.tpl"),
      afterRemove: path.join(stage, "after-remove.tpl"),
      fpm: ["--before-remove", path.join(stage, "before-remove.sh"), unit("cyfr-update.socket"), unit("cyfr-update@.service")]},
    // A distribution build fails rather than leave the app or its DMG
    // unsigned.
    forceCodeSigning: signing !== null,
    mac,
    dmg: {sign: signing !== null, writeUpdateInfo: false},
    win: {executableName: "CYFR"},
    msi: {oneClick: true, perMachine: false},
    msiProjectCreated: (project) => writeFileSync(project, cyfrMsiProject(readFileSync(project, "utf8")))
  },
  publish: "never"
})
if (signing?.phase === "app") {
  const signedApp = path.join(values.out, `mac${values.arch === "arm64" ? "-arm64" : ""}`, "CYFR.app")
  writeFileSync(signing.result, JSON.stringify({helper: signed.helper ?? null, app: existsSync(signedApp) ? signedApp : null}))
}
say(`built ${signing?.phase === "app" ? "CYFR.app" : built} in ${values.out}\n`)

// chmod -R go-w, in this process.
function unwritableByOthers(dir) {
  for (const name of readdirSync(dir)) {
    const p = path.join(dir, name)
    const st = lstatSync(p)
    if (st.isSymbolicLink()) continue
    chmodSync(p, st.mode & 0o7755)
    if (st.isDirectory()) unwritableByOthers(p)
  }
}

/**
 * The worker's configuration at `file`, refused unless the owner wrote it
 * for this very process: a distribution on macOS, started by the process
 * the configuration names, whose word (CYFR_BUILD_OWNER) it carries, and
 * every field present and of its kind.
 */
function ownerConfig(file, {distribution, os}) {
  if (!distribution || os !== "darwin") throw new Refused("--worker is a Mac distribution's own, started by its owner")
  let config
  try { config = JSON.parse(readFileSync(file, "utf8")) } catch { throw new Refused("the worker's configuration is not the owner's") }
  const string = (v) => typeof v === "string" && v !== ""
  const complete = config !== null && typeof config === "object" && !Array.isArray(config) &&
    ["app", "dmg"].includes(config.phase) && string(config.owner) && Number.isInteger(config.ownerPid) &&
    ["identity", "team", "group", "profile", "keychain", "result"].every((k) => string(config[k])) &&
    typeof config.rehearsed === "boolean" && (config.phase === "app" || string(config.app))
  if (!complete) throw new Refused("the worker's configuration is not complete")
  if (process.env.CYFR_BUILD_OWNER !== config.owner || process.ppid !== config.ownerPid) {
    throw new Refused("the worker was not started by its owner")
  }
  return config
}
