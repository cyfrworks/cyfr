// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The MSI as electron-builder's WiX project makes it, as its
// msiProjectCreated hook receives it, with three things of CYFR's:
//
// - Its bundled cyfr on the person's PATH: the component that installs
//   resources\cyfr.exe gains an entry that appends that folder to the
//   account's own PATH (HKCU\Environment, as the install is the person's
//   alone), removed with the component on uninstall. Windows Installer
//   announces the change, so a terminal opened after the install finds
//   cyfr.
// - No Restart Manager (MSIRESTARTMANAGERCONTROL=Disable, in the package,
//   so the removal of the installed package inside an upgrade has it too:
//   on msiexec's command line it does not reach that one). A silent
//   install or removal would otherwise end every program it finds holding
//   one of the app's files, and every other program in that program's
//   console: a reader that holds CYFR.exe a few seconds after it ran
//   takes its console with it, a person's terminal or a runner.
// - No install, upgrade or removal while the app is open: it is refused
//   before anything changes, saying OPEN_REFUSED, and leaves nothing for a
//   restart. The app is open while its single-instance lock is held
//   (src/app.js), which keeps the file lockfile in its user-data folder
//   open and deletes it when it closes, however the app ends; the
//   package's search finds that file, and its launch condition, which
//   Windows Installer reads on install, upgrade and removal alike, refuses.
//   cyfr update closes the app before it installs (cmd/app_update.go); the
//   bundled cyfr running it holds no such lock.
//
// A project without exactly one component installing resources\cyfr.exe,
// or one Product, as a changed electron-builder could make, is refused,
// and the build with it.

import {Refused} from "./check-package.mjs"

const COMPONENT = /(<Component Directory="(d[^"]+)">\s*<File Name="cyfr\.exe" Source="\$\(var\.appDir\)[\\/]resources[\\/]cyfr\.exe"[^>]*\/>)/g
const PRODUCT_END = /<\/Product>/g

/** What Windows Installer says when the app is open. */
export const OPEN_REFUSED = "CYFR is open: close it, then try again."

/** The WiX project text `wxs` as CYFR ships it (above). */
export function cyfrMsiProject(wxs) {
  const found = [...wxs.matchAll(COMPONENT)]
  if (found.length !== 1) throw new Refused(`the MSI project has ${found.length} components installing resources\\cyfr.exe, not one`)
  const ends = [...wxs.matchAll(PRODUCT_END)].length
  if (ends !== 1) throw new Refused(`the MSI project has ${ends} Products, not one`)
  const [{0: whole, 2: directory}] = found
  return wxs
    .replace(whole, `${whole}\n        <Environment Id="cyfrOnPath" Name="PATH" Value="[${directory}]" Part="last" Action="set" System="no" Permanent="no"/>`)
    .replace(PRODUCT_END, `  <Property Id="MSIRESTARTMANAGERCONTROL" Value="Disable"/>
    <Property Id="CYFROPEN">
      <DirectorySearch Id="cyfrUserData" Path="[AppDataFolder]CYFR" Depth="0">
        <FileSearch Id="cyfrLockfile" Name="lockfile"/>
      </DirectorySearch>
    </Property>
    <Condition Message="${OPEN_REFUSED}">NOT CYFROPEN</Condition>
  </Product>`)
}
