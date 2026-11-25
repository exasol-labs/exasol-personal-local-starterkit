#!/usr/bin/env pwsh
# prompt-spinner-safety-ps.ps1 - the Windows twin of prompt-spinner-safety.sh:
# a question is never asked under a live spinner or step bar. The bar repaints
# its line every 0.2 s, so a question printed under it is gone a moment later
# and the install looks hung (MX-05). Read-ExakitPrompt and Confirm-ExakitPrompt
# stop the animation first.
#
# Runs under Windows PowerShell 5.1 and pwsh. Read-Host is stubbed: it records
# whether an animation was still live at the moment the question waited.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-prompt-spin-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
. (Join-Path $repo "setup/lib/exakit-common.ps1")
$script:LogFile = $null
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}

function Test-ExakitInteractive { return $true }
$script:liveAtQuestion = $null
function Read-Host { $script:liveAtQuestion = ($null -ne $script:UiSpinFlag); return "y" }

try {
    $script:UiFancy = $true
    foreach ($case in @("Read-ExakitPrompt", "Confirm-ExakitPrompt")) {
        Write-Host "== $case inside a grouped step's bar"
        Start-ExakitStepBar 0 3 "Data Loader"
        Check "$($case): the bar is running (the test is not vacuous)" $true ($null -ne $script:UiSpinFlag)
        $script:liveAtQuestion = $null
        if ($case -eq "Read-ExakitPrompt") { [void](Read-ExakitPrompt "Database password for user sys" "") }
        else { [void](Confirm-ExakitPrompt "Use it?" $true) }
        Check "$($case): nothing animates while the question waits" $false $script:liveAtQuestion
        Stop-ExakitStepBar
        Stop-ExakitSpinnerAll

        Write-Host "== $case under a plain spinner"
        Start-ExakitSpinner "Installing"
        $script:liveAtQuestion = $null
        if ($case -eq "Read-ExakitPrompt") { [void](Read-ExakitPrompt "Profile name" "starter-kit") }
        else { [void](Confirm-ExakitPrompt "Use it?" $true) }
        Check "$($case): nothing animates while the question waits" $false $script:liveAtQuestion
        Stop-ExakitSpinnerAll
    }
} finally {
    try { Stop-ExakitSpinnerAll } catch { }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "prompt-spinner-safety-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
