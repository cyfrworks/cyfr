# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The MSI's cyfr on the person's PATH, as a terminal opened after the
# install or the uninstall finds it: PATH read again from the registry,
# the system's and this account's, as a new terminal reads it, not the
# PATH this step was started with.
#
#   installed  this account's PATH holds the installed app's resources
#              folder once, and a terminal opened now resolves cyfr to the
#              bundled resources\cyfr.exe, which answers --version
#   removed    after the MSI is removed this account's PATH holds no entry
#              for that folder, and a terminal opened now finds no cyfr
#
# Usage: pwsh tests/desktop-proof/native/windows-path.ps1 installed|removed APP_DIR
# APP_DIR is the folder the MSI installed CYFR.exe in.
param(
  [Parameter(Mandatory)][ValidateSet("installed", "removed")][string]$Mode,
  [Parameter(Mandatory)][string]$AppDir
)
$ErrorActionPreference = "Stop"

$resources = [IO.Path]::GetFullPath((Join-Path $AppDir "resources")).TrimEnd("\")
$user = [Environment]::GetEnvironmentVariable("Path", "User")
# An entry is the folder's when it says it, or resolves to it; one that
# cannot be resolved is compared as it is written, never taken as another's.
$same = { param($entry)
  if ($entry.TrimEnd("\") -ieq $resources) { return $true }
  try { [IO.Path]::GetFullPath($entry).TrimEnd("\") -ieq $resources } catch { $false } }
$entries = @(($user ?? "") -split ";" | Where-Object { $_ -and (& $same $_) })
# A new terminal's PATH: the system's, then this account's.
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + $user
# Only "no such command" reads as absent; any other failure of the lookup
# is a failure.
$found = Get-Command cyfr -CommandType Application -ErrorAction SilentlyContinue -ErrorVariable lookup | Select-Object -First 1
$failed = @($lookup | Where-Object { $_.FullyQualifiedErrorId -notlike "CommandNotFoundException*" })
if ($failed.Count) { throw "looking cyfr up failed: $($failed[0])" }

if ($Mode -eq "installed") {
  if ($entries.Count -ne 1) { throw "this account's PATH holds $($entries.Count) entries for $resources, not one: $user" }
  if (-not $found) { throw "a new terminal finds no cyfr" }
  $want = Join-Path $resources "cyfr.exe"
  if ($found.Source -ine $want) { throw "a new terminal finds cyfr at $($found.Source), not $want" }
  $version = & cyfr --version
  if ($LASTEXITCODE -ne 0 -or "$version" -notmatch "^cyfr version ") { throw "cyfr --version answered '$version' (exit $LASTEXITCODE)" }
  "PASS installed: a new terminal runs $want ($version)"
} else {
  if ($entries.Count -ne 0) { throw "this account's PATH still holds $resources after the uninstall: $user" }
  if ($found) { throw "a new terminal still finds cyfr at $($found.Source)" }
  "PASS removed: this account's PATH holds nothing of CYFR and a new terminal finds no cyfr"
}
