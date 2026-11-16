#!/usr/bin/env pwsh
# addon-launcher-ps.ps1 - the marketplace add-on .cmd launchers clean
# themselves up once their target is gone, and are never rewritten in place
# while a cmd.exe runs them.
#
# dash-server.cmd, dbt-exasol.cmd and exasol-json-tables.cmd get the exakit.cmd
# pattern: a launcher whose venv executable is gone says it is a leftover and
# deletes itself. cmd.exe resumes a batch file at the byte offset it had
# reached, so a launcher rewritten under a running copy (dash-server runs as
# long as the server) resumed inside the new content; the writer now stages
# <launcher>.new and a detached helper swaps it in after every copy exits.
#
#   pwsh -NoProfile -File tests/addon-launcher-ps.ps1
# Every write lands in a temp sandbox; the real ~\.local\bin is never touched.

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}

function Import-Functions {
    param([string]$File, [string[]]$Names)
    $err = $null; $tok = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tok, [ref]$err)
    $out = @()
    foreach ($name in $Names) {
        $def = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
        if (-not $def) { throw "$name not found in $File" }
        $out += $def.Extent.Text
    }
    return $out
}

$commonNames = @("Get-ExakitOemEncoding", "Write-ExakitCmdShimFile", "Write-ExakitCmdShimDeferred",
                 "Start-ExakitDetachedPowerShell", "Get-ExakitAddonLauncherGuard",
                 "Get-ExakitLauncherRunningPids", "Write-ExakitAddonLauncher", "Complete-ExakitAddonLauncherUpdate",
                 "Invoke-ExakitFileReplace")
$defs = @(Import-Functions -File (Join-Path $repo "setup/lib/exakit-common.ps1") -Names $commonNames)
$defs += @(Import-Functions -File (Join-Path $repo "setup/lib/dash-server.ps1") -Names @("Get-DashServerLauncherPath", "Write-DashServerLauncher"))
$defs += @(Import-Functions -File (Join-Path $repo "setup/lib/dbt-exasol.ps1") -Names @("Get-DbtExasolLauncherPath", "Write-DbtExasolLauncher"))
$defs += @(Import-Functions -File (Join-Path $repo "setup/lib/json-tables.ps1") -Names @("Get-JsonTablesBin", "Write-JsonTablesLauncher"))
foreach ($d in $defs) { Invoke-Expression $d }

# Stubs for what the writers read; nothing here reaches the machine.
function Write-ExakitLog { param($Level, $Message) }
$script:said = @()
function Ok($m) { $script:said += "OK $m" }
function Info($m) { $script:said += "INFO $m" }
function Warn2($m) { }
function Write-DashServerNotInstalled($m) { Write-Host "  (not installed: $m)"; return $false }
function Write-DbtExasolNotInstalled($m) { Write-Host "  (not installed: $m)"; return $false }
function Write-JsonTablesNotInstalled($m) { Write-Host "  (not installed: $m)"; return $false }
function Get-ExakitManifestValue($k) { return $null }
function Get-JsonTablesShimDir { return (Join-Path $sandbox "jt\shim") }
function Get-JsonTablesEnginePath { return (Join-Path $sandbox "jt\engine.exe") }
$script:running = @()
function Get-ExakitLauncherRunningPids { param([string]$Path) return $script:running }
$script:helperScript = $null
$script:helperOk = $true
function Start-ExakitDetachedPowerShell { param([string]$Script) $script:helperScript = $Script; return $script:helperOk }

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-addonl-" + [guid]::NewGuid())
$script:BinDir = Join-Path $sandbox "bin"
New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
Remove-Item Env:EXAKIT_JSON_TABLES_BIN -ErrorAction SilentlyContinue
$script:DashServerVenv = Join-Path $sandbox "ds\venv"
$script:DashServerHome = Join-Path $sandbox "ds"
$script:DashServerProfile = "starter-kit"
$script:DbtExasolHome = Join-Path $sandbox "dbt"
$dbtExe = Join-Path $sandbox "dbt\venv\Scripts\dbt.exe"
function Get-DbtExasolVenvDbt { return $dbtExe }
function Get-DbtExasolCredentials { return [pscustomobject]@{ PasswordFile = $null } }
$script:JsonTablesVenv = Join-Path $sandbox "jt\venv"

$cases = @(
    [pscustomobject]@{ Id = "dash-server"; Write = "Write-DashServerLauncher"; Path = (Get-DashServerLauncherPath);
                       Target = (Join-Path $script:DashServerVenv "Scripts\dash-server.exe") },
    [pscustomobject]@{ Id = "dbt-exasol"; Write = "Write-DbtExasolLauncher"; Path = (Get-DbtExasolLauncherPath);
                       Target = $dbtExe },
    [pscustomobject]@{ Id = "json-tables"; Write = "Write-JsonTablesLauncher"; Path = (Get-JsonTablesBin);
                       Target = (Join-Path $script:JsonTablesVenv "Scripts\exasol-json-tables.exe") }
)

foreach ($c in $cases) {
    Write-Host ""
    Write-Host "$($c.Id) launcher"
    $script:running = @(); $script:helperScript = $null
    Remove-Item -Force -LiteralPath $c.Path -ErrorAction SilentlyContinue
    Check "$($c.Id): written" "True" ([bool](& $c.Write))
    $text = [System.IO.File]::ReadAllText($c.Path)
    $lines = $text -split "`r`n"
    Check "$($c.Id): starts with @echo off" "@echo off" $lines[0]
    Check "$($c.Id): checks its target first" "if exist `"$($c.Target)`" goto exakit_target_ok" $lines[1]
    Check "$($c.Id): says it is a leftover" ">&2 echo $($c.Id) is no longer installed (its files are gone), so this leftover launcher (`"%~f0`") removes itself now. To add it again: exakit marketplace" $lines[2]
    Check "$($c.Id): self-deletes after leaving the batch context" "(goto) 2>nul & del `"%~f0`" & cmd /c exit 1" $lines[3]
    Check "$($c.Id): then the label" ":exakit_target_ok" $lines[4]
    Check "$($c.Id): the label is defined once" "1" (@($lines | Where-Object { $_ -eq ":exakit_target_ok" }).Count)
    Check "$($c.Id): still runs the target" "True" ($text.Contains("`"$($c.Target)`" %*"))
    Check "$($c.Id): pure ASCII" "True" (-not ($text -match '[^\x00-\x7F]'))
    Check "$($c.Id): no helper when nothing ran it" "True" ($null -eq $script:helperScript)

    # Same content again, even while running: nothing to swap.
    $script:running = @(2147483001)
    [void](& $c.Write)
    Check "$($c.Id): an unchanged launcher starts no helper" "True" ($null -eq $script:helperScript)
    Check "$($c.Id): an unchanged launcher stages no .new" "False" (Test-Path -LiteralPath "$($c.Path).new")

    # Changed content while a cmd.exe runs it: deferred, never in place.
    $old = "@echo off`r`nrem an older launcher`r`n`"$($c.Target)`" %*`r`n"
    [System.IO.File]::WriteAllText($c.Path, $old, [System.Text.Encoding]::ASCII)
    [void](& $c.Write)
    Check "$($c.Id): running: not rewritten in place" "True" ([System.IO.File]::ReadAllText($c.Path) -eq $old)
    Check "$($c.Id): running: .new carries the new launcher" "True" ((Test-Path -LiteralPath "$($c.Path).new") -and ([System.IO.File]::ReadAllText("$($c.Path).new") -eq $text))
    Check "$($c.Id): running: the helper waits for the running copy" "True" ("$script:helperScript".Contains("2147483001"))
    Check "$($c.Id): running: the wait has no time limit" "False" ("$script:helperScript".Contains("-Timeout"))
    Check "$($c.Id): running: the helper looks again before the move" "True" ("$script:helperScript".Contains("Get-CimInstance Win32_Process"))
    & ([scriptblock]::Create($script:helperScript))
    Check "$($c.Id): helper: the new launcher is in place" "True" ([System.IO.File]::ReadAllText($c.Path) -eq $text)
    Check "$($c.Id): helper: .new is gone" "False" (Test-Path -LiteralPath "$($c.Path).new")

    # Staged while running: the writer says so, not "launcher written".
    [System.IO.File]::WriteAllText($c.Path, $old, [System.Text.Encoding]::ASCII)
    $script:said = @()
    [void](& $c.Write)
    Check "$($c.Id): running: says the update is staged" "True" ((@($script:said) -join "`n") -match 'launcher update staged; it applies ')
    Check "$($c.Id): running: does not say launcher written" "False" ((@($script:said) -join "`n") -match 'launcher written')
    # The helper never ran (a logoff ended it): nothing is replaced while a
    # copy still runs, and the next start (no copy running) applies the .new.
    Complete-ExakitAddonLauncherUpdate -Path $c.Path
    Check "$($c.Id): stale .new: not applied while a copy runs" "True" ([System.IO.File]::ReadAllText($c.Path) -eq $old)
    Check "$($c.Id): stale .new: kept while a copy runs" "True" (Test-Path -LiteralPath "$($c.Path).new")
    $script:running = @()
    Complete-ExakitAddonLauncherUpdate -Path $c.Path
    Check "$($c.Id): stale .new: applied at the next start" "True" ([System.IO.File]::ReadAllText($c.Path) -eq $text)
    Check "$($c.Id): stale .new: gone once applied" "False" (Test-Path -LiteralPath "$($c.Path).new")
    # A removed launcher is never brought back by a stale .new.
    Set-Content -Path "$($c.Path).new" -Value "stale"
    $keep = [System.IO.File]::ReadAllText($c.Path)
    Remove-Item -Force -LiteralPath $c.Path
    Complete-ExakitAddonLauncherUpdate -Path $c.Path
    Check "$($c.Id): stale .new: a removed launcher is not recreated" "False" (Test-Path -LiteralPath $c.Path)
    Remove-Item -Force -LiteralPath "$($c.Path).new" -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($c.Path, $keep, [System.Text.Encoding]::ASCII)
    # ReplaceFile's half failure (1176/1177): Replace throws after the launcher
    # is gone, with .new still there. The launcher existed before the Replace,
    # so .new becomes it - at the next start and in the helper - and is never
    # dropped there.
    function Invoke-ExakitFileReplace { param([string]$New, [string]$Target) Remove-Item -Force -LiteralPath $Target; throw "unable to move the replacement file (1176)" }
    [System.IO.File]::WriteAllText($c.Path, $old, [System.Text.Encoding]::ASCII)
    Set-Content -Path "$($c.Path).new" -Value "staged"
    Complete-ExakitAddonLauncherUpdate -Path $c.Path
    Check "$($c.Id): half-failed Replace at start: .new becomes the launcher" "True" ((Test-Path -LiteralPath $c.Path) -and ([System.IO.File]::ReadAllText($c.Path).Trim() -eq "staged"))
    Check "$($c.Id): half-failed Replace at start: no .new is left" "False" (Test-Path -LiteralPath "$($c.Path).new")
    [System.IO.File]::WriteAllText($c.Path, $old, [System.Text.Encoding]::ASCII)
    $script:running = @(2147483001); $script:helperScript = $null
    [void](& $c.Write)
    & ([scriptblock]::Create($script:helperScript))
    Check "$($c.Id): half-failed Replace in the helper: .new becomes the launcher" "True" ((Test-Path -LiteralPath $c.Path) -and ([System.IO.File]::ReadAllText($c.Path) -eq $text))
    Check "$($c.Id): half-failed Replace in the helper: no .new is left" "False" (Test-Path -LiteralPath "$($c.Path).new")
    foreach ($d in (Import-Functions -File (Join-Path $repo "setup/lib/exakit-common.ps1") -Names @("Invoke-ExakitFileReplace"))) { Invoke-Expression $d }
    [System.IO.File]::WriteAllText($c.Path, $keep, [System.Text.Encoding]::ASCII)
    $script:running = @(2147483001)

    # No helper could start: the working old launcher is kept, no .new left.
    [System.IO.File]::WriteAllText($c.Path, $old, [System.Text.Encoding]::ASCII)
    $script:helperOk = $false
    Check "$($c.Id): no helper: still reported written" "True" ([bool](& $c.Write))
    Check "$($c.Id): no helper: the old launcher is kept" "True" ([System.IO.File]::ReadAllText($c.Path) -eq $old)
    Check "$($c.Id): no helper: no .new is left" "False" (Test-Path -LiteralPath "$($c.Path).new")
    $script:helperOk = $true

    # Not running: in place, and a leftover .new is dropped.
    $script:running = @(); $script:helperScript = $null
    [System.IO.File]::WriteAllText($c.Path, $old, [System.Text.Encoding]::ASCII)
    Set-Content -Path "$($c.Path).new" -Value "stale"
    [void](& $c.Write)
    Check "$($c.Id): idle: written in place" "True" ([System.IO.File]::ReadAllText($c.Path) -eq $text)
    Check "$($c.Id): idle: a leftover .new is removed" "False" (Test-Path -LiteralPath "$($c.Path).new")
    Check "$($c.Id): idle: no helper" "True" ($null -eq $script:helperScript)

    # Windows only: the real cmd.exe runs the leftover and it removes itself.
    $cmdExe = Get-Command cmd.exe -ErrorAction SilentlyContinue
    if ($cmdExe) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $out = & cmd.exe /d /c "`"$($c.Path)`" --version" 2>&1 | Out-String -Width 4096
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        Check "$($c.Id) (cmd.exe): prints the leftover message" "True" ($out -match "$([regex]::Escape($c.Id)) is no longer installed \(its files are gone\), so this leftover launcher")
        Check "$($c.Id) (cmd.exe): exits non-zero" "True" ($code -ne 0)
        Check "$($c.Id) (cmd.exe): deleted itself" "False" (Test-Path -LiteralPath $c.Path)
    } else {
        Write-Host "  skip $($c.Id) (cmd.exe): not on Windows"
    }
}

# --- Windows only: a real cmd.exe runs the launcher while it is rewritten ---
# The real running-copy scan, the real detached helper, sandbox paths only.
# While the copy runs the file must not change; once it exits the helper swaps
# the new content in.
Write-Host ""
Write-Host "live rewrite under cmd.exe (Windows only)"
if (Get-Command cmd.exe -ErrorAction SilentlyContinue) {
    foreach ($d in (Import-Functions -File (Join-Path $repo "setup/lib/exakit-common.ps1") -Names @("Get-ExakitLauncherRunningPids", "Start-ExakitDetachedPowerShell"))) { Invoke-Expression $d }
    $liveDir = Join-Path $sandbox "live"
    New-Item -ItemType Directory -Force -Path $liveDir | Out-Null
    $live = Join-Path $liveDir "live-addon.cmd"
    $liveOld = "@echo off`r`nrem old launcher`r`nping -n 7 127.0.0.1 >nul`r`necho old-done`r`n"
    $liveNew = "@echo off`r`nrem new launcher, different length and bytes`r`necho new-content`r`n"
    [System.IO.File]::WriteAllText($live, $liveOld, [System.Text.Encoding]::ASCII)
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/d", "/c", "`"$live`"") -PassThru -WindowStyle Hidden
    $seen = $false
    for ($i = 0; $i -lt 20 -and -not $seen; $i++) {
        if (@(Get-ExakitLauncherRunningPids -Path $live).Count -gt 0) { $seen = $true } else { Start-Sleep -Milliseconds 250 }
    }
    Check "live: the running copy is found by its path" "True" $seen
    Write-ExakitAddonLauncher -Path $live -Content $liveNew
    $changed = $false
    while (-not $proc.HasExited) {
        if ([System.IO.File]::ReadAllText($live) -ne $liveOld) { $changed = $true }
        Start-Sleep -Milliseconds 200
    }
    Check "live: nothing was rewritten while it ran" "False" $changed
    Check "live: the running copy finished its own (old) script" "0" $proc.ExitCode
    for ($i = 0; $i -lt 60 -and (Test-Path -LiteralPath "$live.new"); $i++) { Start-Sleep -Milliseconds 500 }
    Check "live: after it exited the new content is in place" "True" ([System.IO.File]::ReadAllText($live) -eq $liveNew)
    Check "live: .new is gone" "False" (Test-Path -LiteralPath "$live.new")
} else {
    Write-Host "  skip live rewrite: not on Windows"
}

# --- static: every add-on launcher writer goes through the deferred writer --
Write-Host ""
Write-Host "static"
foreach ($f in @("dash-server.ps1", "dbt-exasol.ps1", "json-tables.ps1")) {
    $src = Get-Content -Raw (Join-Path $repo "setup/lib/$f")
    Check "$($f): writes its launcher through Write-ExakitAddonLauncher" "1" ([regex]::Matches($src, 'Write-ExakitAddonLauncher -Path')).Count
    Check "$($f): no direct WriteAllText of the launcher" "0" ([regex]::Matches($src, 'WriteAllText\(\(Get-\w+LauncherPath\)|WriteAllText\(\$launcher')).Count
    Check "$($f): carries the self-cleaning guard" "1" ([regex]::Matches($src, 'Get-ExakitAddonLauncherGuard -Id')).Count
}

# dash-server applies a staged launcher right before each start, so an update
# that stopped and restarts it runs the new launcher (the update's own restart,
# and the next `exakit start`).
foreach ($fn in @("Start-DashServer", "Test-DashServer")) {
    $body = "" + (Import-Functions -File (Join-Path $repo "setup/lib/dash-server.ps1") -Names @($fn))
    $applyAt = $body.IndexOf("Complete-ExakitAddonLauncherUpdate -Path (Get-DashServerLauncherPath)")
    $startAt = $body.IndexOf("Start-Process -FilePath (Get-DashServerLauncherPath)")
    Check "$($fn): applies a staged launcher before it starts one" "True" (($applyAt -ge 0) -and ($startAt -gt $applyAt))
}

Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "PASS=$($script:PASS) FAIL=$($script:FAIL)"
if ($script:FAIL -ne 0) { exit 1 }
