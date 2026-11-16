#!/usr/bin/env pwsh
# shim-update-ps.ps1 - exakit.cmd is never rewritten in place under a running
# exakit.cmd.
#
# cmd.exe re-opens a batch file after each command and resumes at the byte
# offset it had reached. `exakit update` (and `exakit repair-runtime`, which
# re-runs setup-windows.ps1) run under exakit.cmd; rewriting it in place made
# cmd.exe resume inside the NEW shim's self-cleaning line, which deleted the
# shim it had just been given. Set-ExakitCmdShim now stages exakit.cmd.new and
# a detached helper swaps it in after the launcher chain exits.
#
#   pwsh -NoProfile -File tests/shim-update-ps.ps1
# Every write lands in a temp sandbox; the real ~\.local\bin is never touched.

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}

$commonPath = Join-Path $repo "setup/lib/exakit-common.ps1"
$cErr = $null; $cTok = $null
$cAst = [System.Management.Automation.Language.Parser]::ParseFile($commonPath, [ref]$cTok, [ref]$cErr)
$names = @("Get-ExakitCmdShimContent", "Get-ExakitOemEncoding", "Set-ExakitCmdShim",
           "Test-ExakitCmdShimCurrent", "Write-ExakitCmdShimFile", "Get-ExakitShimLauncherPids",
           "Write-ExakitCmdShimDeferred", "Start-ExakitDetachedPowerShell")
$defs = @{}
foreach ($name in $names) {
    $def = $cAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
    if (-not $def) { throw "$name not found in exakit-common.ps1" }
    $defs[$name] = $def.Extent.Text
}
function Import-ShimFunctions { foreach ($n in $names) { Invoke-Expression $defs[$n] } }
. Import-ShimFunctions
function Write-ExakitLog { param($Level, $Message) }

# --- static: the only writer defers under the shim -------------------------
Write-Host "static"
$setBody = $defs["Set-ExakitCmdShim"]
Check "Set-ExakitCmdShim asks whether it runs under the shim" "True" ($setBody.Contains("Get-ExakitShimLauncherPids"))
Check "Set-ExakitCmdShim defers under the shim" "True" ($setBody.Contains("Write-ExakitCmdShimDeferred"))
Check "the deferred writer stages exakit.cmd.new" "True" ($defs["Write-ExakitCmdShimDeferred"].Contains('$newPath = "$ShimPath.new"'))
Check "the deferred writer drops .new when no helper starts" "True" ($defs["Write-ExakitCmdShimDeferred"] -match 'Remove-Item -Force -LiteralPath \$newPath')
$commonText = Get-Content -Raw $commonPath
$writes = ([regex]::Matches($commonText, 'WriteAllText\(\$shimPath')).Count
Check "nothing else writes exakit.cmd directly" "0" $writes

# --- sandbox ---------------------------------------------------------------
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-shimupd-" + [guid]::NewGuid())
$script:BinDir = Join-Path $sandbox "bin"
New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
$target = Join-Path $sandbox "kit\setup\exakit.ps1"
New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
Set-Content -Path $target -Value "exit 0"
$shimPath = Join-Path $script:BinDir "exakit.cmd"
$newPath = "$shimPath.new"
$oldShim = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$target`" %*`r`n"
function Write-OldShim { [System.IO.File]::WriteAllText($shimPath, $oldShim, [System.Text.Encoding]::ASCII) }
$newShim = Get-ExakitCmdShimContent -PsTarget $target

# --- pure logic: what cmd.exe would read on resume -------------------------
Write-Host ""
Write-Host "resume offset"
$tail = $newShim.Substring([Math]::Min($oldShim.Length, $newShim.Length))
Check "the hazard is real: the new shim's bytes past the old offset delete it" "True" ($tail.Contains("del "))

# Under the shim, helper started.
Write-Host ""
Write-Host "under exakit.cmd"
$script:helperScript = $null
$script:helperOk = $true
function Get-ExakitShimLauncherPids { param([string]$ShimPath) return @(2147483000) }
function Start-ExakitDetachedPowerShell { param([string]$Script) $script:helperScript = $Script; return $script:helperOk }
Write-OldShim
[void](Set-ExakitCmdShim -PsTarget $target)
$onDisk = [System.IO.File]::ReadAllText($shimPath)
Check "exakit.cmd is not rewritten in place" "True" ($onDisk -eq $oldShim)
$resume = ""
if ($onDisk.Length -gt $oldShim.Length) { $resume = $onDisk.Substring($oldShim.Length) }
Check "what cmd.exe resumes into holds no del" "False" ($resume.Contains("del"))
Check "exakit.cmd.new carries the new shim" "True" ((Test-Path -LiteralPath $newPath) -and ([System.IO.File]::ReadAllText($newPath) -eq $newShim))
Check "the helper waits for the launcher pid" "True" ("$script:helperScript".Contains("2147483000"))
# Run the helper's script here: it must move .new over exakit.cmd.
& ([scriptblock]::Create($script:helperScript))
Check "helper: exakit.cmd now has the new content" "True" ([System.IO.File]::ReadAllText($shimPath) -eq $newShim)
Check "helper: exakit.cmd.new is gone" "False" (Test-Path -LiteralPath $newPath)

# Helper could not start: old shim kept, no .new left.
Write-OldShim
$script:helperOk = $false
[void](Set-ExakitCmdShim -PsTarget $target)
Check "no helper: the old shim is kept" "True" ([System.IO.File]::ReadAllText($shimPath) -eq $oldShim)
Check "no helper: no exakit.cmd.new is left" "False" (Test-Path -LiteralPath $newPath)
$script:helperOk = $true

# A current shim is left alone even under the shim.
$script:helperScript = $null
[System.IO.File]::WriteAllText($shimPath, $newShim, [System.Text.Encoding]::ASCII)
[void](Set-ExakitCmdShim -PsTarget $target)
Check "a current shim starts no helper" "True" ($null -eq $script:helperScript)

# Outside the shim (install.ps1): in place, and a leftover .new is dropped.
Write-Host ""
Write-Host "outside exakit.cmd"
function Get-ExakitShimLauncherPids { param([string]$ShimPath) return @() }
Write-OldShim
Set-Content -Path $newPath -Value "stale"
[void](Set-ExakitCmdShim -PsTarget $target)
Check "install: written in place" "True" ([System.IO.File]::ReadAllText($shimPath) -eq $newShim)
Check "install: a leftover exakit.cmd.new is removed" "False" (Test-Path -LiteralPath $newPath)

# --- behavioral (Windows only): a real update from an old-format shim -------
Write-Host ""
Write-Host "cmd.exe (Windows only)"
$cmdExe = Get-Command cmd.exe -ErrorAction SilentlyContinue
if ($cmdExe) {
    . Import-ShimFunctions
    $fnFile = Join-Path $sandbox "shimfns.ps1"
    ($names | ForEach-Object { $defs[$_] }) -join "`r`n" | Set-Content -Path $fnFile
    $binQ = $script:BinDir -replace "'", "''"
    $fnQ = $fnFile -replace "'", "''"
    $tQ = $target -replace "'", "''"
    # The kit's exakit.ps1 stand-in: loads the real shim functions and runs the
    # same call the update path makes, then exits - as `exakit update` does.
    Set-Content -Path $target -Value @"
`$script:BinDir = '$binQ'
function Write-ExakitLog { param(`$Level, `$Message) }
. '$fnQ'
[void](Set-ExakitCmdShim -PsTarget '$tQ')
exit 0
"@
    $newShim = Get-ExakitCmdShimContent -PsTarget $target
    Write-OldShim
    Remove-Item -Force -LiteralPath $newPath -ErrorAction SilentlyContinue
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = & cmd.exe /d /c "`"$shimPath`"" 2>&1 | Out-String -Width 4096
    $ErrorActionPreference = $prevEap
    for ($i = 0; $i -lt 40 -and (Test-Path -LiteralPath $newPath); $i++) { Start-Sleep -Milliseconds 500 }
    Check "cmd.exe: no 'is not recognized' fragment ran" "False" ($out -match 'is not recognized')
    Check "cmd.exe: no leftover message" "False" ($out -match 'leftover launcher')
    Check "cmd.exe: exakit.cmd still exists" "True" (Test-Path -LiteralPath $shimPath)
    Check "cmd.exe: exakit.cmd has the new content" "True" ((Test-Path -LiteralPath $shimPath) -and ([System.IO.File]::ReadAllText($shimPath) -eq $newShim))
    Check "cmd.exe: exakit.cmd.new is gone" "False" (Test-Path -LiteralPath $newPath)
} else {
    Write-Host "  skip cmd.exe: not on Windows"
}

Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "PASS=$($script:PASS) FAIL=$($script:FAIL)"
if ($script:FAIL -ne 0) { exit 1 }
