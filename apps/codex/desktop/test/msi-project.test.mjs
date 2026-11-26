// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {test} from "node:test"

import {Refused} from "../scripts/check-package.mjs"
import {OPEN_REFUSED, cyfrMsiProject} from "../scripts/msi-project.mjs"

// The files part of electron-builder's WiX project for the app, as its
// MsiTarget writes it on Windows.
const component = (dir, file, packaged) => `<Component Directory="${dir}">
        <File Name="${file}" Source="$(var.appDir)\\${packaged}" ReadOnly="yes" KeyPath="yes"/>
      </Component>`
const project = (...components) => `<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs"><Product>
    <ComponentGroup Id="ProductComponents" Directory="APPLICATIONFOLDER">
      ${components.join("\n      ")}
    </ComponentGroup>
  </Product></Wix>`
const app = component("dXhYk1dSZmXgNv2v.Q9jC0Q", "app.asar", "resources\\app.asar")
const cyfr = component("dXhYk1dSZmXgNv2v.Q9jC0Q", "cyfr.exe", "resources\\cyfr.exe")

// What the project gains at the end of its Product, exactly.
const productEnd = `  <Property Id="MSIRESTARTMANAGERCONTROL" Value="Disable"/>
    <Property Id="CYFROPEN">
      <DirectorySearch Id="cyfrUserData" Path="[AppDataFolder]CYFR" Depth="0">
        <FileSearch Id="cyfrLockfile" Name="lockfile"/>
      </DirectorySearch>
    </Property>
    <Condition Message="${OPEN_REFUSED}">NOT CYFROPEN</Condition>
  </Product>`

test("the bundled cyfr's folder goes on the account's PATH, and leaves it on uninstall", () => {
  const patched = cyfrMsiProject(project(app, cyfr))
  const entries = [...patched.matchAll(/<Environment [^>]*\/>/g)].map((m) => m[0])
  assert.deepEqual(entries, ['<Environment Id="cyfrOnPath" Name="PATH" Value="[dXhYk1dSZmXgNv2v.Q9jC0Q]" Part="last" Action="set" System="no" Permanent="no"/>'])
  // Inside the component that installs cyfr.exe, so it goes with it.
  assert.match(patched, /<File Name="cyfr\.exe"[^>]*\/>\s*<Environment Id="cyfrOnPath"[^>]*\/>\s*<\/Component>/)
})

// Restart Manager off in the package itself, and an open app's lockfile
// (Electron's single-instance lock, in its user-data folder) refusing the
// install, upgrade or removal, saying OPEN_REFUSED; nothing else changes.
test("the package has no Restart Manager and refuses while the app is open", () => {
  const patched = cyfrMsiProject(project(app, cyfr))
  assert.equal(OPEN_REFUSED, "CYFR is open: close it, then try again. If CYFR is not open, open it and close it once, then try again.")
  assert.equal(patched.replace(/\n\s*<Environment [^>]*\/>/, ""), project(app, cyfr).replace("</Product>", productEnd))
})

test("a project without exactly one cyfr.exe component, or one Product, is refused", () => {
  assert.throws(() => cyfrMsiProject(project(app)), Refused, "no cyfr.exe")
  assert.throws(() => cyfrMsiProject(project(app, cyfr, cyfr)), Refused, "two")
  assert.throws(() => cyfrMsiProject(project(component("dA", "cyfr.exe", "cyfr.exe"))), Refused, "cyfr.exe outside resources")
  assert.throws(() => cyfrMsiProject(project(cyfr).replace("</Product>", "")), Refused, "no Product's end")
  assert.throws(() => cyfrMsiProject(project(cyfr).replace("</Product>", "</Product></Product>")), Refused, "two Products' ends")
})
