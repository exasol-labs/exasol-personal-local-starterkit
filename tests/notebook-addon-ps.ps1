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

    Write-Host "options are matched exactly, as the shell side does; a long --port is refused cleanly:"
    foreach ($case in @(@(@("--CHECK"), "*Unknown option*"), @(@("--Stop"), "*Unknown option*"),
                        @(@("--port", "99999999999"), "*--port needs a number*"), @(@("--port", "065536"), "*--port needs a number*"))) {
        $said = ""
        try { Invoke-CmdNotebook -CmdArgs $case[0] } catch { $said = "$_" }
        Check "refuses: $($case[0] -join ' ')" $true ($said -like $case[1])
    }

    Write-Host "the notebook tools: the variable is checked, a recorded choice stands:"
    Check "names in any case, jupyter as jupyterlab, any whitespace, unknown ones dropped" "jupyterlab,positron" `
        (ConvertTo-NotebookFrontEnds "Jupyter`tPOSITRON ,frob" -Quiet)
    Check "none alone is none" "none" (ConvertTo-NotebookFrontEnds " none ")
    Initialize-ExakitManifest
    Set-ExakitManifestValue "components.notebook.front_ends" "jupyterlab,positron"
    Check "a reinstall keeps the recorded choice" "jupyterlab,positron" (Get-NotebookFrontEnds)
    $env:EXAKIT_NOTEBOOK_FRONTENDS = "marimo"
    Check "the variable still overrides it" "marimo" (Get-NotebookFrontEnds)
    $env:EXAKIT_NOTEBOOK_FRONTENDS = "frob"
    Check "a variable naming nothing known falls back to the record" "jupyterlab,positron" (Get-NotebookFrontEnds 6>$null)
    Remove-Item Env:EXAKIT_NOTEBOOK_FRONTENDS
    Add-NotebookFrontEnd "marimo"
    Check "a tool added later joins the record" "jupyterlab,marimo,positron" (Get-ExakitManifestValue "components.notebook.front_ends")
    Remove-ExakitManifestValue "components.notebook"

    Write-Host "the kit's own packages are reinstalled on every install and update:"
    $script:LoggedArgs = @()
    function Get-NotebookUv { return "uv" }
    function Invoke-ExakitLogged { param($Cmd, [Parameter(ValueFromRemainingArguments)]$Rest) $script:LoggedArgs = @($Rest); return 0 }
    [void](Sync-NotebookPackages)
    Contains "with --reinstall-package for both" "--reinstall-package exakit-nb --reinstall-package exasol-mlflow" ($script:LoggedArgs -join " ")

    Write-Host "exakit logs notebook: two targets:"
    $logs = @(Get-NotebookLogPath)
    Check "JupyterLab's log" "notebook|JupyterLab (exakit notebook)|$(Get-NotebookLogFile)" $logs[0]
    Check "Marimo's log" "notebook-marimo|Marimo (notebook --marimo)|$(Get-NotebookMarimoLogFile)" $logs[1]

    Write-Host "a pid file is trusted only while its process is the kit's server:"
    $python = (Get-Command python3).Source
    $bystander = Start-Process -FilePath $python -ArgumentList @("-c", "`"import time; time.sleep(60)`"") -PassThru
    $ours = Start-Process -FilePath $python -ArgumentList @("-c", "`"import time; time.sleep(60)`"", "jupyter-lab", "--ServerApp.ip=127.0.0.1") -PassThru
    Start-Sleep -Milliseconds 500
    Check "a server the kit started is recognised" $true (Test-NotebookProcessOurs -PidText "$($ours.Id)" -Pattern $script:NotebookJupyterMatch)
    New-Item -ItemType Directory -Force -Path $script:NotebookHome | Out-Null
    Set-Content -Path (Get-NotebookPidFile) -Value $bystander.Id
    Check "a pid file naming another program is stale: stopped" "stopped" (Get-NotebookServerState)
    Check "the stale pid file is gone" $false (Test-Path (Get-NotebookPidFile))
    Set-Content -Path (Get-NotebookPidFile) -Value $bystander.Id
    Stop-NotebookServer -Quiet
    Set-Content -Path (Get-NotebookMarimoPidFile) -Value $bystander.Id
    Stop-NotebookMarimo -Quiet
    Check "stopping does not touch that program" $false $bystander.HasExited
    Set-Content -Path (Get-NotebookPidFile) -Value $ours.Id
    Stop-NotebookServer 6>$null
    Start-Sleep -Milliseconds 500
    Check "the kit's own server is stopped" $true $ours.HasExited
    Stop-Process -Id $bystander.Id -Force -ErrorAction SilentlyContinue

    Write-Host "the login token is handed to the browser in a file:"
    function Start-Process { param($FilePath) $script:Opened = "$FilePath" }
    Check "the browser is opened" $true (Open-NotebookLoggedIn -Front "jupyter" -Url "http://127.0.0.1:8888/lab?token=abc&x=1")
    Remove-Item Function:\Start-Process
    Check "on the file, not the address" (Get-NotebookOpenFile "jupyter") $script:Opened
    Contains "which forwards to it" "lab?token=abc&amp;x=1" (Get-Content -Raw (Get-NotebookOpenFile "jupyter"))
    Stop-NotebookServer -Quiet
    Check "and goes when the server stops" $false (Test-Path (Get-NotebookOpenFile "jupyter"))

    Write-Host "an uninstall keeps the notebooks:"
    $said = (Uninstall-Notebook 6>&1 | Out-String)
    Check "the notebooks are still there" "mine" (Get-Content -Raw (Join-Path (Join-Path $nb "general") "start_here.ipynb"))
    Check "it does not say JupyterLab is not running" $false ($said -like "*JupyterLab is not running*")

    Write-Host "a full kit uninstall keeps the notebooks:"
    $errors = $null; $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/exakit.ps1"), [ref]$tokens, [ref]$errors)
    foreach ($name in @("Invoke-ExakitUninstallRun", "Test-ExakitSafeUninstallTarget", "Test-ExakitUninstallKeepsNotebooks", "Get-ExakitLogTargets")) {
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        Invoke-Expression $fn.Extent.Text
    }
    function Get-ExakitServiceIds { return @() }
    function Get-ExakitMarketplaceInstalledAddons { return @("notebook") }
    function Get-RuntimeType { return "" }
    function Get-ExakitKitSkillNames { return @() }
    function Get-ExakitSkillRoots { return @() }
    function Remove-ExakitReadonlyAllowlist { return "" }
    function Get-ExakitExapumpProfileDirs { return @() }
    function Remove-ExakitBinariesDeferred { param([string[]]$Paths) }
    function Seed-Kit {
        Initialize-ExakitManifest
        Set-ExakitManifestValue "components.notebook.version" "3.1.0"
        $work2 = Join-Path (Join-Path $script:NotebookDir "my-work") "mlflow"
        New-Item -ItemType Directory -Force -Path $work2 | Out-Null
        Set-Content -Path (Join-Path $work2 "mlflow.db") -Value "runs" -NoNewline
        New-Item -ItemType Directory -Force -Path (Join-Path $script:ExakitHome "logs") | Out-Null
    }
    Seed-Kit
    $said = (Invoke-ExakitUninstallRun -DryRun 6>&1 | Out-String)
    Contains "the dry run says the notebooks stay" "your notebooks stay in $(Join-Path $script:ExakitHome 'notebooks')" $said
    Check "the dry run removes nothing" $true (Test-Path $script:ManifestPath)
    $said = (Invoke-ExakitUninstallRun 6>&1 | Out-String)
    Check "the user's notebook and MLflow store are still there" "mine|runs" `
        "$(Get-Content -Raw (Join-Path (Join-Path $nb 'general') 'start_here.ipynb'))|$(Get-Content -Raw (Join-Path (Join-Path (Join-Path $script:NotebookDir 'my-work') 'mlflow') 'mlflow.db'))"
    Check "everything else in the kit home is gone" "notebooks" ((@(Get-ChildItem -Force -LiteralPath $script:ExakitHome) | ForEach-Object { $_.Name }) -join " ")
    Check "a home holding only kept notebooks is still a kit home to the guard" $true (Test-ExakitSafeUninstallTarget $script:ExakitHome)
    Seed-Kit
    $env:EXAKIT_UNINSTALL_NOTEBOOKS = "remove"
    try {
        $said = (Invoke-ExakitUninstallRun -DryRun 6>&1 | Out-String)
        Contains "EXAKIT_UNINSTALL_NOTEBOOKS=remove: the dry run says they go" "will remove: your notebooks in $($script:NotebookDir)" $said
        [void](Invoke-ExakitUninstallRun 6>&1)
        Check "and the real run removes the whole kit home" $false (Test-Path $script:ExakitHome)
    } finally { Remove-Item Env:EXAKIT_UNINSTALL_NOTEBOOKS -ErrorAction SilentlyContinue }

    Write-Host "the log listing reads an add-on's several logs:"
    function Get-ExakitMarketplaceAddon { param($Id) return [pscustomobject]@{ Id = $Id; LogFn = "Get-NotebookLogPath" } }
    $script:LogDir = Join-Path $work "logs"
    $targets = @(Get-ExakitLogTargets)
    Check "notebook and notebook-marimo" "notebook,notebook-marimo" (($targets | ForEach-Object { $_.Id }) -join ",")
    Check "with their files" (Get-NotebookMarimoLogFile) $targets[1].Source

    Write-Host "a server that could not be started makes the command exit 1, as on the shell side:"
    function Get-NotebookInstalledVersion { return "3.1.0" }
    function Test-ExakitDbReachable { return $true }
    function Write-NotebookConnection { return "same" }
    function Register-NotebookKernel { return $true }
    function Write-NotebookCopied { param($Folder, $Front) }
    function Confirm-NotebookJupyter { return $true }
    function Get-NotebookServerState { return "stopped" }
    function Start-NotebookServer { param($Port) return $false }
    function Start-NotebookMarimo { param($Port) return $false }
    function Get-NotebookMarimoState { return "stopped" }
    New-Item -ItemType File -Force -Path (Get-NotebookMarimoCommand) | Out-Null
    $script:PendingExitCode = 0
    Invoke-CmdNotebook -CmdArgs @("--no-browser")
    Check "JupyterLab" 1 $script:PendingExitCode
    $script:PendingExitCode = 0
    Invoke-CmdNotebook -CmdArgs @("--marimo", "--no-browser")
    Check "Marimo" 1 $script:PendingExitCode
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "notebook-addon-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
