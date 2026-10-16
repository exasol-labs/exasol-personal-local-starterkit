#!/usr/bin/env pwsh
# Hermetic Windows twin test: S3 pin belongs to raw EXE; GitHub ZIP is fallback.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-s3-ps-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:EXAKIT_PERSONAL_VERSION = "2.3.0"
$env:EXAKIT_FORCE_COMPONENT_INSTALL = "1"
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/runtime-personal.ps1")
# The REAL Get-ExakitFile -Soft, before the stub below replaces it, against a
# loopback listener that accepts the connection and never answers: the only
# thing that can end the call is the HEAD probe's 10 s cap, so one $false in
# about ten seconds proves the cap (a refused port would answer instantly with
# or without the probe). Nothing leaves the machine.
$script:silent = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$script:silent.Start()
$script:silentPort = $script:silent.LocalEndpoint.Port
$script:softWatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:softAnswer = @(Get-ExakitFile -Url "http://127.0.0.1:$($script:silentPort)/personal/exasol.exe" -Dest (Join-Path $work "probe.exe") -Soft)
$script:softWatch.Stop()
$script:silent.Stop()
$script:BinDir = Join-Path $work "bin"
$script:PersonalBinPath = Join-Path $script:BinDir "exasol.exe"
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++ }
    else { $script:FAIL++; Write-Host "FAIL $($label): expected <$expected>, got <$actual>" }
}
function Get-ExakitVersionsValue {
    param([string]$Path)
    switch ($Path) {
        "components.personal.version" { return "2.3.0" }
        "components.personal.s3.base_url" { return "https://example.test/personal" }
        "components.personal.s3.sha256.windows-x86_64" { return ('a' * 64) }
    }
}
function Info { param($Text) }
function Ok { param($Text) }
function Warn2 { param($Text) }
function OkStep { param($Text) }
function Write-ExakitLog { param($Kind, $Text) }
function Test-ExakitStdoutIsTerminal { return $false }
function Get-ExakitTilde { param($Path) return $Path }
function Get-ExakitSha256 {
    param($Path)
    if ((Get-Content $Path -Raw) -eq 'good-s3') { return ('a' * 64) }
    return ('b' * 64)
}
function Test-ExakitSha256 { param($Path, $Expected) }
function Expand-Archive {
    param($Path, $DestinationPath, [switch]$Force)
    New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null
    Set-Content -NoNewline -Path (Join-Path $DestinationPath "exasol.exe") -Value 'github-bin'
}
$script:mode = 'success'
$script:s3Calls = 0
$script:githubCalls = 0
function Get-ExakitFile {
    param($Url, $Dest, [switch]$Soft)
    if ($Soft) {
        $script:s3Calls++
        if ($script:mode -eq 'fail') { return $false }
        $payload = if ($script:mode -eq 'mismatch') { 'bad-s3' } else { 'good-s3' }
        Set-Content -NoNewline -Path $Dest -Value $payload
        return $true
    }
    $script:githubCalls++
    if ($Dest -like '*checksums.txt') {
        Set-Content -Path $Dest -Value (('c' * 64) + '  exasol-personal_Windows_x86_64.zip')
    } else { Set-Content -NoNewline -Path $Dest -Value 'archive' }
}

try {
    Check 'a missed soft download is one $false' $true ($script:softAnswer.Count -eq 1 -and $script:softAnswer[0] -eq $false)
    Check '...ended by the probe cap, about ten seconds' $true ($script:softWatch.Elapsed.TotalSeconds -ge 8 -and $script:softWatch.Elapsed.TotalSeconds -lt 15)
    $source = Get-PersonalS3Source -Version '2.3.0'
    Check 'versioned S3 URL' 'https://example.test/personal/windows/x86_64/2.3.0/exasol.exe' $source.Url
    Check 'override does not reuse old pin' $null (Get-PersonalS3Source -Version '2.4.0')
    $env:EXAKIT_PERSONAL_S3 = "0"
    Check 'EXAKIT_PERSONAL_S3=0 builds no S3 source' $null (Get-PersonalS3Source -Version '2.3.0')
    $script:mode = 'success'
    $s3Before = $script:s3Calls
    Install-PersonalLauncher
    Check 'EXAKIT_PERSONAL_S3=0 never touches S3' $s3Before $script:s3Calls
    Check '...and installs the verified GitHub binary' 'github-bin' (Get-Content $script:PersonalBinPath -Raw)
    Remove-Item Env:EXAKIT_PERSONAL_S3
    $script:githubCalls = 0

    Install-PersonalLauncher
    Check 'S3 success avoids GitHub' 0 $script:githubCalls
    Check 'raw S3 executable installed' 'good-s3' (Get-Content $script:PersonalBinPath -Raw)

    $script:mode = 'mismatch'
    Install-PersonalLauncher
    Check 'S3 mismatch downloads ZIP and checksum' 2 $script:githubCalls
    Check 'mismatched S3 EXE not installed' 'github-bin' (Get-Content $script:PersonalBinPath -Raw)

    $script:mode = 'fail'
    Install-PersonalLauncher
    Check 'S3 transfer failure downloads ZIP and checksum' 4 $script:githubCalls
    Check 'verified fallback installed' 'github-bin' (Get-Content $script:PersonalBinPath -Raw)
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host "$($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL) { exit 1 }
