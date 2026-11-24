// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The MSI puts its bundled cyfr on the person's PATH: electron-builder's
// WiX project, as its msiProjectCreated hook receives it, gains in the
// component that installs resources\cyfr.exe an entry that appends that
// folder to the account's own PATH (HKCU\Environment, as the install is
// the person's alone) and is removed with the component on uninstall.
// Windows Installer announces the change, so a terminal opened after the
// install finds cyfr. A project without exactly one such component, as a
// changed electron-builder could make, is refused, and the build with it.

import {Refused} from "./check-package.mjs"

const COMPONENT = /(<Component Directory="(d[^"]+)">\s*<File Name="cyfr\.exe" Source="\$\(var\.appDir\)[\\/]resources[\\/]cyfr\.exe"[^>]*\/>)/g

/** The WiX project text `wxs` with the bundled cyfr's folder on PATH. */
export function addCyfrToPath(wxs) {
  const found = [...wxs.matchAll(COMPONENT)]
  if (found.length !== 1) throw new Refused(`the MSI project has ${found.length} components installing resources\\cyfr.exe, not one`)
  const [{0: whole, 2: directory}] = found
  return wxs.replace(whole, `${whole}\n        <Environment Id="cyfrOnPath" Name="PATH" Value="[${directory}]" Part="last" Action="set" System="no" Permanent="no"/>`)
}
