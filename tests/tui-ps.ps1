#!/usr/bin/env pwsh
# tui-ps.ps1 - the Windows twin of tests/tui.sh: exakit.ps1 launches the terminal view (setup/lib/tui.ps1) only for a
# person at a console. Redirected - as scripts, agents and CI run it - a bare `exakit` prints the help, `exakit
# <persona-id>` prints the persona as `exakit persona show` does, and `exakit tui` is refused with what to use
# instead. Runs under Windows PowerShell 5.1 and pwsh; a sandboxed kit home.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-tui-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Contains($label, $needle, $haystack) {
    if ("$haystack".Contains("$needle")) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected to contain <$needle>, got <$haystack>" }
}
$hostExe = (Get-Process -Id $PID).Path
$cli = Join-Path $repo "setup/exakit.ps1"
function Invoke-Kit([string[]]$Words) {
    # Redirected both ways, as a script runs it: no console, so no view.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"      # 5.1: stderr through 2>&1 is not an error while the code is read
    try {
        $out = "" | & $hostExe -NoProfile -ExecutionPolicy Bypass -File $cli @Words 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    return @{ Code = $code; Out = $out }
}

try {
    Write-Host "without a console nothing changes for scripts and agents:"
    $r = Invoke-Kit @()
    Check "bare exakit, redirected: exit 0" 0 $r.Code
    Contains "bare exakit, redirected: the help" "exakit status" $r.Out
    $r = Invoke-Kit @("data-scientist")
    Check "exakit <persona>, redirected: exit 0" 0 $r.Code
    Contains "exakit <persona>, redirected: the persona" "Data Scientist" $r.Out
    $r = Invoke-Kit @("tui")
    Check "exakit tui, redirected: refused" 2 $r.Code
    Contains "exakit tui, redirected: says what to use instead" "exakit status --json" $r.Out
    $r = Invoke-Kit @("tui", "--tab", "nope")
    Check "an unknown tab is refused" 2 $r.Code
    $r = Invoke-Kit @("no-such-word")
    Check "a word that is neither command nor persona is still unknown" 2 $r.Code

    Write-Host "the decision a bare exakit makes:"
    . (Join-Path $repo "setup/lib/tui.ps1")
    $env:EXAKIT_NO_TUI = "1"
    Check "EXAKIT_NO_TUI=1: no view" $false (Test-ExakitTuiWanted)
    Remove-Item Env:EXAKIT_NO_TUI
    $env:CI = "1"
    Check "CI: no view" $false (Test-ExakitTuiWanted)
    Remove-Item Env:CI
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "tui-ps.ps1: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
