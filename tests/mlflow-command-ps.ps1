# Isolated PowerShell command smoke. No server or database process.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-mlflow-$([guid]::NewGuid().ToString('N'))"
$oldHome = $env:HOME; $oldKit = $env:EXAKIT_HOME
try {
    $env:HOME = Join-Path $work "user"
    $env:EXAKIT_HOME = Join-Path $work "kit"
    New-Item -ItemType Directory -Force $env:HOME, $env:EXAKIT_HOME | Out-Null
    . (Join-Path $root "setup/lib/exakit-common.ps1")
    . (Join-Path $root "setup/lib/persona.ps1")
    . (Join-Path $root "setup/lib/notebook.ps1")
    . (Join-Path $root "setup/lib/mlflow.ps1")
    $doc = Invoke-MlflowService -ServiceArgs @("status", "--json") | ConvertFrom-Json
    if ($doc.status -ne "stopped" -or $doc.remedy -ne "exakit mlflow start") { throw "wrong status: $($doc | ConvertTo-Json -Compress)" }
    if (Test-Path (Join-Path $env:EXAKIT_HOME "mlflow")) { throw "status wrote files" }
    $url = Invoke-MlflowService -ServiceArgs @("url")
    if ($url) { throw "stopped server has a URL" }
    Write-Host "mlflow-command-ps: status and URL passed"
} finally {
    $env:HOME = $oldHome; $env:EXAKIT_HOME = $oldKit
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
