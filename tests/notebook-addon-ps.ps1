#!/usr/bin/env pwsh
# notebook-addon-ps.ps1 - the Windows twin of tests/notebook-addon.sh: the
# notebook add-on's own behaviour in setup/lib/notebook.ps1. Runs under Windows
# PowerShell 5.1 and pwsh; a sandboxed kit home, no database, no network.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-notebook-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/notebook.ps1")
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
# Fail ends the run in the real CLI; here it throws so a refusal is observable.
function Fail([string]$Msg) { throw "FAIL: $Msg" }

try {
    Write-Host "the install is one pinned resolution:"
    $script:NotebookVersion = "3.1.0"
    $specs = @(Get-NotebookSpecs)
    Check "the connector, pinned, with its extras" "exasol-notebook-connector[bucketfs,ibis,pyexasol,sqlalchemy]==3.1.0" $specs[0]
    Contains "the kernel package" "ipykernel>=6.29,<8" ($specs -join " ")
    Contains "the MLflow client, not the server" "mlflow-skinny>=2.14,<4" ($specs -join " ")
    Check "the kit's helper package" (Join-Path (Join-Path $repo "notebook") "package") $specs[-2]
    Check "the kit's MLflow client package" (Join-Path (Join-Path $repo "packages") "exasol-mlflow") $specs[-1]
    Check "JupyterLab is not in it" 0 @($specs | Where-Object { $_ -match "jupyterlab" }).Count

    Write-Host "notebooks are copied once, never over the user's:"
    New-Item -ItemType Directory -Force -Path $script:NotebookDir | Out-Null
    Set-Content -Path (Join-Path $script:NotebookDir "start_here.ipynb") -Value "mine" -NoNewline
    $shipped = @(Get-ChildItem -Path (Join-Path (Join-Path $repo "notebook") "notebooks") -Filter "*.ipynb" | Where-Object { $_.Name -ne "start_here.ipynb" } | Sort-Object Name | ForEach-Object { $_.Name })
    Check "what is missing comes" ($shipped -join ",") (@(Copy-NotebookContent) -join ",")
    Check "the user's own stays" "mine" (Get-Content -Raw (Join-Path $script:NotebookDir "start_here.ipynb"))
    Check "a second run adds nothing" 0 @(Copy-NotebookContent).Count

    Write-Host "exakit notebook refuses what it does not know:"
    foreach ($bad in @(@("--frob"), @("--port"), @("--port", "abc"), @("--port", "80"))) {
        $refused = $false
        try { Invoke-CmdNotebook -CmdArgs $bad } catch { $refused = "$_" -like "FAIL:*" }
        Check "refuses: $($bad -join ' ')" $true $refused
    }
    $said = ""
    try { Invoke-CmdNotebook -CmdArgs @("--check") } catch { $said = "$_" }
    Contains "not installed names the marketplace" "exakit marketplace notebook" $said

    Write-Host "an uninstall keeps the notebooks:"
    [void](Uninstall-Notebook)
    Check "the notebooks are still there" "mine" (Get-Content -Raw (Join-Path $script:NotebookDir "start_here.ipynb"))
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "notebook-addon-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
