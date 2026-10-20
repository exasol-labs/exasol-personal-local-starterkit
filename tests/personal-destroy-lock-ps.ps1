#!/usr/bin/env pwsh
# personal-destroy-lock-ps.ps1 - the Windows twin of personal-destroy-lock.sh:
# Invoke-PersonalDestroy in setup/lib/runtime-personal.ps1 releases a lock a
# crashed launcher left behind (diag unlock) and destroys once more - only when
# no launcher process runs - and otherwise quotes the launcher's own error.
# Runs under Windows PowerShell 5.1 and pwsh; a stub launcher, never a real
# deployment.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-destroy-lock-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/runtime-personal.ps1")
$script:LogFile = $null
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
$onWindows = $env:OS -eq "Windows_NT"
$lock = 'Error: Deployment directory is locked by another operation. Please wait. Do not use `unlock` unless you are certain that no other exasol launcher instance is running.'

# The stub launcher: destroy answers from <case>/destroy.<n>.rc and .out; every
# call is recorded in <case>/calls. A .cmd on Windows, a sh script elsewhere.
function New-StubCase([string]$Name, [object[]]$Answers) {
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    for ($i = 0; $i -lt $Answers.Count; $i += 2) {
        $n = ($i / 2) + 1
        Set-Content -Path (Join-Path $dir "destroy.$n.rc") -Value $Answers[$i] -Encoding Ascii
        Set-Content -Path (Join-Path $dir "destroy.$n.out") -Value $Answers[$i + 1] -Encoding Ascii
    }
    if ($onWindows) {
        $stub = Join-Path $dir "exasol.cmd"
        $body = @(
            '@echo off',
            ('set D=' + $dir),
            'echo %*>> "%D%\calls"',
            'if "%1 %2"=="diag unlock" exit /b 0',
            'if not "%1"=="destroy" exit /b 0',
            'set /a N=0',
            'if exist "%D%\n" set /p N=<"%D%\n"',
            'set /a N=%N%+1',
            '>"%D%\n" echo %N%',
            'type "%D%\destroy.%N%.out" 2>nul',
            'set /p RC=<"%D%\destroy.%N%.rc"',
            'exit /b %RC%')
        Set-Content -Path $stub -Value $body -Encoding Ascii
    } else {
        $stub = Join-Path $dir "exasol"
        $body = @(
            '#!/bin/sh',
            ('D="' + $dir + '"'),
            'echo "$*" >> "$D/calls"',
            'case "$1 $2" in "diag unlock") exit 0 ;; esac',
            '[ "$1" = destroy ] || exit 0',
            'n=$(( $(cat "$D/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/n"',
            'cat "$D/destroy.$n.out"; exit "$(cat "$D/destroy.$n.rc")"')
        Set-Content -Path $stub -Value $body -Encoding Ascii
        & chmod +x $stub
    }
    return $stub
}
function Get-Calls([string]$Name) {
    $file = Join-Path (Join-Path $work $Name) "calls"
    if (-not (Test-Path $file)) { return "" }
    return ((Get-Content $file | ForEach-Object { "$_".Trim() }) -join "|")
}

try {
    Write-Host "== a stale lock is released and the destroy retried"
    $script:stub = New-StubCase "stale" @("1", $lock, "0", "destroyed")
    function Get-PersonalCli { return $script:stub }
    Check "stale: destroyed" $true (Invoke-PersonalDestroy)
    Check "stale: launcher calls" "destroy --remove --auto-approve|diag unlock --auto-approve|destroy --remove --auto-approve" (Get-Calls "stale")

    Write-Host "== a running launcher keeps its lock"
    $script:stub = New-StubCase "busy" @("1", $lock)
    # A process whose image name is the launcher's: a copy of a program that waits.
    $holder = Join-Path $work "holder"
    New-Item -ItemType Directory -Force -Path $holder | Out-Null
    if ($onWindows) {
        Copy-Item (Join-Path $env:SystemRoot "System32\PING.EXE") (Join-Path $holder "exasol.exe")
        $proc = Start-Process -FilePath (Join-Path $holder "exasol.exe") -ArgumentList "-n", "60", "127.0.0.1" -PassThru -WindowStyle Hidden
        Start-Sleep -Milliseconds 500
    } else {
        # pwsh on macOS/Linux: a copied system binary will not run, so the process
        # table is stubbed (a function outranks the cmdlet); Windows runs the real one.
        $proc = $null
        function Get-Process { param([string]$Name, $ErrorAction) if ($Name -eq "exasol") { return [pscustomobject]@{ Id = 1; ProcessName = "exasol" } } }
    }
    try {
        Check "busy: not destroyed" $false (Invoke-PersonalDestroy)
        Check "busy: no unlock" "destroy --remove --auto-approve" (Get-Calls "busy")
        Contains "busy: the launcher's words" "locked by another operation" $script:PersonalDestroyError
    } finally {
        if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item Function:\Get-Process -ErrorAction SilentlyContinue
    }

    Write-Host "== any other failure is quoted, never retried"
    $script:stub = New-StubCase "other" @("1", "Destroying...`nwarning: slow`nError: disk full")
    Check "other: not destroyed" $false (Invoke-PersonalDestroy)
    Check "other: one destroy" "destroy --remove --auto-approve" (Get-Calls "other")
    Check "other: the last error line" "Error: disk full" $script:PersonalDestroyError
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "personal-destroy-lock-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
