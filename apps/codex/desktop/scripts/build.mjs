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
// sandbox's AppArmor profile loaded), a DMG on macOS and an MSI on
// Windows, for this machine's platform. The MSI installs for the person
// alone and puts its bundled cyfr on their PATH (msi-path.mjs).
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

import {execFileSync} from "node:child_process"
import {createHash} from "node:crypto"
import {chmodSync, copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync} from "node:fs"
import path from "node:path"
import {fileURLToPath} from "node:url"
import {parseArgs} from "node:util"

import {build as bundle} from "esbuild"
import {Arch, Platform, build} from "electron-builder"

import {Refused, checkPackage, filesOf, redact} from "./check-package.mjs"
import {distribute} from "./mac-distribution.mjs"
import {APP_ID, notarize, signer, writeEntitlements} from "./mac-sign.mjs"
import {addCyfrToPath} from "./msi-path.mjs"

// Every file the package installs is root's alone to change.
process.umask(0o022)
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const {values} = parseArgs({options: {
  cyfr: {type: "string"}, version: {type: "string"}, arch: {type: "string"}, out: {type: "string", default: path.join(root, "dist")},
  distribution: {type: "boolean", default: false}, rehearse: {type: "boolean", default: false}, worker: {type: "string"}
}})
if (!values.cyfr || !values.version || !["amd64", "arm64"].includes(values.arch) || (values.rehearse && !values.distribution)) {
  console.error("usage: node scripts/build.mjs --cyfr PATH --version VERSION --arch amd64|arm64 [--out DIR] [--distribution [--rehearse]]")
  process.exit(64)
}

// A refusal ends the build with its sentence; anything else is a fault.
function refuse(e) {
  if (!(e instanceof Refused)) throw e
  console.error(`refused: ${e.message}`)
  process.exit(1)
}

const os = {linux: "linux", darwin: "darwin", win32: "windows"}[process.platform]
const artifact = `cyfr-desktop_${values.version}_${os}_${values.arch}.\${ext}`
const built = artifact.replace("${ext}", {linux: "deb", darwin: "dmg", windows: "msi"}[os])
if (values.rehearse && os !== "darwin") {
  console.error("refused: a rehearsal signs a Mac package, and this is not a Mac")
  process.exit(1)
}
// A Mac distribution: this process owns the build, its keychain, its
// folder and its every printed line, and the worker packs and signs.
if (values.distribution && os === "darwin" && !values.worker) {
  process.on("uncaughtException", (e) => {
    console.error(redact(e?.stack ?? e))
    process.exit(1)
  })
  try {
    await distribute({env: process.env, dest: path.join(path.resolve(values.out), built), rehearse: values.rehearse,
      worker: {command: process.execPath, minutes: 50, args: [fileURLToPath(import.meta.url), "--cyfr", path.resolve(values.cyfr),
        "--version", values.version, "--arch", values.arch, "--distribution", ...(values.rehearse ? ["--rehearse"] : [])]}})
  } catch (e) {
    refuse(e)
  }
  console.log(`built ${built}${values.rehearse ? " (rehearsed: not notarised, not for release)" : ""} in ${values.out}`)
  process.exit(0)
}
// The worker's part of a distribution, as its owner wrote it: the
// identity's name, team and group, the profile's path, the unlocked
// keychain's path, whether it is a rehearsal and where the signed cyfr's
// SHA-256 goes.
const signing = values.worker && values.distribution && os === "darwin" ? JSON.parse(readFileSync(values.worker, "utf8")) : null
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
// when told to, as a distribution's is. The app is notarised (unless
// rehearsed) once signed, before its DMG is made.
let mac = {identity: null, category: "public.app-category.productivity"}
const signed = {}
if (signing) {
  Object.assign(process.env, {CSC_KEYCHAIN: signing.keychain, CSC_FOR_PULL_REQUEST: "true"})
  mac = {...mac, identity: signing.identity, type: "distribution", provisioningProfile: signing.profile,
    sign: signer(writeEntitlements(stage, signing.team, signing.group), staged.helper.sha256, signed), notarize: false}
}

// The Linux package's install script is electron-builder's own, which
// links the app and loads its AppArmor profile, with the bundled cyfr
// linked onto PATH after it.
const template = (name) => readFileSync(path.join(root, "node_modules", "app-builder-lib", "templates", "linux", name), "utf8")
writeFileSync(path.join(stage, "after-install.tpl"), template("after-install.tpl") +
  "\nln -sf '/opt/${sanitizedProductName}/resources/cyfr' /usr/bin/cyfr\n")
writeFileSync(path.join(stage, "after-remove.tpl"), template("after-remove.tpl") +
  "\nif [ \"$(readlink /usr/bin/cyfr)\" = '/opt/${sanitizedProductName}/resources/cyfr' ]; then rm -f /usr/bin/cyfr; fi\n")

await build({
  targets: {linux: Platform.LINUX, darwin: Platform.MAC, windows: Platform.WINDOWS}[os]
    .createTarget({linux: "deb", darwin: "dmg", windows: "msi"}[os], values.arch === "arm64" ? Arch.arm64 : Arch.x64),
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
    afterSign: async (context) => {
      if (signing && !signing.rehearsed) {
        notarize(path.join(context.appOutDir, "CYFR.app"), {key: process.env.CYFR_NOTARY_KEY, ...signing.notary}, signing.work)
      }
    },
    afterPack: async (context) => {
      checkPackage(context.appOutDir, staged, os)
      // What is installed is root's alone to change, whatever this
      // machine's umask made of the copies.
      if (os === "linux") execFileSync("chmod", ["-R", "go-w", context.appOutDir])
    },
    icon: path.join(stage, "icon.png"),
    linux: {executableName: "CYFR", category: "Network", maintainer: "CYFR Works Inc.",
      synopsis: "CYFR in a window of its own",
      vendor: "CYFR Works Inc.", desktop: {entry: {Name: "CYFR"}}},
    deb: {packageName: "cyfr-desktop",
      depends: ["libgtk-3-0", "libnotify4", "libnss3", "libxss1", "libxtst6", "xdg-utils", "libatspi2.0-0", "libuuid1",
        "libsecret-1-0", "libgbm1", "libasound2t64 | libasound2"],
      afterInstall: path.join(stage, "after-install.tpl"),
      afterRemove: path.join(stage, "after-remove.tpl")},
    // A distribution build fails rather than leave the app or its DMG
    // unsigned.
    forceCodeSigning: signing !== null,
    mac,
    dmg: {sign: signing !== null, writeUpdateInfo: false},
    win: {executableName: "CYFR"},
    msi: {oneClick: true, perMachine: false},
    msiProjectCreated: (project) => writeFileSync(project, addCyfrToPath(readFileSync(project, "utf8")))
  },
  publish: "never"
})
if (signing) writeFileSync(signing.result, JSON.stringify({helper: signed.helper ?? null}))
console.log(`built ${built} in ${values.out}`)
