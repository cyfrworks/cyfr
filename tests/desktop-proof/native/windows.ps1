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
#   remove   the MSI removes the app at APP, and its cyfr is off PATH. A
#            program of this script's making holds APP open as the
#            runner's own reader holds it after the app ran (read, sharing
#            delete), in a console of its own with a second program beside
#            it, through the removal: the installer uses no Restart Manager
#            (apps/codex/desktop/scripts/msi-project.mjs), so both still
#            run after it. A console of its own, so a package that ended
#            it would end no other program
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

# The holder: started in a console of its own (Start-Process without
# -NoNewWindow), it opens FILE, starts the second program in its console,
# and writes its id, the second's and the ids its console lists to READY.
$holder = @'
param($File, $Ready)
$held = [IO.File]::Open($File, "Open", "Read", "ReadWrite, Delete")
$beside = Start-Process pwsh -ArgumentList "-NoProfile", "-Command", "Start-Sleep 900" -NoNewWindow -PassThru
Add-Type -Namespace Proof -Name Console -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] ids, uint count);'
$ids = New-Object uint32[] 64
$n = [Proof.Console]::GetConsoleProcessList($ids, 64)
"$PID $($beside.Id) $(($ids[0..($n - 1)] | Sort-Object) -join ',')" | Set-Content "$Ready.part"
Move-Item "$Ready.part" $Ready
Start-Sleep 900
'@
$held = @()
if ($Mode -eq "remove") {
  if (-not $env:APP) { throw "APP names no installed app to remove" }
  $script = Join-Path $env:RUNNER_TEMP "cyfr-holder.ps1"
  $ready = Join-Path $env:RUNNER_TEMP "cyfr-holder.ready"
  Set-Content $script $holder
  Remove-Item $ready -ErrorAction SilentlyContinue
  $started = Start-Process pwsh -ArgumentList "-NoProfile", "-File", "`"$script`"", "`"$env:APP`"", "`"$ready`"" -PassThru
  $until = (Get-Date).AddSeconds(60)
  while (-not (Test-Path $ready) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 200 } # sleep-ok: the gap between two looks for the holder's ready file, bounded by $until
  if (-not (Test-Path $ready)) { Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue; throw "the holder did not hold $env:APP within 60 s" }
  $holderId, $besideId, $console = (Get-Content $ready).Split(" ")
  $held = @([int]$holderId, [int]$besideId)
  $want = ($held | Sort-Object) -join ","
  if ($holderId -ne $started.Id -or $console -ne $want) {
    Stop-Process -Id $held -Force -ErrorAction SilentlyContinue
    throw "the holder ($($started.Id)) wrote '$(Get-Content $ready)': its console is not its own with one program beside it"
  }
}
try {
  $run = Start-Process msiexec.exe -ArgumentList $flag, "`"$msi`"", "/qn", "/norestart", "/l*v", "`"$log`"" -Wait -PassThru
  if ($run.ExitCode -ne 0) { Get-Content $log -Tail 50; throw "msiexec $flag exited $($run.ExitCode)" }
  if ($held) {
    $alive = @(Get-Process -Id $held -ErrorAction SilentlyContinue)
    if ($alive.Count -ne 2) {
      Select-String -Path $log -Pattern "RESTART MANAGER" | ForEach-Object { $_.Line }
      throw "the removal ended $(2 - $alive.Count) of the holder's console's two programs ($($held -join ', '))"
    }
    if (Test-Path $env:APP) { throw "the removal left $env:APP" }
    "the holder's console's two programs ($($held -join ', ')) ran through the removal"
  }
} finally {
  if ($held) { Stop-Process -Id $held -Force -ErrorAction SilentlyContinue }
}

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
  pwsh -NoProfile -File $path removed (Split-Path $env:APP)
  if ($LASTEXITCODE -ne 0) { throw "the MSI's cyfr stayed on PATH" }
}
