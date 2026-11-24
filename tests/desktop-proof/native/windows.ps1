# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The CYFR app's MSI, installed and removed as a person installs and
# removes it, each followed by the check of its cyfr on the person's PATH
# (windows-path.ps1). Codex CI runs it on the package a change builds and
# Release on the package a tag publishes, each on a runner of the package's
# architecture; the smoke (smoke.sh) runs between the two.
#
#   install  the MSI installs for this account alone, under its local
#            programs folder, holding exactly one CYFR.exe there, the name
#            matched with its case (Windows matches a filter without it, and
#            the bundled resources\cyfr.exe is another program), and its
#            cyfr is on PATH. The app's path is written as APP to
#            $GITHUB_ENV, and its bundled cyfr's as CYFR, with forward
#            slashes for Git Bash, and both are printed
#   remove   the MSI removes the app at APP, and its cyfr is off PATH
#
# Usage: pwsh tests/desktop-proof/native/windows.ps1 install|remove MSI
param(
  [Parameter(Mandatory)][ValidateSet("install", "remove")][string]$Mode,
  [Parameter(Mandatory)][string]$Msi
)
$ErrorActionPreference = "Stop"

$msi = (Resolve-Path $Msi).Path
$log = Join-Path $env:RUNNER_TEMP "cyfr-msi-$Mode.log"
$flag = if ($Mode -eq "install") { "/i" } else { "/x" }
$run = Start-Process msiexec.exe -ArgumentList $flag, "`"$msi`"", "/qn", "/norestart", "/l*v", "`"$log`"" -Wait -PassThru
if ($run.ExitCode -ne 0) { Get-Content $log -Tail 50; throw "msiexec $flag exited $($run.ExitCode)" }

$path = Join-Path $PSScriptRoot "windows-path.ps1"
if ($Mode -eq "install") {
  $found = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA "Programs") -Recurse -Filter CYFR.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ceq "CYFR.exe" })
  if ($found.Count -ne 1) { throw "the MSI installed $($found.Count) CYFR.exe under $env:LOCALAPPDATA\Programs" }
  $app = $found[0].FullName
  $cyfr = (Join-Path $found[0].DirectoryName "resources\cyfr.exe").Replace("\", "/")
  if ($env:GITHUB_ENV) { "APP=$app", "CYFR=$cyfr" >> $env:GITHUB_ENV }
  $app, $cyfr
  pwsh -NoProfile -File $path installed $found[0].DirectoryName
  if ($LASTEXITCODE -ne 0) { throw "the MSI's cyfr is not on PATH" }
} else {
  if (-not $env:APP) { throw "APP names no installed app to remove" }
  pwsh -NoProfile -File $path removed (Split-Path $env:APP)
  if ($LASTEXITCODE -ne 0) { throw "the MSI's cyfr stayed on PATH" }
}
