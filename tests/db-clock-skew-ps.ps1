#!/usr/bin/env pwsh
# db-clock-skew-ps.ps1 - the Windows twin of the database clock check: the
# measurement, its words and its limit. Twin of the helper section of
# tests/db-clock-skew.sh; the database is a stub exapump that answers the
# clock query with this computer's time shifted by FAKE_SKEW seconds.
#
#   pwsh -NoProfile -File tests/db-clock-skew-ps.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/db-clock-skew-ps.ps1

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-clock-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path (Join-Path $work "home") | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:EXAKIT_LOG_FILE = Join-Path $work "test.log"
Set-Content -Path (Join-Path $env:EXAKIT_HOME "manifest.json") -Value '{"components": {"exapump": {"profile": "starter-kit"}}}'

# $env:OS, not $IsWindows: the automatic variable does not exist on 5.1.
if ($env:OS -like "*Windows*") {
    $stub = Join-Path $work "exapump.cmd"
    Set-Content -Path $stub -Encoding Ascii -Value @(
        "@echo off",
        "if `"%FAKE_MODE%`"==`"down`" (echo connection refused 1>&2 & exit /b 1)",
        "powershell -NoProfile -Command `"'T'; 'EXAKIT_CLOCK=' + ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + [long]`$env:FAKE_SKEW)`"",
        "exit /b 0"
    )
} else {
    $stub = Join-Path $work "exapump"
    Set-Content -Path $stub -Value @(
        "#!/bin/sh",
        "[ `"`$FAKE_MODE`" = down ] && { echo 'connection refused' >&2; exit 1; }",
        "printf 'T\nEXAKIT_CLOCK=%s\n' `$(( `$(date +%s) + `${FAKE_SKEW:-0} ))",
        "exit 0"
    )
    & chmod +x $stub
}
$env:EXAKIT_EXAPUMP_BIN = $stub

. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/exapump.ps1")

try {
    Write-Host ""
    Write-Host "== the measurement =="
    $env:FAKE_MODE = ""
    $env:FAKE_SKEW = "-1955"
    $skew = Get-ExakitDbClockSkew
    Check "a database 1955 s behind measures within a second" $true ($skew -ge -1956 -and $skew -le -1954)
    $env:FAKE_SKEW = "0"
    $skew = Get-ExakitDbClockSkew
    Check "an in-sync database measures within a second" $true ($skew -ge -1 -and $skew -le 1)
    $env:FAKE_MODE = "down"
    Check "a database that cannot be asked answers null" $true ($null -eq (Get-ExakitDbClockSkew))
    $env:FAKE_MODE = ""

    Write-Host ""
    Write-Host "== the words and the limit (twin of exakit_clock_skew_words / exakit_clock_skewed) =="
    Check "words for 0" "0 min ahead of" (Format-ExakitClockSkew 0)
    Check "words for -1955" "33 min behind" (Format-ExakitClockSkew -1955)
    Check "words for -5100" "1 h 25 min behind" (Format-ExakitClockSkew -5100)
    Check "words for -8760" "2 h 26 min behind" (Format-ExakitClockSkew -8760)
    Check "words for 150" "3 min ahead of" (Format-ExakitClockSkew 150)
    Check "skewed? -119" $false (Test-ExakitClockSkewed -119)
    Check "skewed? 119" $false (Test-ExakitClockSkewed 119)
    Check "skewed? -120" $true (Test-ExakitClockSkewed -120)
    Check "skewed? 120" $true (Test-ExakitClockSkewed 120)
    Check "skewed? null" $false (Test-ExakitClockSkewed $null)
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
