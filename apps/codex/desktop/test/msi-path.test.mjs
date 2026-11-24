// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {test} from "node:test"

import {Refused} from "../scripts/check-package.mjs"
import {addCyfrToPath} from "../scripts/msi-path.mjs"

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

test("the bundled cyfr's folder goes on the account's PATH, and leaves it on uninstall", () => {
  const patched = addCyfrToPath(project(app, cyfr))
  const entries = [...patched.matchAll(/<Environment [^>]*\/>/g)].map((m) => m[0])
  assert.deepEqual(entries, ['<Environment Id="cyfrOnPath" Name="PATH" Value="[dXhYk1dSZmXgNv2v.Q9jC0Q]" Part="last" Action="set" System="no" Permanent="no"/>'])
  // Inside the component that installs cyfr.exe, so it goes with it.
  assert.match(patched, /<File Name="cyfr\.exe"[^>]*\/>\s*<Environment Id="cyfrOnPath"[^>]*\/>\s*<\/Component>/)
  assert.equal(patched.replace(/\n\s*<Environment [^>]*\/>/, ""), project(app, cyfr))
})

test("a project without exactly one cyfr.exe component is refused", () => {
  assert.throws(() => addCyfrToPath(project(app)), Refused, "no cyfr.exe")
  assert.throws(() => addCyfrToPath(project(app, cyfr, cyfr)), Refused, "two")
  assert.throws(() => addCyfrToPath(project(component("dA", "cyfr.exe", "cyfr.exe"))), Refused, "cyfr.exe outside resources")
})
