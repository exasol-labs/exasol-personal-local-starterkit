#!/usr/bin/env pwsh
# temp-cleanup-ps.ps1 - install.ps1's dry run leaves nothing in %TEMP%.
#
#   pwsh -NoProfile -File tests/temp-cleanup-ps.ps1
#
# A dry run used to stage the kit in %TEMP%\exakit-dry-run-* and never remove
# it, and a local-kit copy took the whole checkout with it (.claude worktrees,
# caches: ~500 MB). Each run here gets a temp folder of its own, so a leak is
# an entry in a folder that must be empty. Runs install.ps1 the way users do,
# as a string through Invoke-Expression, in a child of this same engine (5.1
# on the Windows leg). Off Windows the installer's platform gate is answered
# through $env:OS, as it is nowhere else.
#
# twin: tests/temp-cleanup.sh

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-tc-test-$([guid]::NewGuid().ToString('N'))"
$scratch = Join-Path $work "tmp"
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$engine = (Get-Process -Id $PID).Path
$installer = Join-Path $repo "install.ps1"

function Get-Left { (@(Get-ChildItem -LiteralPath $scratch -Force | ForEach-Object { $_.Name }) -join " ") }

# Invoke-DryRun <local kit> [keep] - one dry run in a child engine, with this
# test's temp folder and kit home. Returns the child's output as one string.
function Invoke-DryRun($localKit, [switch]$Keep) {
    $saved = @{}
    $vars = @{
        TMP = $scratch; TEMP = $scratch; TMPDIR = $scratch
        EXAKIT_HOME = (Join-Path $work "home\kit")
        EXAKIT_LOCAL_KIT = $localKit
        EXAKIT_DRY_RUN = "1"
        EXAKIT_DRY_RUN_KEEP = $(if ($Keep) { "1" } else { "" })
    }
    if ($env:OS -notlike "*Windows*") {
        $vars["OS"] = "Windows_NT"
        $vars["PROCESSOR_ARCHITECTURE"] = "AMD64"
        $vars["USERPROFILE"] = (Join-Path $work "home")
    }
    foreach ($k in $vars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $vars[$k])
    }
    try {
        $cmd = "Get-Content -Raw -LiteralPath '$installer' | Invoke-Expression"
        $out = & $engine -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    return $out
}

try {
    Write-Host ""
    Write-Host "== install.ps1: a dry run leaves nothing in TEMP =="
    $out = Invoke-DryRun $repo
    Check "first dry run reached the plan" "True" ($out -match "Dry run requested")
    Check "first dry run: TEMP is empty" "" (Get-Left)
    $out = Invoke-DryRun $repo
    Check "second dry run: TEMP is empty" "" (Get-Left)
    Check "and says the folder was removed" "True" ($out -match "has been removed")

    Write-Host ""
    Write-Host "== install.ps1: EXAKIT_DRY_RUN_KEEP=1 keeps it, and only the kit =="
    $out = Invoke-DryRun $repo -Keep
    $kept = Get-ChildItem -LiteralPath $scratch -Directory -Filter "exakit-dry-run-*" | Select-Object -First 1
    $keptKit = if ($kept) { Join-Path $kept.FullName "kit" } else { "" }
    Check "the folder is kept" "True" ([bool]$kept -and (Test-Path (Join-Path $keptKit "install.ps1")))
    Check "and named in the output" "True" ($out -match "kept for inspection")
    Check "no .git in the copy" "False" ([bool]$kept -and (Test-Path (Join-Path $keptKit ".git")))
    Check "no .claude in the copy" "False" ([bool]$kept -and (Test-Path (Join-Path $keptKit ".claude")))
    Get-ChildItem -LiteralPath $scratch -Force | Remove-Item -Recurse -Force

    Write-Host ""
    Write-Host "== install.ps1: a failure after staging cleans up too =="
    # Passes the first check (setup\exakit.ps1 is there) and fails the sentinel
    # check after the staging folder exists - the throw lands in the trap.
    $broken = Join-Path $work "broken-kit"
    New-Item -ItemType Directory -Force -Path (Join-Path $broken "setup") | Out-Null
    Set-Content -Path (Join-Path $broken "setup\exakit.ps1") -Value "# stub"
    New-Item -ItemType Directory -Force -Path (Join-Path $broken ".claude\worktrees") | Out-Null
    $out = Invoke-DryRun $broken
    Check "the incomplete kit is refused" "True" ($out -match "incomplete")
    Check "failure: TEMP is empty" "" (Get-Left)
} finally {
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$script:PASS passed, $script:FAIL failed"
if ($script:FAIL -gt 0) { exit 1 }
exit 0
