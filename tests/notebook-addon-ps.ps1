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
    Check "the connector, pinned, with its extras (notebook-dependencies: ipywidgets, ipyfilechooser, matplotlib, wordcloud, stopwatch.py - the AI Lab notebooks' first cell)" "exasol-notebook-connector[bucketfs,ibis,pyexasol,sqlalchemy,notebook-dependencies]==3.1.0" $specs[0]
    Contains "the kernel package" "ipykernel>=6.29,<8" ($specs -join " ")
    Contains "the MLflow client, not the server" "mlflow-skinny>=3,<4" ($specs -join " ")
    Contains "Langfuse SDK major 5" "langfuse>=5,<6" ($specs -join " ")
    Check "the kit's helper package" (Join-Path (Join-Path $repo "notebook") "package") $specs[-2]
    Check "the kit's MLflow client package" (Join-Path (Join-Path $repo "packages") "exasol-mlflow") $specs[-1]
    Check "JupyterLab is not in it" 0 @($specs | Where-Object { $_ -match "jupyterlab" }).Count
    Check "Marimo is not in it" 0 @($specs | Where-Object { $_ -match "marimo" }).Count

    Write-Host "the front ends are pinned in versions.json and join the one resolution:"
    $versions = Get-Content -Raw (Join-Path $repo "versions.json") | ConvertFrom-Json
    $pinJ = $versions.components.notebook.frontends.jupyterlab
    $pinM = $versions.components.notebook.frontends.marimo
    Check "the JupyterLab pin is read from versions.json" $pinJ (Get-NotebookFrontendPin "jupyterlab")
    Check "the Marimo pin is read from versions.json" $pinM (Get-NotebookFrontendPin "marimo")
    $env:EXAKIT_NOTEBOOK_MARIMO_VERSION = "0.26.1"
    Check "EXAKIT_NOTEBOOK_MARIMO_VERSION outranks the pin" "0.26.1" (Get-NotebookFrontendPin "marimo")
    $env:EXAKIT_NOTEBOOK_MARIMO_VERSION = "1; rm"
    Check "a pin outside the safe charset is no pin" $null (Get-NotebookFrontendPin "marimo")
    Remove-Item Env:EXAKIT_NOTEBOOK_MARIMO_VERSION
    $script:NotebookAddJupyterLab = $true
    $specs = @(Get-NotebookSpecs)
    $script:NotebookAddJupyterLab = $false
    Check "JupyterLab ticked: the connector's jupyter extra, no separate spec" "exasol-notebook-connector[bucketfs,ibis,pyexasol,sqlalchemy,notebook-dependencies,jupyter]==3.1.0" $specs[0]
    Check "and its version held by the pin" "jupyterlab==$pinJ" (@($specs | Where-Object { $_ -like "jupyterlab*" }) -join ",")
    $script:NotebookAddMarimo = $true
    Check "Marimo ticked: marimo at its pin" "marimo==$pinM" (@(Get-NotebookSpecs | Where-Object { $_ -like "marimo*" }) -join ",")
    $script:NotebookAddMarimo = $false
    $converts = & python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import notebooks; print(notebooks.marimo_pin())" (Join-Path $repo "tools")
    Check "tools/notebooks.py converts with the Marimo the add-on installs" "marimo==$(Get-NotebookFrontendPin 'marimo')" "$converts"
    $realFind = ${function:Find-NotebookJupyter}
    function Find-NotebookJupyter { return $null }
    Set-NotebookFrontEndPlan "jupyterlab,marimo"
    Check "ticked tools, no JupyterLab of the user's: the kit brings both" "True True" "$($script:NotebookAddJupyterLab) $($script:NotebookAddMarimo)"
    function Find-NotebookJupyter { return ,@("own", "C:\Python\Scripts\jupyter-lab.exe") }
    Set-NotebookFrontEndPlan "jupyterlab,positron"
    Check "the user's own JupyterLab is used, not installed" "False False" "$($script:NotebookAddJupyterLab) $($script:NotebookAddMarimo)"
    Set-Item -Path Function:\Find-NotebookJupyter -Value $realFind
    $script:NotebookAddJupyterLab = $false; $script:NotebookAddMarimo = $false

    Write-Host "notebooks are copied once, into persona folders, never over the user's:"
    $nb = Join-Path $script:NotebookDir "starter-kit-notebooks"
    New-Item -ItemType Directory -Force -Path (Join-Path $nb "data-scientist") | Out-Null
    Set-Content -Path (Join-Path (Join-Path $nb "data-scientist") "00_quickstart.ipynb") -Value "mine" -NoNewline
    Check "what is missing comes, each in its persona's folder, the shared cells too" `
        "00_shared/data_paths.ipynb,data-scientist/01_explore.ipynb,data-scientist/02_ask_your_data.ipynb,data-scientist/03_share.ipynb,ml-engineer/00_quickstart.ipynb,ml-engineer/01_train.ipynb,ml-engineer/02_rust_score.ipynb,ml-engineer/03_score_external_model.ipynb,useful-notebooks/data-scientist/01_sql_and_dataframes.ipynb,useful-notebooks/data-scientist/02_decision_tree_baseline.ipynb,useful-notebooks/ml-engineer/01_udf_package_check.ipynb,useful-notebooks/ml-engineer/02_decision_tree_udf.ipynb,exasol-examples,EXAMPLE-GUIDE.md,UPSTREAM-LICENSE.txt,INSTALL-AND-UPDATE.md" `
        (@(Copy-NotebookContent) -join ",")
    Check "the user's own stays" "mine" (Get-Content -Raw (Join-Path (Join-Path $nb "data-scientist") "00_quickstart.ipynb"))
    Check "a second run adds nothing" 0 @(Copy-NotebookContent).Count
    Contains "a README names each persona's order" "00. ``ml-engineer/00_quickstart.ipynb`` - Quickstart" (Get-Content -Raw (Join-Path $nb "README.md"))
    Check "the Marimo ones go to marimo/<persona>/" "00_shared/data_paths.py,data-scientist/00_quickstart.py,data-scientist/01_explore.py,data-scientist/02_ask_your_data.py,data-scientist/03_share.py,ml-engineer/00_quickstart.py,ml-engineer/01_train.py,ml-engineer/02_rust_score.py,ml-engineer/03_score_external_model.py,useful-notebooks/data-scientist/01_sql_and_dataframes.py,useful-notebooks/data-scientist/02_decision_tree_baseline.py,useful-notebooks/ml-engineer/01_udf_package_check.py,useful-notebooks/ml-engineer/02_decision_tree_udf.py,exasol-examples,EXAMPLE-GUIDE.md,UPSTREAM-LICENSE.txt,INSTALL-AND-UPDATE.md" `
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
    foreach ($bad in @(@("--frob"), @("--port"), @("--port", "abc"), @("--port", "80"), @("--marimo", "--positron"), @("marimo", "positron"), @("jupyterlab", "marimo"), @("Marimo"))) {
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

    $dirtyKit = Join-Path $work "dirty-kit"
    $buildA = Join-Path $dirtyKit "notebook/package/build"
    $buildB = Join-Path $dirtyKit "packages/exasol-mlflow/build"
    New-Item -ItemType Directory -Force -Path $buildA, $buildB | Out-Null
    $currentSource = Join-Path $dirtyKit "packages/exasol-mlflow/current.py"
    Set-Content -Path $currentSource -Value "current helper" -NoNewline
    $cleaned = & {
        function Get-ExakitRepoRoot { return $dirtyKit }
        function Get-NotebookSpecs { return @("local-package") }
        function Get-NotebookFrontendsInstalled { return @{} }
        function Invoke-ExakitLogged { param($Cmd, [Parameter(ValueFromRemainingArguments)]$Rest)
            if ((Test-Path $buildA) -or (Test-Path $buildB)) { return 1 }; return 0
        }
        Sync-NotebookPackages
    }
    Check "a local checkout's stale build output is removed before packaging" $true $cleaned
    Check "current package source is kept" "current helper" (Get-Content -Raw $currentSource)

    Write-Host "a front end the kit installed follows its pin through an update:"
    $scriptsDir = Join-Path $script:NotebookVenv "Scripts"
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
    New-Item -ItemType File -Force -Path (Get-NotebookMarimoCommand) | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $scriptsDir "jupyter-lab.exe") | Out-Null
    $real = @{}
    foreach ($fn in @("Get-ExakitComponentAvailable", "Get-NotebookInstalledVersion", "Copy-NotebookContent", "Register-NotebookKernel", "Test-Notebook")) {
        $real[$fn] = (Get-Item "Function:\$fn").ScriptBlock
    }
    function Get-ExakitComponentAvailable { param($Component) return "3.1.0" }
    function Get-NotebookInstalledVersion { return "3.1.0" }
    function Copy-NotebookContent { param($Front) return @() }
    function Register-NotebookKernel { return $true }
    function Test-Notebook { }
    Update-Notebook 6>$null
    $logged = $script:LoggedArgs -join " "
    Contains "the update's resolution keeps Marimo at the versions.json pin" "marimo==$pinM" $logged
    Contains "and JupyterLab, through the connector's extra" "sqlalchemy,notebook-dependencies,jupyter]==3.1.0" $logged
    Contains "at its pin" "jupyterlab==$pinJ" $logged
    $env:EXAKIT_NOTEBOOK_MARIMO_VERSION = "0.26.1"
    try { Update-Notebook 6>$null } finally { Remove-Item Env:EXAKIT_NOTEBOOK_MARIMO_VERSION }
    $logged = $script:LoggedArgs -join " "
    Check "a changed Marimo pin is what the update installs" "True|False" "$($logged.Contains('marimo==0.26.1'))|$($logged.Contains("marimo==$pinM"))"
    Remove-Item -Force (Get-NotebookMarimoCommand), (Join-Path $scriptsDir "jupyter-lab.exe")
    Update-Notebook 6>$null
    $logged = $script:LoggedArgs -join " "
    Check "a front end the kit did not install stays out" "False|False" "$($logged.Contains('marimo'))|$($logged.Contains('jupyter'))"
    foreach ($fn in @($real.Keys)) { Set-Item -Path "Function:\$fn" -Value $real[$fn] }

    Write-Host "exakit logs notebook: two targets:"
    $logs = @(Get-NotebookLogPath)
    Check "JupyterLab's log" "notebook|JupyterLab (exakit notebook)|$(Get-NotebookLogFile)" $logs[0]
    Check "Marimo's log" "notebook-marimo|Marimo (notebook marimo)|$(Get-NotebookMarimoLogFile)" $logs[1]

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
    Check "the notebooks are still there" "mine" (Get-Content -Raw (Join-Path (Join-Path $nb "data-scientist") "00_quickstart.ipynb"))
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
        Set-ExakitComponentOwnership "notebook" "kit"
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
        "$(Get-Content -Raw (Join-Path (Join-Path $nb 'data-scientist') '00_quickstart.ipynb'))|$(Get-Content -Raw (Join-Path (Join-Path (Join-Path $script:NotebookDir 'my-work') 'mlflow') 'mlflow.db'))"
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

    Write-Host "the connection is re-read on every launch: a changed database port reaches the store (AC-DS1.5):"
    # The launch path (Invoke-NotebookPreflight, what exakit notebook runs before
    # any server starts) writes the kit's recorded connection into the
    # connector's store every time. The manifest's runtime.dsn changes between
    # two launches - a database moved to another port - and write_store.py,
    # stubbed, records the host:port it was handed. No database, no real store.
    Initialize-ExakitManifest
    Set-ExakitManifestValue "runtime.user" "sys"
    Set-ExakitManifestValue "runtime.password_file" (Join-Path $work "pw")
    New-Item -ItemType Directory -Force -Path (Join-Path $script:NotebookDir "starter-kit-notebooks") | Out-Null
    $script:StoreWrites = @()
    $script:StoreAnswer = "same"
    $realInvokePy = ${function:Invoke-NotebookPy}
    function Invoke-NotebookPy {
        param([Parameter(Mandatory)][string]$Script, [hashtable]$Env = @{})
        $script:StoreWrites += "$Script $($Env.EXAKIT_NB_HOST):$($Env.EXAKIT_NB_PORT)"
        $script:StoreSchema = $Env.EXAKIT_NB_SCHEMA
        return ,@(0, @($script:StoreAnswer))
    }
    function Get-NotebookEnvState { return "ok" }
    function Test-NotebookOnTerminal { return $false }
    function Test-ExakitDbReachable { return $true }
    function Register-NotebookKernel { return $true }
    function Write-NotebookCopied { param($Folder, $Front) }
    Set-ExakitManifestValue "runtime.dsn" "127.0.0.1:8563"
    $said = (Invoke-NotebookPreflight 6>&1 | Out-String)
    Check "the first launch runs through" $true ($said -like "*True*")
    Check "and hands the store the recorded port" "write_store.py 127.0.0.1:8563" ($script:StoreWrites -join ",")
    Set-ExakitManifestValue "runtime.dsn" "127.0.0.1:8564"
    $script:StoreAnswer = "changed"
    $said = (Invoke-NotebookPreflight 6>&1 | Out-String)
    Check "the next launch runs through too" $true ($said -like "*True*")
    Check "the store is written again, now with the new port: nothing is cached between launches" `
        "write_store.py 127.0.0.1:8563,write_store.py 127.0.0.1:8564" ($script:StoreWrites -join ",")
    Contains "and the launch says the notebooks use the new connection" "The database connection changed; the notebooks now use the new one" $said
    $master = Get-Content -Raw (Join-Path $script:CredsDir $script:NotebookMasterCred)
    Check "the master password is in no argument the launcher records" $false (($script:StoreWrites -join ",").Contains($master.Trim()))
    # The store's schema: the connector's jupysql.init reads db_schema, so the
    # write carries one - the kit's STARTER_KIT, or EXAKIT_NOTEBOOK_SCHEMA.
    Check "the store write carries the kit's schema, STARTER_KIT, by default" "STARTER_KIT" $script:StoreSchema
    $script:NotebookSchema = "MY_SCHEMA"
    $said = (Invoke-NotebookPreflight 6>&1 | Out-String)
    Check "a launch with EXAKIT_NOTEBOOK_SCHEMA runs through" $true ($said -like "*True*")
    Check "and hands the store that schema" "MY_SCHEMA" $script:StoreSchema
    $script:NotebookSchema = "STARTER_KIT"
    Set-Item -Path Function:\Invoke-NotebookPy -Value $realInvokePy
    Remove-ExakitManifestValue "runtime"

    Write-Host "a server that could not be started makes the command exit 1, as on the shell side:"
    function Get-NotebookInstalledVersion { return "3.1.0" }
    Initialize-ExakitManifest
    Set-ExakitManifestValue "components.notebook.version" "3.1.0"
    # The launcher's own checks are tests/notebook-launcher-ps.ps1's: here the
    # environment imports, nobody is at a console and every port is free.
    function Get-NotebookEnvState { return "ok" }
    function Test-NotebookOnTerminal { return $false }
    function Test-NotebookPortInUse { param($Port) return $false }
    function Confirm-NotebookJupyterReady { param($Setup) return 0 }
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
