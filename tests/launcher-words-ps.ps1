#!/usr/bin/env pwsh
# launcher-words-ps.ps1 - the Windows twin of launcher-words.sh: the
# launcher's own text, relayed in the kit's failure box (Show-PersonalLauncherTail,
# after a failed deploy or start), never tells a kit user to run the launcher's
# `destroy`. Its `start` is the kit's `exakit start`, a sentence that says to
# destroy is left out, and the lines the kit keeps (the log) are unchanged.
#
# Runs under Windows PowerShell 5.1 and pwsh; no launcher runs.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-words-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/runtime-personal.ps1")
$script:LogFile = $null
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

try {
    $said = @(
        'Using default deployment directory: C:\Users\u\AppData\Local\exasol\launcher\deployments\default',
        'Error: deployment failed: deployment in C:\Users\u\AppData\Local\exasol\launcher\deployments\default is in state "stopped". Deployment stopped. Run `start` to restart or `destroy` to delete resources.',
        'Use `destroy` to remove the old deployment first. Then retry.',
        "run 'exasol destroy' to clean up",
        'Run `start` again later.')
    $script:PersonalLauncherOutput = $said
    # Write-Host goes to the information stream (6) on 5.1 as on pwsh. Each
    # record is read as its own text: Out-String wraps at the console width on
    # Windows PowerShell 5.1, which split the launcher's long error line.
    $out = (@(Show-PersonalLauncherTail 6>&1) | ForEach-Object { "$_" }) -join "`n"
    Write-Host "the failure box:"
    Contains "the launcher's error is still shown" 'is in state "stopped". Deployment stopped.' $out
    Contains "its start is the kit's" 'Run `exakit start` to restart.' $out
    Lacks    "no destroy instruction" '`destroy`' $out
    Lacks    "  in any quoting" "'exasol destroy'" $out
    Lacks    "  nor the rest of that sentence" "delete resources" $out
    Contains "the sentence after a dropped one stays" "Then retry." $out
    Contains "a bare start hint is mapped too" 'Run `exakit start` again later.' $out
    Contains "lines without a hint are unchanged" 'Using default deployment directory:' $out
    Contains "the launcher's own words are kept" '`destroy` to delete resources' ($script:PersonalLauncherOutput -join "`n")
} finally {
    Remove-Item -Recurse -Force -Path $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "launcher-words-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
exit 0
