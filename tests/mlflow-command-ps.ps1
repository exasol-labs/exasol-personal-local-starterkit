# Public PowerShell MLflow adapter smoke test. The shared behavior and live
# localhost server are covered by test_marketplace_mlflow.py and the Bash twin.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $root 'setup/exakit.ps1'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-mlflow-$([guid]::NewGuid().ToString('N'))"
$oldKit = $env:EXAKIT_HOME
$oldHome = $env:HOME
$script:PASS = 0
$script:FAIL = 0

function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}

try {
    $env:HOME = Join-Path $work 'user'
    $env:EXAKIT_HOME = Join-Path $work 'kit'
    New-Item -ItemType Directory -Force $env:HOME, $env:EXAKIT_HOME | Out-Null

    $out = @(& $cli mlflow status --json)
    $code = $LASTEXITCODE
    $state = ($out -join "`n") | ConvertFrom-Json
    Check 'status returns one JSON object' 1 $out.Count
    Check 'status succeeds' 0 $code
    Check 'status is stopped' 'stopped' $state.status
    Check 'status gives a runnable remedy' 'exakit mlflow start' $state.remedy
    Check 'status did not create an MLflow directory' $false (Test-Path (Join-Path $env:EXAKIT_HOME 'mlflow'))

    $out = @(& $cli mlflow start --json)
    $code = $LASTEXITCODE
    $refusal = ($out -join "`n") | ConvertFrom-Json
    Check 'start without UDF devkit fails' 1 $code
    Check 'start gives the UDF devkit command' 'exakit marketplace udf-devkit' $refusal.remedy
    Check 'start refusal is one JSON object' 1 $out.Count

    $out = @(& $cli mlflow start --disable --json)
    $code = $LASTEXITCODE
    $bad = ($out -join "`n") | ConvertFrom-Json
    Check 'unknown start option exits 2' 2 $code
    Check 'unknown start option is rejected' $true $bad.rejected
    Check 'unknown start option is one JSON object' 1 $out.Count

    $out = @(& $cli mlflow replay --json)
    $code = $LASTEXITCODE
    $missing = ($out -join "`n") | ConvertFrom-Json
    Check 'replay without Notebook fails' 1 $code
    Check 'replay gives the Notebook command' 'exakit marketplace notebook' $missing.remedy
} finally {
    $env:HOME = $oldHome
    $env:EXAKIT_HOME = $oldKit
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "mlflow-command-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
