// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Build the CYFR app's package for one platform:
//
//   node scripts/build.mjs --cyfr PATH --version VERSION --arch amd64|arm64 [--out DIR]
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
// Windows, for this machine's platform.

import {execFileSync} from "node:child_process"
import {createHash} from "node:crypto"
import {chmodSync, copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync} from "node:fs"
import path from "node:path"
import {fileURLToPath} from "node:url"
import {parseArgs} from "node:util"

import {build as bundle} from "esbuild"
import {Arch, Platform, build} from "electron-builder"

import {checkPackage, filesOf} from "./check-package.mjs"

// Every file the package installs is root's alone to change.
process.umask(0o022)
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const {values} = parseArgs({options: {
  cyfr: {type: "string"}, version: {type: "string"}, arch: {type: "string"}, out: {type: "string", default: path.join(root, "dist")}
}})
if (!values.cyfr || !values.version || !["amd64", "arm64"].includes(values.arch)) {
  console.error("usage: node scripts/build.mjs --cyfr PATH --version VERSION --arch amd64|arm64 [--out DIR]")
  process.exit(64)
}

const os = {linux: "linux", darwin: "darwin", win32: "windows"}[process.platform]
const pkg = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"))
const electronVersion = pkg.devDependencies.electron
const stage = path.join(values.out, "stage")
const app = path.join(stage, "app")
rmSync(stage, {recursive: true, force: true})
mkdirSync(app, {recursive: true})

await bundle({
  entryPoints: [path.join(root, "src", "main.js")], outfile: path.join(app, "main.js"), bundle: true,
  platform: "node", format: "cjs", target: "node22", external: ["electron"], legalComments: "none",
  define: {__CYFR_TOUCH_ID_GROUP__: JSON.stringify(process.env.CYFR_TOUCH_ID_GROUP ?? "")}
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

// The Linux package's install script is electron-builder's own, which
// links the app and loads its AppArmor profile, with the bundled cyfr
// linked onto PATH after it.
const template = (name) => readFileSync(path.join(root, "node_modules", "app-builder-lib", "templates", "linux", name), "utf8")
writeFileSync(path.join(stage, "after-install.tpl"), template("after-install.tpl") +
  "\nln -sf '/opt/${sanitizedProductName}/resources/cyfr' /usr/bin/cyfr\n")
writeFileSync(path.join(stage, "after-remove.tpl"), template("after-remove.tpl") +
  "\nif [ \"$(readlink /usr/bin/cyfr)\" = '/opt/${sanitizedProductName}/resources/cyfr' ]; then rm -f /usr/bin/cyfr; fi\n")

const artifact = `cyfr-desktop_${values.version}_${os}_${values.arch}.\${ext}`
await build({
  targets: {linux: Platform.LINUX, darwin: Platform.MAC, windows: Platform.WINDOWS}[os]
    .createTarget({linux: "deb", darwin: "dmg", windows: "msi"}[os], values.arch === "arm64" ? Arch.arm64 : Arch.x64),
  config: {
    appId: "run.cyfr.desktop",
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
      if (os === "linux") execFileSync("chmod", ["-R", "go-w", context.appOutDir])
    },
    icon: path.join(stage, "icon.png"),
    linux: {executableName: "CYFR", category: "Network", maintainer: "CYFR Works Inc.",
      vendor: "CYFR Works Inc.", desktop: {entry: {Name: "CYFR"}}},
    deb: {packageName: "cyfr-desktop",
      depends: ["libgtk-3-0", "libnotify4", "libnss3", "libxss1", "libxtst6", "xdg-utils", "libatspi2.0-0", "libuuid1",
        "libsecret-1-0", "libgbm1", "libasound2t64 | libasound2"],
      afterInstall: path.join(stage, "after-install.tpl"),
      afterRemove: path.join(stage, "after-remove.tpl")},
    mac: {identity: null, category: "public.app-category.productivity"},
    win: {executableName: "CYFR"},
    msi: {oneClick: true, perMachine: false}
  },
  publish: "never"
})
console.log(`built ${artifact.replace("${ext}", {linux: "deb", darwin: "dmg", windows: "msi"}[os])} in ${values.out}`)
