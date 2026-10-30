#!/usr/bin/env pwsh
# Public PowerShell workflow CLI contract; the implementation is Python.
$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-workflow-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "kit"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:EXAKIT_VERSION_POLICY = "pinned"
New-Item -ItemType Directory -Force -Path $env:EXAKIT_HOME, $env:EXAKIT_BIN_DIR | Out-Null
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Contains($label, $needle, $haystack) {
    if ("$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> not in <$haystack>" }
}
$hostBin = if ($PSVersionTable.PSEdition -eq "Desktop") { "powershell" } else { "pwsh" }
function Run {
    param([string[]]$Words = @())
    $script:OUT = (@(& $hostBin -NoProfile -File (Join-Path $repo "setup/exakit.ps1") "workflow" @Words 2>&1 |
        ForEach-Object { "$_" }) -join "`n")
    $script:CODE = $LASTEXITCODE
}
try {
    Run @(); Check "missing action" 2 $CODE; Contains "usage named" "exakit workflow list" $OUT
    Run @("frobnicate"); Check "unknown action" 2 $CODE; Contains "supported actions" "supported: list, show" $OUT
    Run @("list", "--bogus"); Check "unknown option" 2 $CODE
    Run @("show", "..\other"); Check "path is not an id" 2 $CODE
    Run @("show", "nope"); Check "invalid id" 2 $CODE
    Run @("show"); Check "missing id" 2 $CODE
    Run @("list", "extra"); Check "list argument" 2 $CODE
    Run @("frobnicate", "--json"); Check "JSON refusal exit" 2 $CODE
    $refusal = $OUT | ConvertFrom-Json
    Check "JSON refusal rejected" $true $refusal.rejected
    Check "JSON refusal ok is false" $false $refusal.ok
    Run @("list", "--json"); Check "missing notebook exit" 1 $CODE
    Check "missing notebook remedy" "exakit marketplace notebook" (($OUT | ConvertFrom-Json).remedy)
    [System.IO.File]::WriteAllText((Join-Path $env:EXAKIT_HOME "manifest.json"),
        '{"components":{"notebook":{"version":"3.1.0"}}}')
    Run @("list"); Check "missing venv exit" 1 $CODE
    Contains "missing venv remedy" "exakit notebook setup" $OUT
    Run @("--help"); Check "help exit" 0 $CODE; Contains "help describes workflow" "workflow" $OUT
    $cli = Get-Content -Raw (Join-Path $repo "setup/exakit.ps1")
    Contains "public entry routes to Python" 'Invoke-ExakitMarketplaceCli -Script workflow_cli' $cli
    $help = Get-Content -Raw (Join-Path $repo "setup/help/exakit.json") | ConvertFrom-Json
    Check "help metadata lists workflow" 1 @($help.commands | Where-Object { $_.command -eq "workflow" }).Count
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "$(Split-Path -Leaf $PSCommandPath): $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -ne 0) { exit 1 }
