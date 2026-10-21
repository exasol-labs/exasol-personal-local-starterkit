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

    Write-Host "notebooks are copied once, into persona folders, never over the user's:"
    $nb = Join-Path $script:NotebookDir "starter-kit-notebooks"
    New-Item -ItemType Directory -Force -Path (Join-Path $nb "general") | Out-Null
    Set-Content -Path (Join-Path (Join-Path $nb "general") "start_here.ipynb") -Value "mine" -NoNewline
    Check "what is missing comes, each in its persona's folder" `
        "data-scientist/explore.ipynb,data-scientist/text_classification.ipynb,ml-engineer/bank_marketing_mlflow.ipynb,ml-engineer/train.ipynb" `
        (@(Copy-NotebookContent) -join ",")
    Check "the user's own stays" "mine" (Get-Content -Raw (Join-Path (Join-Path $nb "general") "start_here.ipynb"))
    Check "a second run adds nothing" 0 @(Copy-NotebookContent).Count
    Check "a README names the end-to-end path" $true (Test-Path (Join-Path $nb "README.md"))
    Check "the Marimo ones go to marimo/<persona>/" "data-scientist/explore.py,data-scientist/text_classification.py,ml-engineer/bank_marketing_mlflow.py,ml-engineer/train.py" `
        (@(Copy-NotebookContent -Front marimo) -join ",")

    Write-Host "the notebook tools: one checklist, all three ticked:"
    foreach ($v in @("EXAKIT_NOTEBOOK_FRONTENDS", "EXAKIT_NOTEBOOK_JUPYTER", "EXAKIT_NOTEBOOK_MARIMO")) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
    function Test-ExakitInteractive { return $false }
    Check "without a console the ticks stand" "jupyterlab,marimo,positron" (Get-NotebookFrontEnds)
    $env:EXAKIT_NOTEBOOK_MARIMO = "skip"
    Check "EXAKIT_NOTEBOOK_MARIMO=skip leaves Marimo out" "jupyterlab,positron" (Get-NotebookFrontEnds)
    Remove-Item Env:EXAKIT_NOTEBOOK_MARIMO
    $env:EXAKIT_NOTEBOOK_FRONTENDS = "Marimo, positron"
    Check "EXAKIT_NOTEBOOK_FRONTENDS answers it" "marimo,positron" (Get-NotebookFrontEnds)
    Remove-Item Env:EXAKIT_NOTEBOOK_FRONTENDS
    $catalog = Get-Content -Raw (Join-Path (Join-Path $repo "notebook") "catalog.json") | ConvertFrom-Json
    Check "Marimo's pin is the one notebook/catalog.json converts with" $catalog.marimo_package $script:NotebookMarimoPackage

    Write-Host "Positron is configured, never installed:"
    $vscode = Join-Path $script:NotebookDir ".vscode"
    New-Item -ItemType Directory -Force -Path $vscode | Out-Null
    Set-Content -Path (Join-Path $vscode "settings.json") -Value '{"editor.fontSize": 14}' -NoNewline
    Check "the folder is prepared" $true (Set-NotebookPositronFolder)
    $settings = Get-Content -Raw (Join-Path $vscode "settings.json") | ConvertFrom-Json
    Check "the folder names the kit's Python" (Get-NotebookVenvPython) $settings."python.defaultInterpreterPath"
    Check "the user's own settings stay" 14 $settings."editor.fontSize"
    Set-Content -Path (Join-Path $vscode "settings.json") -Value '{not json' -NoNewline
    Check "a file that is not JSON is left alone" "False|{not json" "$(Set-NotebookPositronFolder)|$(Get-Content -Raw (Join-Path $vscode 'settings.json'))"

    Write-Host "exakit notebook refuses what it does not know:"
    foreach ($bad in @(@("--frob"), @("--port"), @("--port", "abc"), @("--port", "80"), @("--marimo", "--positron"))) {
        $refused = $false
        try { Invoke-CmdNotebook -CmdArgs $bad } catch { $refused = "$_" -like "FAIL:*" }
        Check "refuses: $($bad -join ' ')" $true $refused
    }
    $said = ""
    try { Invoke-CmdNotebook -CmdArgs @("--check") } catch { $said = "$_" }
    Contains "not installed names the marketplace" "exakit marketplace notebook" $said

    Write-Host "an uninstall keeps the notebooks:"
    [void](Uninstall-Notebook)
    Check "the notebooks are still there" "mine" (Get-Content -Raw (Join-Path (Join-Path $nb "general") "start_here.ipynb"))
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "notebook-addon-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
