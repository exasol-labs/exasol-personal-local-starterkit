#!/usr/bin/env pwsh
# install-no-database-ps.ps1 - the Windows twin of install-no-database.sh: an
# install that ends with no usable database must not exit 0.
#
# What it pins, by running setup-windows.ps1's own code (the database step's
# if/else and everything from the connection panel to the end of the try
# block), not a copy of it, in a child PowerShell so its exit code is real:
#   - the first-run arm: a deploy that fails softly ends with exit 7, and the
#     ready line is not printed, and the summary never says "ready"
#   - the resume arm: a deployed database that does not start ends with 7
#   - a soft failure beside a working database (the MCP step) still ends 0
#   - a clean run ends 0 and prints the ready line
#
# Runs under Windows PowerShell 5.1 and pwsh, against a scratch EXAKIT_HOME with
# the steps' work stubbed: no launcher, no database, no installed kit.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-nodb-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$script:PASS = 0
$script:FAIL = 0
function Contains($label, $needle, $haystack) {
    if ("$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> not in <$haystack>" }
}
function Lacks($label, $needle, $haystack) {
    if (-not "$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> found in <$haystack>" }
}

$setup = Get-Content -Raw -Path (Join-Path $repo "setup/setup-windows.ps1")
$lines = $setup -split "`r?`n"
function Get-Slice([string]$from, [string]$to) {
    $out = @(); $on = $false
    foreach ($l in $lines) {
        if (-not $on -and $l.StartsWith($from)) { $on = $true }
        if ($on -and $l.StartsWith($to)) { break }
        if ($on) { $out += $l }
    }
    return ($out -join "`n")
}
$arm = Get-Slice '    if (Begin-ExakitStep "runtime"' '    # exapump publishes Windows binaries'
$close = Get-Slice '    Show-ExakitConnectionSummary' '} catch [ExakitFailException] {'

try {
    if (-not $arm -or -not $close) { throw "could not find the database step or the closing lines in setup-windows.ps1" }
    $harness = Join-Path $work "run.ps1"
    $common = Join-Path $repo "setup/lib/exakit-common.ps1"
    $body = @"
`$ErrorActionPreference = "Stop"
. '$($common -replace "'", "''")'
`$script:LogFile = `$null
# The steps' work.
function Begin-ExakitStep { param(`$a, `$b) return (`$env:STUB_BEGIN -ne "1") }
function Set-ExakitStepDone { param(`$a) Write-Host "MARK `$a" }
function Install-PersonalDeployment { if (`$env:STUB_DEPLOY_FAILS -eq "1") { `$script:PersonalNoDatabase = `$true } }
function Get-ExakitInstallCommand { return "irm https://www.exasol.com/install/starter-kit.ps1 | iex" }
function Get-ExakitFailureReason { return "the launcher refused the deploy" }
function Clear-PersonalStaleRecord { }
function Test-PersonalDeploymentExists { return `$true }
function Test-PersonalDeploymentRunning { return `$false }
function Start-Personal { if (`$env:STUB_START_FAILS -eq "1") { throw "the start failed" } }
function Wait-PersonalReadyOrDeploy { return `$true }
# The closing lines' neighbours, which have nothing to do with the exit.
function Show-ExakitConnectionSummary { Write-Host "PANEL" }
function Write-ExakitWhatsNewBox { param(`$KitRoot) }
function Write-ExakitReadyLine { if (`$script:ExakitSoftFailed.Count -eq 0) { Write-Host "READY LINE" } }
function Invoke-ExakitClosingOffer { }
function Clear-ExakitFinishedSoftFailures { }
function Remove-ExakitManifestValue { param(`$a) }
function Exit-ExakitInstallLock { }
function Write-ExakitRule { }
function Write-ExakitHeading { param(`$a) Write-Host "CLOSING" }
`$coreRerun = `$false
`$KitRoot = '$($work -replace "'", "''")'
try {
$arm
    if (`$env:STUB_MCP_FAILS -eq "1") { Register-ExakitSoftFailure -Component "mcp" -Repair "exakit mcp-setup" -Reason "the MCP server did not answer" -Label "AI client (MCP) setup" }
$close
    Write-Host "FELL THROUGH"
} finally {
    Write-Host "FINALLY"
}
"@
    Set-Content -Path $harness -Value $body -Encoding UTF8
    $exe = (Get-Process -Id $PID).Path

    function Invoke-Case([hashtable]$envs) {
        $home2 = Join-Path $work ("home-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $home2 | Out-Null
        $saved = @{}
        $all = @{ EXAKIT_HOME = $home2; STUB_BEGIN = ""; STUB_DEPLOY_FAILS = ""; STUB_START_FAILS = ""; STUB_MCP_FAILS = "" }
        foreach ($k in $envs.Keys) { $all[$k] = $envs[$k] }
        foreach ($k in $all.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $all[$k]) }
        # Continue for the child: Windows PowerShell 5.1 turns the first line a
        # native command writes to stderr under 2>&1 into a terminating
        # NativeCommandError when the preference is Stop (pwsh does not), and
        # the install writes its warnings there.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $out = (@(& $exe -NoProfile -ExecutionPolicy Bypass -File $harness 2>&1) | ForEach-Object { "$_" }) -join "`n"
            $rc = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
        return ($out + "`nRC=$rc")
    }

    Write-Host "setup-windows.ps1:"
    $out = Invoke-Case @{ STUB_DEPLOY_FAILS = "1" }
    Contains "a failed deploy is recorded as a soft failure" "The database was not installed" $out
    Contains "  the install exits 7 (no usable database)" "RC=7" $out
    Lacks    "  and the ready line is not printed" "READY LINE" $out
    Lacks    "  and the closing summary does not say ready" "ready" $out
    Contains "  it says no database is usable" "No database is usable, so the steps that need one were skipped." $out
    Contains "  the closing lines still ran" "CLOSING" $out
    Contains "  and the finally block too" "FINALLY" $out

    $out = Invoke-Case @{ STUB_BEGIN = "1"; STUB_START_FAILS = "1" }
    Contains "a deployed database that does not start" "Database is deployed but not running" $out
    Contains "  exits 7 too" "RC=7" $out

    $out = Invoke-Case @{ STUB_MCP_FAILS = "1" }
    Contains "a soft failure beside a working database" "AI client (MCP) setup" $out
    Contains "  still exits 0, as before" "RC=0" $out

    $out = Invoke-Case @{}
    Contains "a clean run exits 0" "RC=0" $out
    Contains "  with the ready line" "READY LINE" $out
} finally {
    Remove-Item -Recurse -Force -Path $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
exit 0
