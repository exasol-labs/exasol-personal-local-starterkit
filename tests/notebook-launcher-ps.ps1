#!/usr/bin/env pwsh
# notebook-launcher-ps.ps1 - the Windows twin of tests/notebook-launcher.sh:
# `exakit notebook` as a launcher in setup/lib/notebook.ps1 - what it checks
# before it opens anything, the "Open which notebook tools?" multi-select, and
# the edge cases (the database down, a tool or the environment deleted, a port
# taken, the notebooks folder or the connection store gone, a stale pid file,
# no browser, a tool already running). Runs under Windows PowerShell 5.1 and
# pwsh. The launcher's own code runs; the database, the servers, the browser,
# Positron, the installs and the questions are stubbed (they record what was
# asked and answer from $script:T). A sandboxed kit home; no database, no
# network, no real server.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-nblaunch-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
foreach ($v in @("EXAKIT_NOTEBOOK_VENV", "EXAKIT_NOTEBOOK_HOME", "EXAKIT_NOTEBOOK_DIR", "EXAKIT_MARIMO_PORT", "EXAKIT_NOTEBOOK_JUPYTER",
                 "EXAKIT_NOTEBOOK_MARIMO", "EXAKIT_NOTEBOOK_FRONTENDS", "EXAKIT_NOTEBOOK_PORT_TRIES")) {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}
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
function Lacks($label, $needle, $haystack) {
    if (-not "$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> found in <$haystack>" }
}
# Fail ends the run in the real CLI; here it throws so a refusal is observable.
function Fail([string]$Msg) { throw "FAIL: $Msg" }

$onWindows = ($env:OS -eq "Windows_NT")
$scripts = Join-Path $script:NotebookVenv "Scripts"
$importsOk = Join-Path $work "imports-ok"
$dbUp = Join-Path $work "db-up"
$jState = Join-Path $work "jstate"
$mState = Join-Path $work "mstate"
$python3 = (Get-Command python3 -ErrorAction SilentlyContinue)
if (-not $python3) { $python3 = Get-Command python }
$python3 = $python3.Source
$ownBin = Join-Path $work "ownbin"
New-Item -ItemType Directory -Force -Path $ownBin | Out-Null
$env:PATH = $ownBin + [System.IO.Path]::PathSeparator + $env:PATH
# A JupyterLab of the machine's own outside the sandbox would answer the
# "missing" checks; they are skipped (and said) then.
$systemJupyter = Get-Command jupyter-lab -ErrorAction SilentlyContinue

function New-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
    return "$p"
}
# The venv's Python: on Windows a copy of one real venv made once (a venv's
# python.exe is a launcher that reads its pyvenv.cfg, so a copy runs; its
# packages do not import, so the state checks below answer from the flag
# file); elsewhere a script whose import check answers from that flag file and
# which runs python3 for the rest (notebooks.py).
$template = Join-Path $work "template-venv"
function New-FakeVenv {
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    $py = Get-NotebookVenvPython
    # Removed first: a write follows a symlink to a real interpreter.
    Remove-Item -Force -ErrorAction SilentlyContinue $py
    if ($onWindows) {
        if (-not (Test-Path $template)) { & $python3 -m venv --without-pip $template | Out-Null }
        Copy-Item -Recurse -Force (Join-Path $template "*") $script:NotebookVenv
    } else {
        Set-Content -Path $py -Encoding Ascii -Value "#!/bin/sh`ncase `"`$*`" in *`"import exasol.nb_connector`"*) [ -f '$importsOk' ] && exit 0; exit 1 ;; esac`nexec '$python3' `"`$@`""
        & chmod +x $py
        New-Item -ItemType File -Force -Path (Join-Path $script:NotebookVenv "pyvenv.cfg") | Out-Null
    }
}
function New-Tool([string]$Name) {
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $scripts "$Name.exe") | Out-Null
}
function Reset-Kit([string]$FrontEnds = "", [switch]$Jupyter, [switch]$Marimo) {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $script:ExakitHome
    foreach ($f in @($importsOk, $dbUp, $jState, $mState, (Join-Path $ownBin "jupyter-lab"), (Join-Path $ownBin "jupyter-lab.cmd"))) {
        Remove-Item -Force -ErrorAction SilentlyContinue $f
    }
    New-Item -ItemType Directory -Force -Path $script:ExakitHome | Out-Null
    Initialize-ExakitManifest
    Set-Content -Path (Join-Path $work "pw") -Value "pw" -NoNewline
    Set-ExakitManifestValue "runtime.dsn" "db.test:8563"
    Set-ExakitManifestValue "runtime.password_file" (Join-Path $work "pw")
    Set-ExakitManifestValue "components.notebook.version" "3.1.0"
    if ($FrontEnds) { Set-ExakitManifestValue "components.notebook.front_ends" $FrontEnds }
    Set-ExakitManifestValue "components.notebook.port" (New-FreePort)
    Set-ExakitManifestValue "components.notebook.marimo_port" (New-FreePort)
    New-FakeVenv
    if ($Jupyter) { New-Tool "jupyter-lab" }
    if ($Marimo) { New-Tool "marimo" }
    New-Item -ItemType File -Force -Path $importsOk | Out-Null
    New-Item -ItemType File -Force -Path $dbUp | Out-Null
    $script:Calls = @()
}

# --- the stubs: everything that would reach outside the kit home --------------
$script:T = @{}
$script:Calls = @()
function Get-NotebookEnvState {
    if ($script:T.Env) { return $script:T.Env }
    if (-not (Test-Path (Get-NotebookVenvPython))) { return "missing" }
    if (Test-Path $importsOk) { return "ok" }
    return "broken"
}
function Test-NotebookOnTerminal { return [bool]$script:T.Terminal }
function Confirm-ExakitPrompt {
    param([string]$Question, [bool]$DefaultYes = $true)
    $script:Calls += "confirm:$Question"
    if ($script:T.Answer) { return ($script:T.Answer -eq "y") }
    return $DefaultYes
}
function Read-ExakitCheckboxMenu {
    param([string]$Title, [string[]]$Options, [int[]]$Defaults = @(), [int]$ExclusiveIndex = 0)
    $script:Calls += "menu:$Title|defaults=$($Defaults -join ',')|exclusive=$ExclusiveIndex|$($Options -join '|')"
    if ($script:T.Pick) { return @($script:T.Pick) }
    return $Defaults
}
function Test-ExakitDbReachable { return (Test-Path $dbUp) }
function Clear-ExakitDbReachable { }
function Initialize-ExakitLogging { }
function Start-ExakitDatabase {
    $script:Calls += "start-db"
    if (-not $script:T.StartFails) { New-Item -ItemType File -Force -Path $dbUp | Out-Null }
}
function Invoke-NotebookPy {
    param([string]$Script, [hashtable]$Env = @{})
    if ($Script -eq "write_store.py") {
        $script:Calls += "store"
        if ($script:T.StoreFails) { return ,@(1, @()) }
        if ((Test-Path $Env.SCS_FILE) -and ((Get-Content -Raw $Env.SCS_FILE) -like "*OLD*")) { return ,@(1, @()) }
        Set-Content -Path $Env.SCS_FILE -Value "NEW" -NoNewline
        return ,@(0, @("same"))
    }
    if ($Script -eq "register_kernel.py") { $script:Calls += "kernel"; return ,@(0, @()) }
    if ($Script -eq "check_connection.py") {
        $script:Calls += "connected"
        if ($script:T.ConnectFails) { return ,@(1, @()) }
        return ,@(0, @())
    }
    return ,@(1, @())
}
function Get-NotebookServerState { if (Test-Path $jState) { return "running" } else { return "stopped" } }
function Start-NotebookServer {
    param([string]$Port)
    $script:Calls += "jstart:$Port"
    New-Item -ItemType File -Force -Path $jState | Out-Null
    Set-ExakitManifestValue "components.notebook.port" $Port
    return $true
}
function Get-NotebookMarimoState {
    if (-not (Test-Path (Get-NotebookMarimoCommand))) { return "not installed" }
    if (Test-Path $mState) { return "running" }
    return "stopped"
}
function Start-NotebookMarimo {
    param([string]$Port)
    $script:Calls += "mstart:$Port"
    New-Item -ItemType File -Force -Path $mState | Out-Null
    Set-ExakitManifestValue "components.notebook.marimo_port" $Port
    return $true
}
# The browser and Positron are both opened with Start-Process.
function Start-Process {
    param([string]$FilePath, $ArgumentList)
    $script:Calls += "open:$FilePath"
    if ($script:T.NoBrowser -and $FilePath -like "*.html") { throw "no browser" }
}
function Find-NotebookPositron { if ($script:T.Positron) { return "/Applications/Positron.app" } else { return $null } }
function Sync-NotebookPackages {
    $script:Calls += "sync:J=$([int]$script:NotebookAddJupyterLab):M=$([int]$script:NotebookAddMarimo)"
    if ($script:T.SyncFails) { return $false }
    if ($script:NotebookAddJupyterLab) { New-Tool "jupyter-lab" }
    if ($script:NotebookAddMarimo) { New-Tool "marimo" }
    return $true
}
function Get-NotebookFrontendsInstalled {
    if (Test-Path (Join-Path $scripts "jupyter-lab.exe")) { return @{ jupyterlab = "4.4.9" } }
    return @{}
}
function Install-Notebook {
    $script:Calls += "install:$($script:NotebookVersion):$($env:EXAKIT_FORCE_COMPONENT_INSTALL)"
    if ($script:T.InstallFails) { return $false }
    New-FakeVenv; New-Tool "jupyter-lab"
    New-Item -ItemType File -Force -Path $importsOk | Out-Null
    return $true
}

# Invoke-Run <answers> <args> - Invoke-CmdNotebook with the answers in
# $script:T; sets $script:Out (what it said), $script:Rc (0, or 1 for a
# failure or a refusal) and $script:Did (the calls, one per line).
function Invoke-Run([hashtable]$Answers, [string[]]$CmdArgs = @()) {
    $script:T = $Answers
    $script:Calls = @()
    $script:PendingExitCode = 0
    $script:Rc = 0
    try {
        $script:Out = (Invoke-CmdNotebook -CmdArgs $CmdArgs 6>&1 | Out-String)
        if ($script:PendingExitCode -ne 0) { $script:Rc = 1 }
    } catch {
        $script:Out = "$_"
        $script:Rc = 1
    }
    $script:Did = ($script:Calls -join "`n")
    $script:T = @{}
}
# Use-RealFunction <name> - the shipped definition back in place of a stub;
# returns the stub, for Set-Item to put back.
function Use-RealFunction([string]$Name) {
    $stub = (Get-Item "Function:\$Name").ScriptBlock
    $errs = $null; $toks = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/lib/notebook.ps1"), [ref]$toks, [ref]$errs)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    $body = $fn.Body.Extent.Text
    Set-Item -Path "Function:\script:$Name" -Value ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
    return $stub
}
function Get-MenuLine { return "$(@($script:Calls | Where-Object { $_ -like 'menu:*' }) | Select-Object -First 1)" }
function Get-Count([string]$Like) { return @($script:Calls | Where-Object { $_ -like $Like }).Count }

try {
    Write-Host "the menu, on a console:"
    Reset-Kit "jupyterlab,marimo,positron" -Jupyter -Marimo
    Invoke-Run @{ Terminal = $true; Positron = $true; Pick = @(4) }
    Contains "titled 'Open which notebook tools?'" "menu:Open which notebook tools?|" (Get-MenuLine)
    Contains "JupyterLab: ready, the kit's, its version" "|JupyterLab - ready (the kit's 4.4.9)|" (Get-MenuLine)
    Contains "Marimo: ready" "|Marimo - ready|" (Get-MenuLine)
    Contains "Positron: found" "|Positron - found - opens on the notebooks folder|" (Get-MenuLine)
    Contains "Skip is the last row" "|Skip - open nothing" (Get-MenuLine)
    Contains "...and the exclusive one" "exclusive=4" (Get-MenuLine)
    Contains "the recorded tools are ticked" "defaults=1,2,3" (Get-MenuLine)
    Check "Skip opens nothing" "0|0" "$($script:Rc)|$(Get-Count 'jstart:*')"
    Contains "...and says so" "Nothing opened" $script:Out

    Invoke-Run @{ Terminal = $true; Pick = @(1, 2) }
    Check "two picked: both started" 2 ((Get-Count "jstart:*") + (Get-Count "mstart:*"))
    Check "...both opened logged in" "open:$(Get-NotebookOpenFile 'jupyter')|open:$(Get-NotebookOpenFile 'marimo')" (@($script:Calls | Where-Object { $_ -like "open:*" }) -join "|")
    Contains "one line for JupyterLab, with its address" "JupyterLab is running: http://127.0.0.1:$(Get-ExakitManifestValue 'components.notebook.port')/lab" $script:Out
    Contains "one line for Marimo, with its address" "Marimo is running: http://127.0.0.1:$(Get-ExakitManifestValue 'components.notebook.marimo_port')/" $script:Out
    Contains "then one line naming how to stop them" "To stop JupyterLab and Marimo: exakit notebook stop" $script:Out
    Lacks "...not one per tool" "(stop it with" $script:Out
    Check "exit 0" 0 $script:Rc

    Write-Host "the menu's states:"
    Reset-Kit "jupyterlab,marimo,positron" -Jupyter -Marimo
    New-Item -ItemType File -Force -Path $jState, $mState | Out-Null
    Invoke-Run @{ Terminal = $true; Pick = @(4) }
    Contains "JupyterLab running: its address" "|JupyterLab - running at http://127.0.0.1:$(Get-ExakitManifestValue 'components.notebook.port')/lab|" (Get-MenuLine)
    Contains "Marimo running: its address" "|Marimo - running at http://127.0.0.1:$(Get-ExakitManifestValue 'components.notebook.marimo_port')/|" (Get-MenuLine)
    Contains "Positron not here: a disabled row saying where to get it" "|!Positron - not on this machine (get it at positron.posit.co)|" (Get-MenuLine)
    Contains "...and not ticked although it is recorded" "defaults=1,2|" (Get-MenuLine)
    if (-not $systemJupyter) {
        Reset-Kit "jupyterlab,marimo"
        Invoke-Run @{ Terminal = $true; Pick = @(4) }
        Contains "JupyterLab removed: missing, reinstall it" "|JupyterLab - missing - reinstall it into the kit's environment|" (Get-MenuLine)
        Contains "Marimo removed: missing, reinstall it" "|Marimo - missing - reinstall it into the kit's environment|" (Get-MenuLine)
        Contains "missing tools stay ticked" "defaults=1,2|" (Get-MenuLine)
        Reset-Kit ""
        Invoke-Run @{ Terminal = $true; Pick = @(4) }
        Contains "never set up: not installed, installs it" "|JupyterLab - not installed - installs it into the kit's environment|" (Get-MenuLine)
        Contains "Marimo never set up" "|Marimo - not installed - installs it|" (Get-MenuLine)
        Contains "nothing recorded: JupyterLab ticked" "defaults=1|" (Get-MenuLine)
    } else {
        Write-Host "  (a jupyter-lab outside the sandbox is on PATH: the 'missing' rows are checked on the shell side)"
    }
    Check "the labels are the shell twin's" "JupyterLab - ready (yours: X)" (Get-NotebookMenuLabels -Jupyter "own X" -Marimo "none" -Positron $false)[0]
    $defaults = @()
    foreach ($case in @(@("jupyterlab,marimo,positron", $true), @("jupyterlab,marimo,positron", $false), @("positron", $false), @("marimo", $true), @("none", $true))) {
        Set-ExakitManifestValue "components.notebook.front_ends" $case[0]
        $defaults += ((Get-NotebookMenuDefaults -Positron $case[1]) -join ",")
    }
    Check "the defaults: the record, Positron only when it is here, else JupyterLab" "1,2,3|1,2|1|2|1" ($defaults -join "|")

    Write-Host "without a console nothing is asked:"
    Reset-Kit "jupyterlab,marimo,positron" -Jupyter -Marimo
    Invoke-Run @{}
    Check "plain exakit notebook opens JupyterLab, as it always did" "0|1" "$($script:Rc)|$(Get-Count 'jstart:*')"
    Check "...asking nothing" 0 ((Get-Count "menu:*") + (Get-Count "confirm:*"))
    Contains "...with its stop line" "(stop it with: exakit notebook stop)" $script:Out
    Remove-Item -Force $jState
    Invoke-Run @{ Terminal = $true } @("--port", (New-FreePort))
    Check "--port on a console is JupyterLab's port: no menu" "0|1" "$(Get-Count 'menu:*')|$(Get-Count 'jstart:*')"
    Invoke-Run @{ Terminal = $true } @("--marimo", "--no-browser")
    Check "--marimo on a console: Marimo, no menu, no browser" "0|1|0" "$(Get-Count 'menu:*')|$(Get-Count 'mstart:*')|$(Get-Count 'open:*')"
    Invoke-Run @{ Terminal = $true } @("--stop")
    Check "--stop: no menu, no checks" "" $script:Did
    foreach ($f in @($jState, $mState)) { if (Test-Path $f) { Remove-Item -Force $f } }
    Invoke-Run @{ Terminal = $true } @("marimo", "--no-browser")
    Check "the word form, marimo: Marimo, no menu" "0|1" "$(Get-Count 'menu:*')|$(Get-Count 'mstart:*')"
    Invoke-Run @{ Terminal = $true } @("stop")
    Check "...stop as a word: no menu, no checks" "" $script:Did
    if (Test-Path $jState) { Remove-Item -Force $jState }
    Invoke-Run @{ Terminal = $true } @("jupyterlab", "--no-browser")
    Check "jupyterlab on a console: JupyterLab, no menu" "0|1" "$(Get-Count 'menu:*')|$(Get-Count 'jstart:*')"
    Invoke-Run @{ Terminal = $true } @("stop")

    Write-Host "a. the database is not running, or the connection was lost:"
    Reset-Kit "jupyterlab" -Jupyter
    Remove-Item -Force $dbUp
    Invoke-Run @{}
    Check "no console: not started, nothing opened, a failure" "1|0" "$($script:Rc)|$((Get-Count 'start-db') + (Get-Count 'jstart:*') + (Get-Count 'confirm:*'))"
    Contains "...naming the command" "Start it with: exakit start" $script:Out
    Invoke-Run @{ Terminal = $true; Pick = @(1) }
    Contains "on a console: said" "The database is not running, or the connection to it was lost" $script:Out
    Contains "...and offered" "confirm:Start the database now?" $script:Did
    Check "a yes starts it the way exakit start does, then the store, the connection, the tools" "start-db store connected kernel jstart" `
        ((@($script:Calls | Where-Object { $_ -match '^(start-db|store|connected|kernel|jstart)' }) | ForEach-Object { ($_ -split ':')[0] }) -join " ")
    Remove-Item -Force $dbUp, $jState
    Invoke-Run @{ Terminal = $true; Answer = "n" }
    Check "a no: nothing opened, a failure" "1|0" "$($script:Rc)|$((Get-Count 'start-db') + (Get-Count 'jstart:*'))"
    Contains "...naming the command" "Start it with: exakit start - then: exakit notebook" $script:Out
    Invoke-Run @{ Terminal = $true; StartFails = $true }
    Check "a start that does not bring it up: nothing opened" "1|0" "$($script:Rc)|$(Get-Count 'jstart:*')"
    Contains "...pointing at exakit status and exakit logs" "see: exakit status   (and its log: exakit logs)" $script:Out
    Invoke-Run @{ Terminal = $true; ConnectFails = $true }
    Check "up, but the notebooks still cannot connect: nothing opened" "1|0" "$($script:Rc)|$(Get-Count 'jstart:*')"
    Contains "...said" "the notebooks cannot connect to it, so nothing was opened - see: exakit status" $script:Out

    if (-not $systemJupyter) {
        Write-Host "b. JupyterLab deleted:"
        Reset-Kit "jupyterlab"
        Invoke-Run @{}
        Check "no console: nothing installed, nothing opened, a failure" "1|0" "$($script:Rc)|$((Get-Count 'sync:*') + (Get-Count 'jstart:*') + (Get-Count 'confirm:*'))"
        Contains "...one line naming the fix" "there is nothing to open the notebooks in. Install it with: exakit notebook setup" $script:Out
        Invoke-Run @{ Terminal = $true; Pick = @(1) }
        Contains "picked: a reinstall is offered" "confirm:Reinstall JupyterLab $(Get-NotebookFrontendPin 'jupyterlab') into the kit's notebook environment" $script:Did
        Check "...a yes installs the kit's and opens it" "1|1" "$(Get-Count 'sync:J=1:M=0')|$(Get-Count 'jstart:*')"
        Reset-Kit "jupyterlab"
        Invoke-Run @{ Terminal = $true; Pick = @(1); Answer = "n" }
        Check "...a no: nothing installed, nothing opened, not a failure" "0|0|0" "$($script:Rc)|$(Get-Count 'sync:*')|$(Get-Count 'jstart:*')"
        Invoke-Run @{} @("--setup")
        Check "--setup without a console installs it" "0|1|0" "$($script:Rc)|$(Get-Count 'sync:J=1*')|$(Get-Count 'jstart:*')"
        Reset-Kit "jupyterlab"
        Invoke-Run @{ SyncFails = $true } @("--setup")
        Check "a reinstall that fails: a failure, the retry named" "1" $script:Rc
        Contains "...the retry named" "retry with: exakit notebook setup" $script:Out

        Write-Host "c. Marimo removed from the environment:"
        Reset-Kit "jupyterlab,marimo" -Jupyter
        Set-ExakitManifestValue "components.notebook.marimo" "kit"
        Invoke-Run @{ Terminal = $true; Pick = @(2) }
        Contains "picked: a reinstall is offered" "confirm:Marimo is missing (it was removed from the kit's notebook environment). Reinstall it" $script:Did
        Check "...a yes installs it and opens it" "1|1" "$(Get-Count 'sync:J=0:M=1')|$(Get-Count 'mstart:*')"
        Reset-Kit "jupyterlab,marimo" -Jupyter
        Invoke-Run @{ Terminal = $true; Pick = @(1, 2); SyncFails = $true }
        Check "...an install that fails: the other tool still opens, a failure" "1|1" "$($script:Rc)|$(Get-Count 'jstart:*')"
        Contains "...the retry named" "retry with: exakit notebook marimo" $script:Out
    }

    Write-Host "d. the notebook environment deleted or broken:"
    Reset-Kit "jupyterlab" -Jupyter
    Remove-Item -Recurse -Force $script:NotebookVenv
    Invoke-Run @{}
    Check "no console: not repaired, nothing opened, a failure" "1|0" "$($script:Rc)|$((Get-Count 'install:*') + (Get-Count 'jstart:*') + (Get-Count 'confirm:*'))"
    Contains "...one line naming the repair" "The notebook environment is missing (its Python, $(Get-NotebookVenvPython), is gone) - nothing was opened. Repair it with: exakit update notebook" $script:Out
    Invoke-Run @{ Terminal = $true; Pick = @(1) }
    Contains "on a console: the repair is offered" "confirm:Repair it now?" $script:Did
    Check "...a yes installs it again at the recorded version, the whole way, then opens" "install:3.1.0:1|1" "$(@($script:Calls | Where-Object { $_ -like 'install:*' }) -join ',')|$(Get-Count 'jstart:*')"
    Contains "...and says so" "The notebook environment is repaired" $script:Out
    Check "...the variable it set is gone again" $null $env:EXAKIT_FORCE_COMPONENT_INSTALL
    Reset-Kit "jupyterlab" -Jupyter
    Invoke-Run @{ Terminal = $true; Answer = "n"; Env = "broken" }
    Check "broken, a no: nothing opened, a failure" "1|0" "$($script:Rc)|$(Get-Count 'jstart:*')"
    Contains "...the repair named" "Repair it any time with: exakit update notebook" $script:Out
    Remove-Item -Recurse -Force $script:NotebookVenv
    Invoke-Run @{} @("--stop")
    Check "--stop works with the environment gone" 0 $script:Rc
    if (-not $onWindows) {
        Reset-Kit "jupyterlab" -Jupyter
        $stub = Use-RealFunction "Get-NotebookEnvState"
        Check "the real check: imports" "ok" (Get-NotebookEnvState)
        Remove-Item -Force $importsOk
        Check "...does not import: broken" "broken" (Get-NotebookEnvState)
        Remove-Item -Force (Get-NotebookVenvPython)
        Check "...no Python: missing" "missing" (Get-NotebookEnvState)
        Set-Item -Path Function:\script:Get-NotebookEnvState -Value $stub
    }

    Write-Host "e. Positron uninstalled after it was set up:"
    Reset-Kit "jupyterlab,positron" -Jupyter
    [void](Set-NotebookPositronFolder)
    Invoke-Run @{ Terminal = $true; Pick = @(4) }
    Contains "a disabled row, with where to get it" "|!Positron - not on this machine" (Get-MenuLine)
    Contains "...its folder settings stay" "defaultInterpreterPath" (Get-Content -Raw (Join-Path (Join-Path $script:NotebookDir ".vscode") "settings.json"))
    Invoke-Run @{ Terminal = $true; Positron = $true; Pick = @(3) }
    Check "found again: picking it opens it on the folder" "1|0" "$(Get-Count 'open:/Applications/Positron.app')|$($script:Rc)"
    Lacks "...no stop line for Positron alone" "To stop" $script:Out

    Write-Host "f. a port another program holds:"
    Reset-Kit "jupyterlab,marimo" -Jupyter -Marimo
    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
    $listener.Start()
    try {
        $taken = "$($listener.LocalEndpoint.Port)"
        Check "it is seen as in use" $true (Test-NotebookPortInUse $taken)
        Check "a free one is not" $false (Test-NotebookPortInUse (New-FreePort))
        Set-ExakitManifestValue "components.notebook.port" $taken
        Invoke-Run @{}
        $next = Get-ExakitManifestValue "components.notebook.port"
        Check "not given with --port: the next free port is used, and recorded" "True|jstart:$next" "$([int]$next -gt [int]$taken -and [int]$next -le ([int]$taken + 20))|$(@($script:Calls | Where-Object { $_ -like 'jstart:*' }) -join ',')"
        Contains "...said in one line" "Port $taken is in use by another program, so JupyterLab uses port $next" $script:Out
        Remove-Item -Force $jState
        Invoke-Run @{} @("--port", $taken)
        Check "given with --port: refused, nothing started" "1|0" "$($script:Rc)|$(Get-Count 'jstart:*')"
        Contains "...pick another" "Port $taken is in use by another program - pick another with: exakit notebook --port <number>" $script:Out
        Set-ExakitManifestValue "components.notebook.marimo_port" $taken
        Invoke-Run @{} @("--marimo", "--no-browser")
        Check "Marimo too steps over it" 1 (Get-Count "mstart:$([int]$taken + 1)")
        Set-ExakitManifestValue "components.notebook.port" $taken
        $script:NotebookPortTries = 0
        try { Invoke-Run @{} } finally { $script:NotebookPortTries = 20 }
        Contains "no free port in the range: said, with --port" "all in use by other programs - pick a free one with: exakit notebook --port <number>" $script:Out
        Check "...a failure" 1 $script:Rc
    } finally { $listener.Stop() }

    Write-Host "g. the notebooks folder deleted:"
    Reset-Kit "jupyterlab" -Jupyter
    Invoke-Run @{}
    $train = Join-Path (Join-Path (Join-Path $script:NotebookDir "starter-kit-notebooks") "ml-engineer") "01_train.ipynb"
    Check "the first launch copies the kit's notebooks" $true (Test-Path $train)
    Remove-Item -Force $train
    Invoke-Run @{}
    Check "one notebook the user deleted stays deleted" $false (Test-Path $train)
    Remove-Item -Recurse -Force $script:NotebookDir
    Remove-Item -Force $jState
    Invoke-Run @{}
    Check "the whole folder deleted: made again, every notebook back" $true (Test-Path $train)
    Contains "...in one line" "The notebooks folder was gone, so it was made again with the kit's notebooks: " $script:Out
    Lacks "...not the list of every notebook" "New notebooks in" $script:Out
    Check "...and JupyterLab still opens" "0|1" "$($script:Rc)|$(Get-Count 'jstart:*')"

    Write-Host "h. the connection store or its master password deleted:"
    Reset-Kit "jupyterlab" -Jupyter
    $store = Get-NotebookStoreFile
    $master = Join-Path $script:CredsDir $script:NotebookMasterCred
    Check "a first write" "same" (Write-NotebookConnection)
    Check "...made its master password" $true (Test-Path $master)
    Set-Content -Path $store -Value "OLD" -NoNewline; Remove-Item -Force $master
    Check "the master deleted: a new store" "new|NEW" "$(Write-NotebookConnection)|$(Get-Content -Raw $store)"
    Check "...under a new master" $true (Test-Path $master)
    Set-Content -Path $store -Value "OLD" -NoNewline
    Check "a store that will not open: a new one, the old one kept beside it" "new|NEW|OLD" "$(Write-NotebookConnection)|$(Get-Content -Raw $store)|$(Get-Content -Raw "$store.unreadable")"
    Set-Content -Path $store -Value "OLD" -NoNewline
    $script:T = @{ StoreFails = $true }
    Check "a failure that is not the store's: the old store put back" "|OLD|False" "$(Write-NotebookConnection 6>$null)|$(Get-Content -Raw $store)|$(Test-Path "$store.unreadable")"
    $script:T = @{}
    Set-Content -Path $store -Value "OLD" -NoNewline; Remove-Item -Force $master
    Invoke-Run @{}
    Contains "the launcher says so in one line" "so a new one was written from the kit's connection" $script:Out
    Check "...and goes on" "0|1" "$($script:Rc)|$(Get-Count 'jstart:*')"
    Lacks "...never a secret on screen" (Get-Content -Raw $master) $script:Out

    Write-Host "i. the kernel spec removed:"
    Reset-Kit "jupyterlab,marimo" -Jupyter -Marimo
    foreach ($form in @(@(), @("--marimo"), @("--check"))) {
        Invoke-Run @{} $form
        Check "registered again on every launch: exakit notebook $($form -join ' ')" 1 (Get-Count "kernel")
    }
    Invoke-Run @{ Terminal = $true; Pick = @(4) }
    Check "...on the menu's path too, before it asks" "kernel menu" ((@($script:Calls | Where-Object { $_ -match '^(kernel|menu)' }) | ForEach-Object { ($_ -split ':')[0] }) -join " ")

    Write-Host "j. a stale pid file:"
    Reset-Kit "jupyterlab" -Jupyter
    $bystander = [System.Diagnostics.Process]::Start($python3, '-c "import time; time.sleep(60)"')
    try {
        New-Item -ItemType Directory -Force -Path $script:NotebookHome | Out-Null
        Set-Content -Path (Get-NotebookPidFile) -Value $bystander.Id
        $stub = Use-RealFunction "Get-NotebookServerState"
        Check "a pid file naming another program: not running, ready" "kit 4.4.9" (Get-NotebookJupyterState)
        Check "...the stale file removed" $false (Test-Path (Get-NotebookPidFile))
        Set-Item -Path Function:\script:Get-NotebookServerState -Value $stub
        Check "...and that program left alone" $false $bystander.HasExited
    } finally { Stop-Process -Id $bystander.Id -Force -ErrorAction SilentlyContinue }

    Write-Host "k. the browser cannot be opened:"
    Reset-Kit "jupyterlab,marimo" -Jupyter -Marimo
    Invoke-Run @{ Terminal = $true; Pick = @(1, 2); NoBrowser = $true }
    Contains "JupyterLab: its address and where the login token is" `
        "Open http://127.0.0.1:$(Get-ExakitManifestValue 'components.notebook.port')/lab - the login token is in $(Join-Path $script:CredsDir $script:NotebookTokenCred)" $script:Out
    Contains "Marimo: the same" `
        "Open http://127.0.0.1:$(Get-ExakitManifestValue 'components.notebook.marimo_port')/ - the login token is in $(Join-Path $script:CredsDir $script:NotebookMarimoCred)" $script:Out
    Lacks "...the token itself never on screen" (Get-ExakitCredential $script:NotebookTokenCred) $script:Out
    Check "...and the command still succeeds" 0 $script:Rc

    Write-Host "l. a tool already running:"
    Reset-Kit "jupyterlab,marimo" -Jupyter -Marimo
    New-Item -ItemType File -Force -Path $jState, $mState | Out-Null
    Invoke-Run @{ Terminal = $true; Pick = @(1, 2) }
    Check "picked from the menu: no second server" 0 ((Get-Count "jstart:*") + (Get-Count "mstart:*"))
    Contains "...JupyterLab opened where it runs" "JupyterLab is running: http://127.0.0.1:$(Get-ExakitManifestValue 'components.notebook.port')/lab" $script:Out
    Check "...both opened in the browser" 2 (Get-Count "open:*")
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "notebook-launcher-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
