# notebook.ps1 - notebook (Jupyter notebooks connected to the local database):
# managed install + validation + the `exakit notebook` command. Twin of
# setup/lib/notebook.sh; read that header for the facts. The Python steps (the
# encrypted store, the kernel, the connection check, placing the notebooks) are
# the shared scripts in notebook/kit/, so the two sides cannot drift there.
#
#   - venv:      $ExakitHome\notebook-venv
#   - store:     $ExakitHome\notebook\connection.scs
#   - notebooks: $ExakitHome\notebooks\starter-kit-notebooks\<persona>\ and
#                ...\marimo\<persona>\ (notebook\catalog.json; copied once,
#                never overwritten, one the user deleted not copied again; kept
#                by an uninstall, the full one too unless
#                EXAKIT_UNINSTALL_NOTEBOOKS=remove)
#   - the notebook tools: the notebook row's three child rows in the
#     marketplace's add-ons table (one checklist on a run that draws no table),
#     JupyterLab, Marimo and Positron all ticked, each saying before anything
#     installs what will become of it and then how it settled; the answer is
#     recorded and a reinstall or an update keeps it. Positron is only ever
#     configured, never installed.
#   - the front ends the kit installs are pinned in versions.json
#     (components.notebook.frontends), EXAKIT_NOTEBOOK_JUPYTERLAB_VERSION and
#     EXAKIT_NOTEBOOK_MARIMO_VERSION outranking the pin; they are in the one uv
#     resolution with the connector (JupyterLab as its jupyter extra), so an
#     update moves one the kit installed to a new pin.
#   - the login token never reaches a command line (a 0600-style HTML file in
#     the notebook home forwards the browser), and a pid file is trusted only
#     while its process is still the server the kit started.

$script:NotebookPackage = "exasol-notebook-connector"
$script:NotebookVersionFallback = if ($env:EXAKIT_NOTEBOOK_VERSION_FALLBACK) { $env:EXAKIT_NOTEBOOK_VERSION_FALLBACK } else { "3.1.0" }
$script:NotebookVersion = if ($env:EXAKIT_NOTEBOOK_VERSION) { $env:EXAKIT_NOTEBOOK_VERSION } else { "" }
$script:NotebookVenv = if ($env:EXAKIT_NOTEBOOK_VENV) { $env:EXAKIT_NOTEBOOK_VENV } else { Join-Path $script:ExakitHome "notebook-venv" }
$script:NotebookHome = if ($env:EXAKIT_NOTEBOOK_HOME) { $env:EXAKIT_NOTEBOOK_HOME } else { Join-Path $script:ExakitHome "notebook" }
$script:NotebookDir = if ($env:EXAKIT_NOTEBOOK_DIR) { $env:EXAKIT_NOTEBOOK_DIR } else { Join-Path $script:ExakitHome "notebooks" }
$script:NotebookPort = if ($env:EXAKIT_NOTEBOOK_PORT) { $env:EXAKIT_NOTEBOOK_PORT } else { "8888" }
$script:NotebookExtras = "bucketfs,ibis,pyexasol,sqlalchemy"
$script:NotebookPackages = @("ipykernel>=6.29,<8", "langfuse>=3,<4", "openai>=1.40,<3", "scikit-learn>=1.4,<2", "mlflow-skinny>=2.14,<4", "alembic>=1.13,<2", "pyarrow>=14")
# The kit's own packages, by their distribution names (reinstalled every time).
$script:NotebookOwnPackages = @("exakit-nb", "exasol-mlflow")
# Which front ends the next resolution brings (Set-NotebookFrontEndPlan), and
# the tools chosen at this install.
$script:NotebookAddJupyterLab = $false
$script:NotebookAddMarimo = $false
$script:NotebookFrontEnds = ""
$script:NotebookKernelName = "exasol-starter-kit"
$script:NotebookKernelTitle = "Exasol (Starter Kit)"
$script:NotebookInstallGuide = "https://jupyter.org/install"
$script:NotebookMasterCred = "notebook_store_master_password"
$script:NotebookTokenCred = "notebook_jupyter_token"
$script:NotebookMarimoCred = "notebook_marimo_token"
$script:NotebookMarimoPort = if ($env:EXAKIT_MARIMO_PORT) { $env:EXAKIT_MARIMO_PORT } else { "2718" }
$script:NotebookPositronDownload = "https://positron.posit.co/download.html"
# What a server's command line holds when it is the one the kit started (see
# Test-NotebookProcessOurs), and how long a start may take, in seconds.
$script:NotebookJupyterMatch = "*jupyter*--ServerApp.ip=127.0.0.1*"
$script:NotebookMarimoMatch = "*marimo_wrapper.py*"
$script:NotebookStartTimeout = if ($env:EXAKIT_NOTEBOOK_START_TIMEOUT) { [int]$env:EXAKIT_NOTEBOOK_START_TIMEOUT } else { 60 }
$script:NotebookCopyCode = 0

function Get-NotebookVenvPython { return (Join-Path $script:NotebookVenv "Scripts\python.exe") }
function Get-NotebookStoreFile { return (Join-Path $script:NotebookHome "connection.scs") }
function Get-NotebookPidFile { return (Join-Path $script:NotebookHome "jupyter.pid") }
function Get-NotebookLogDir {
    if ($script:LogDir) { return $script:LogDir }
    return (Join-Path $script:ExakitHome "logs")
}
# JupyterLab logs to stderr, so stderr is notebook.log; Marimo's wrapper merges
# Marimo's output into its stdout, so stdout is notebook-marimo.log.
function Get-NotebookLogFile { return (Join-Path (Get-NotebookLogDir) "notebook.log") }
function Get-NotebookOutFile { return (Join-Path (Get-NotebookLogDir) "notebook.out.log") }
function Get-NotebookMarimoPidFile { return (Join-Path $script:NotebookHome "marimo.pid") }
function Get-NotebookMarimoLogFile { return (Join-Path (Get-NotebookLogDir) "notebook-marimo.log") }
function Get-NotebookMarimoErrFile { return (Join-Path (Get-NotebookLogDir) "notebook-marimo.err.log") }
function Get-NotebookMarimoCommand { return (Join-Path (Join-Path $script:NotebookVenv "Scripts") "marimo.exe") }
function Get-NotebookOpenFile {
    param([Parameter(Mandatory)][string]$Front)
    return (Join-Path $script:NotebookHome "open-$Front.html")
}

# Get-NotebookLogPath - what `exakit logs` shows for this add-on, one
# "target|what|path" per log. Twin of notebook_log_path.
function Get-NotebookLogPath {
    return @("notebook|JupyterLab (exakit notebook)|$(Get-NotebookLogFile)",
             "notebook-marimo|Marimo (notebook --marimo)|$(Get-NotebookMarimoLogFile)")
}

# Get-NotebookPackageVersion - what the venv says about the connector. Twin of
# notebook_package_version.
function Get-NotebookPackageVersion {
    $python = Get-NotebookVenvPython
    if (-not (Test-Path $python)) { return $null }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $version = & $python -c "from importlib.metadata import version; print(version('exasol-notebook-connector'))" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($version | Out-String -Width 4096).Trim()
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

# Get-NotebookInstalledVersion - the record AND the venv. Twin of
# notebook_installed_version.
function Get-NotebookInstalledVersion {
    $recorded = Get-ExakitManifestValue "components.notebook.version"
    if (-not $recorded) { return $null }
    return (Get-NotebookPackageVersion)
}

function Write-NotebookNotInstalled {
    param([Parameter(Mandatory)][string]$Reason)
    Warn2 "The notebook add-on was not installed: $Reason"
    Warn2 "Everything else in the kit is unaffected. Retry with: exakit update notebook"
    Set-ExakitFailureReason $Reason
    Set-ExakitManifestValue "components.notebook.validated" $false
    return $false
}

# Get-NotebookSecret - the kit credential, generated on first use. Its value
# goes to a child's environment, never to a command line or a log.
function Get-NotebookSecret {
    param([Parameter(Mandatory)][string]$Name)
    $value = Get-ExakitCredential $Name
    if (-not $value) {
        $value = New-ExakitPassword
        Set-ExakitCredential -Name $Name -Value $value
    }
    return $value
}

# Invoke-NotebookPy - run one of notebook/kit/*.py with the venv's Python and
# the given environment (set for the child only, then restored). Returns
# @(exit code, output lines). Twin of _notebook_py.
function Invoke-NotebookPy {
    param([Parameter(Mandatory)][string]$Script, [hashtable]$Env = @{})
    $saved = @{}
    foreach ($key in $Env.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, [string]$Env[$key], "Process")
    }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $path = Join-Path (Join-Path (Join-Path (Get-ExakitRepoRoot) "notebook") "kit") $Script
        $lines = @(& (Get-NotebookVenvPython) $path 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } catch {
        $lines = @("$_")
        $code = 1
    } finally {
        $ErrorActionPreference = $prevEap
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process") }
    }
    if ($script:LogFile -and $lines.Count) { $lines | Add-Content -Path $script:LogFile }
    return ,@($code, $lines)
}

# Write-NotebookConnection - the kit's current connection into the store;
# returns "changed", "same" or $null. The script reads the password from its
# FILE. Twin of notebook_write_connection.
function Write-NotebookConnection {
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $user = Get-ExakitManifestValue "runtime.user"
    $pwFile = Get-ExakitManifestValue "runtime.password_file"
    $colon = if ($dsn) { $dsn.LastIndexOf(":") } else { -1 }
    if ($colon -lt 1 -or -not $pwFile) {
        Warn2 "The kit has no complete database connection recorded yet - install the kit first."
        return $null
    }
    New-Item -ItemType Directory -Force -Path $script:NotebookHome | Out-Null
    if (-not $user) { $user = "sys" }
    $result = Invoke-NotebookPy -Script "write_store.py" -Env @{
        SCS_FILE = (Get-NotebookStoreFile); SCS_MASTER_PASSWORD = (Get-NotebookSecret $script:NotebookMasterCred)
        EXAKIT_NB_HOST = $dsn.Substring(0, $colon); EXAKIT_NB_PORT = $dsn.Substring($colon + 1)
        EXAKIT_NB_USER = $user; EXAKIT_NB_PWFILE = $pwFile }
    if ($result[0] -ne 0) { return $null }
    return ("$(@($result[1])[-1])".Trim())
}

function Test-NotebookConnected {
    $result = Invoke-NotebookPy -Script "check_connection.py" -Env @{
        SCS_FILE = (Get-NotebookStoreFile); SCS_MASTER_PASSWORD = (Get-NotebookSecret $script:NotebookMasterCred) }
    return ($result[0] -eq 0)
}

# Invoke-NotebookFolders - notebook\kit\notebooks.py, which places the kit's
# notebooks and prepares the folder for Positron: standard library only, so the
# venv's Python runs it, and before the venv is there the system one or uv's.
# Its stderr goes to the log and, when it fails, to the screen as warnings too
# (it names what could not be done). Returns @(exit code, output lines). Twin
# of _notebook_folders.
function Invoke-NotebookFolders {
    param([Parameter(ValueFromRemainingArguments)]$FolderArgs)
    $script = Join-Path (Join-Path (Join-Path (Get-ExakitRepoRoot) "notebook") "kit") "notebooks.py"
    $prevEap = $ErrorActionPreference
    $all = @()
    try {
        $ErrorActionPreference = "Continue"
        $venvPython = Get-NotebookVenvPython
        if (Test-Path $venvPython) {
            $all = @(& $venvPython $script @FolderArgs 2>&1)
        } elseif (Test-ExakitSystemPython) {
            $all = @(& python $script @FolderArgs 2>&1)
        } else {
            $uv = Get-NotebookUv
            $all = @(& $uv run --python $script:ManagedPythonVersion --no-project python $script @FolderArgs 2>&1)
        }
        $code = $LASTEXITCODE
    } catch {
        $all = @(); $code = 1
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $lines = @($all | Where-Object { -not ($_ -is [System.Management.Automation.ErrorRecord]) } | ForEach-Object { "$_" })
    $errors = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$($_.Exception.Message)" } | Where-Object { $_ })
    if ($script:LogFile -and $errors.Count) { $errors | Add-Content -Path $script:LogFile }
    if ($code -ne 0) { foreach ($line in $errors) { Warn2 $line } }
    return ,@($code, $lines)
}

# Copy-NotebookContent [-Front jupyter|marimo] - the kit's notebooks into their
# persona folders, as notebook\catalog.json says; one already there is the
# user's and is never overwritten, one the kit copied before and the user
# deleted is not copied again. Returns persona/file per one added; the exit
# code is left in $script:NotebookCopyCode (non-zero when some could not be
# copied - each is warned about). Twin of notebook_copy_notebooks.
function Copy-NotebookContent {
    param([ValidateSet("jupyter", "marimo")][string]$Front = "jupyter")
    try {
        New-Item -ItemType Directory -Force -Path $script:NotebookDir -ErrorAction Stop | Out-Null
    } catch {
        Warn2 "The notebooks folder $($script:NotebookDir) could not be created"
        $script:NotebookCopyCode = 1
        return @()
    }
    $result = Invoke-NotebookFolders "copy" $Front (Get-ExakitRepoRoot) $script:NotebookDir
    $script:NotebookCopyCode = $result[0]
    return @($result[1] | Where-Object { $_ })
}

# Write-NotebookCopied - copy, then say what came: one line for the new ones,
# one warning when some could not be copied. Twin of _notebook_report_copied.
function Write-NotebookCopied {
    param([Parameter(Mandatory)][string]$Folder, [ValidateSet("jupyter", "marimo")][string]$Front = "jupyter")
    $added = @(Copy-NotebookContent -Front $Front)
    if ($added.Count) { Ok "New notebooks in $($Folder): $($added -join ' ')" }
    if ($script:NotebookCopyCode -ne 0) { Warn2 "Some of the kit's notebooks could not be copied into $Folder (named above)." }
}

function Register-NotebookKernel {
    [void](Get-NotebookSecret $script:NotebookMasterCred)
    $result = Invoke-NotebookPy -Script "register_kernel.py" -Env @{
        EXAKIT_KERNEL_NAME = $script:NotebookKernelName; EXAKIT_KERNEL_TITLE = $script:NotebookKernelTitle
        EXAKIT_NB_STORE = (Get-NotebookStoreFile); EXAKIT_NB_MASTER_FILE = (Join-Path $script:CredsDir $script:NotebookMasterCred)
        EXAKIT_NB_KIT = (Get-ExakitRepoRoot); EXAKIT_NB_DATASETS = (Join-Path (Join-Path (Get-ExakitRepoRoot) "data") "datasets") }
    return ($result[0] -eq 0)
}

function Unregister-NotebookKernel {
    if (-not (Test-Path (Get-NotebookVenvPython))) { return }
    [void](Invoke-NotebookPy -Script "remove_kernel.py" -Env @{ EXAKIT_KERNEL_NAME = $script:NotebookKernelName })
}

# Find-NotebookJupyter - @("kit", path) for one the user let the kit install,
# @("own", path) for one on PATH, $null when there is none. Twin of
# notebook_find_jupyter.
function Find-NotebookJupyter {
    foreach ($cmd in @("jupyter-lab", "jupyter-notebook")) {
        $mine = Join-Path (Join-Path $script:NotebookVenv "Scripts") "$cmd.exe"
        if (Test-Path $mine) { return ,@("kit", $mine) }
    }
    foreach ($cmd in @("jupyter-lab", "jupyter-notebook")) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) { return ,@("own", $found.Source) }
    }
    return $null
}

function Get-NotebookUv {
    try { return (Install-ExakitUv) } catch { return $null }
}

# Confirm-NotebookJupyter - settle JupyterLab: the user's own, or the kit's
# after a yes (EXAKIT_NOTEBOOK_JUPYTER=install|skip answers for a script; a run
# with no console skips). $false when there is none afterwards. Twin of
# notebook_offer_jupyter.
function Confirm-NotebookJupyter {
    if (Find-NotebookJupyter) { return $true }
    $answer = "$env:EXAKIT_NOTEBOOK_JUPYTER".ToLower()
    if (-not $answer) {
        if (Confirm-ExakitPrompt "No JupyterLab was found. Install JupyterLab into the kit's notebook environment" $false) { $answer = "install" } else { $answer = "skip" }
    }
    if ($answer -eq "install") {
        # The connector's jupyter extra, in the one resolution with everything
        # else (so an update keeps it, at the pinned version).
        $script:ExakitActiveLabel = "Installing JupyterLab"
        $script:NotebookAddJupyterLab = $true
        try { $synced = Sync-NotebookPackages } finally { $script:NotebookAddJupyterLab = $false }
        if ($synced -and (Test-Path (Join-Path (Join-Path $script:NotebookVenv "Scripts") "jupyter-lab.exe"))) {
            Set-ExakitManifestValue "components.notebook.jupyter" "kit"
            Add-NotebookFrontEnd "jupyterlab"
            Ok "JupyterLab $(Get-NotebookFrontendPin 'jupyterlab') installed into the kit's notebook environment"
            return $true
        }
        Warn2 "JupyterLab could not be installed (see the log)."
    }
    Info "No JupyterLab: get it at $($script:NotebookInstallGuide), then run: exakit notebook"
    Info "The kernel '$($script:NotebookKernelTitle)' is registered: VS Code or any Jupyter front end can use it now."
    return $false
}

# --- the notebook tools: the install's checklist, Marimo, Positron ------------

function Test-NotebookSkipped {
    param([string]$Value)
    return (@("skip", "no", "0", "false", "none") -contains "$Value".ToLower())
}

# ConvertTo-NotebookFrontEnds - a list of notebook tools made canonical:
# jupyterlab (jupyter is the same), marimo, positron, or none; any case,
# separated by commas or any whitespace. An unknown name is warned about
# (naming -Source) and dropped; "" when no known name is left. Twin of
# _notebook_front_ends_given.
function ConvertTo-NotebookFrontEnds {
    param([string]$Value, [string]$Source = "EXAKIT_NOTEBOOK_FRONTENDS", [switch]$Quiet)
    $j = $false; $m = $false; $p = $false; $none = $false
    foreach ($token in @("$Value".ToLower() -split '[,;\s]+')) {
        if (-not $token) { continue }
        switch -CaseSensitive ($token) {
            "jupyterlab" { $j = $true }
            "jupyter" { $j = $true }
            "marimo" { $m = $true }
            "positron" { $p = $true }
            "none" { $none = $true }
            default { if (-not $Quiet) { Warn2 "$($Source): '$token' is not a notebook tool (jupyterlab, marimo, positron or none) - ignored" } }
        }
    }
    $out = @()
    if ($j) { $out += "jupyterlab" }
    if ($m) { $out += "marimo" }
    if ($p) { $out += "positron" }
    if ($out.Count -eq 0 -and $none) { return "none" }
    return ($out -join ",")
}

# Add-NotebookFrontEnd - a tool added after the install (exakit notebook
# --setup | --marimo | --positron) joins the recorded choice, so an update
# keeps it. Twin of _notebook_front_end_add.
function Add-NotebookFrontEnd {
    param([Parameter(Mandatory)][string]$Name)
    $now = Get-ExakitManifestValue "components.notebook.front_ends"
    if (-not $now) { return }
    if ($now -eq "none") { $now = "" }
    Set-ExakitManifestValue "components.notebook.front_ends" (ConvertTo-NotebookFrontEnds "$now,$Name" -Quiet)
}

# Read-NotebookQuestions - the marketplace's QUESTIONS FIRST hook: the notebook
# tools are asked before the install table animates, and the answer is set for
# the install that follows. Only reached on a run whose table did not carry the
# tools as rows (a scripted EXAKIT_MARKETPLACE_ADDONS): where it did, the rows
# were the question (Set-NotebookTableChildrenPicked). Twin of notebook_questions.
function Read-NotebookQuestions {
    $env:EXAKIT_NOTEBOOK_FRONTENDS = Get-NotebookFrontEnds
}

# Get-NotebookDefaultFrontEnds - the notebook tools WITHOUT asking:
# @{ FrontEnds = "jupyterlab,marimo,positron" (or a subset, or none); Decided }.
# EXAKIT_NOTEBOOK_FRONTENDS answers it; else a reinstall or an update keeps the
# recorded choice; else all three, less any EXAKIT_NOTEBOOK_JUPYTER /
# EXAKIT_NOTEBOOK_MARIMO=skip leaves out. Decided is $true for an ANSWER (the
# variable or the record), $false for only where a question would start: the
# checklist below, and the ticks of the tools' rows in the add-ons table
# (Get-NotebookTableChildren). Twin of notebook_default_front_ends.
function Get-NotebookDefaultFrontEnds {
    if ($env:EXAKIT_NOTEBOOK_FRONTENDS) {
        $given = ConvertTo-NotebookFrontEnds $env:EXAKIT_NOTEBOOK_FRONTENDS
        if ($given) { return @{ FrontEnds = $given; Decided = $true } }
        Warn2 "EXAKIT_NOTEBOOK_FRONTENDS names no notebook tool, so it is not used"
    }
    $recorded = Get-ExakitManifestValue "components.notebook.front_ends"
    if ($recorded) {
        $kept = ConvertTo-NotebookFrontEnds "$recorded" -Quiet
        if ($kept) { return @{ FrontEnds = $kept; Decided = $true } }
    }
    $fronts = @()
    if (-not (Test-NotebookSkipped $env:EXAKIT_NOTEBOOK_JUPYTER)) { $fronts += "jupyterlab" }
    if (-not (Test-NotebookSkipped $env:EXAKIT_NOTEBOOK_MARIMO)) { $fronts += "marimo" }
    $fronts += "positron"
    return @{ FrontEnds = ($fronts -join ","); Decided = $false }
}

# Get-NotebookFrontEnds - which notebook tools: jupyterlab, marimo, positron
# (or none). Get-NotebookDefaultFrontEnds answers it when it can (the variable,
# or the recorded choice); else (the first install, with no table that already
# asked) one checklist starting from its ticks, and without a console the
# ticks stand. Twin of notebook_choose_front_ends.
function Get-NotebookFrontEnds {
    $start = Get-NotebookDefaultFrontEnds
    if ($start.Decided) { return $start.FrontEnds }
    $keys = @("jupyterlab", "marimo", "positron")
    $startWith = @($start.FrontEnds -split ',')
    $defaults = @()
    if ($startWith -contains "jupyterlab") { $defaults += 1 }
    if ($startWith -contains "marimo") { $defaults += 2 }
    $defaults += 3
    $picked = $defaults
    if (Test-ExakitInteractive) {
        $picked = @(Read-ExakitCheckboxMenu -Title "Notebook tools - untick any you do not want" -Defaults $defaults -Options @(
            "JupyterLab - notebooks in the browser with the kit's kernel; yours is used if you have one",
            "Marimo - reactive notebooks, installed into the kit's notebook environment",
            "Positron - your Positron, pointed at the kit's Python; never installed by the kit"))
    }
    $chosen = @($picked | Where-Object { $_ -ge 1 -and $_ -le 3 } | Sort-Object -Unique | ForEach-Object { $keys[$_ - 1] })
    if ($chosen.Count -eq 0) { return "none" }
    return ($chosen -join ",")
}

# Get-NotebookTableChildren - the notebook tools as CHILD ROWS of the notebook's
# row in the marketplace's add-ons table (the registry's ChildrenFn), one object
# each: Key, Label, Version, Description, Ticked. The description says, before
# anything installs, what will become of each tool - from the find helpers
# alone, no network - and the ticks are Get-NotebookDefaultFrontEnds'. The
# version is the pin the kit installs at; Positron has none, the kit never
# installs it. Twin of notebook_table_children.
function Get-NotebookTableChildren {
    $fronts = @((Get-NotebookDefaultFrontEnds).FrontEnds -split ',')
    $found = Find-NotebookJupyter
    if ($found -and $found[0] -eq "own") { $jdesc = "yours ($(Get-ExakitTilde $found[1])) is used as it is" }
    elseif ($found) { $jdesc = "already in the kit's notebook environment" }
    else { $jdesc = "not on this machine: installed into the kit's notebook environment" }
    if (Test-Path (Get-NotebookMarimoCommand)) { $mdesc = "already installed" }
    else { $mdesc = "installed into the kit's notebook environment" }
    if (Find-NotebookPositron) { $pdesc = "yours: pointed at the kit's Python" }
    else { $pdesc = "not on this machine: the notebooks folder is prepared for it (positron.posit.co)" }
    return @(
        [pscustomobject]@{ Key = "jupyterlab"; Label = "JupyterLab"; Version = ("" + (Get-NotebookFrontendPin "jupyterlab"))
            Description = $jdesc; Ticked = ($fronts -contains "jupyterlab") },
        [pscustomobject]@{ Key = "marimo"; Label = "Marimo"; Version = ("" + (Get-NotebookFrontendPin "marimo"))
            Description = $mdesc; Ticked = ($fronts -contains "marimo") },
        [pscustomobject]@{ Key = "positron"; Label = "Positron"; Version = ""
            Description = $pdesc; Ticked = ($fronts -contains "positron") }
    )
}

# Set-NotebookTableChildrenPicked -Keys <keys> - the ticked tool rows ARE the
# answer: set as EXAKIT_NOTEBOOK_FRONTENDS ("none" when no tool row was
# ticked), so the install takes it without asking. Twin of
# notebook_table_children_picked.
function Set-NotebookTableChildrenPicked {
    param([string[]]$Keys = @())
    $given = ConvertTo-NotebookFrontEnds ($Keys -join ",") -Quiet
    if (-not $given) { $given = "none" }
    $env:EXAKIT_NOTEBOOK_FRONTENDS = $given
}

# Set-NotebookFrontEndPlan - which front ends the install's one resolution
# brings, from the ticked tools: JupyterLab when it is ticked and the user has
# none of their own (one on PATH is used instead), Marimo when it is ticked.
# Twin of notebook_plan_front_ends.
function Set-NotebookFrontEndPlan {
    param([string]$FrontEnds)
    $fronts = @("$FrontEnds" -split ',')
    $found = Find-NotebookJupyter
    $script:NotebookAddJupyterLab = (($fronts -contains "jupyterlab") -and -not ($found -and $found[0] -eq "own"))
    $script:NotebookAddMarimo = ($fronts -contains "marimo")
}

# Install-NotebookFrontEnds - the install's notebook tools, one line each. The
# tools were chosen before the packages were installed (Install-Notebook), so
# what the kit installs came with them; this settles what is left. Under the
# marketplace's live add-ons table each tool also settles its own row there
# (Set-ExakitAddonTableChild); the lines then go to the logfile, as every
# detail of an install narrated by the table does. Twin of
# notebook_front_ends_setup.
function Install-NotebookFrontEnds {
    if (-not $script:NotebookFrontEnds) { $script:NotebookFrontEnds = Get-NotebookFrontEnds }
    $fronts = @($script:NotebookFrontEnds -split ',')
    if ($fronts -contains "jupyterlab") {
        $found = Find-NotebookJupyter
        if ($found) {
            $whose = "yours"
            $said = "yours, kernel added"
            if ($found[0] -eq "kit") {
                $whose = "the kit's"; $said = "installed" + (Get-NotebookPinSuffix "jupyterlab")
                Set-ExakitManifestValue "components.notebook.jupyter" "kit"
            }
            Ok "JupyterLab ($($whose): $($found[1])) with the kernel '$($script:NotebookKernelTitle)' - open it with: exakit notebook"
            [void](Set-ExakitAddonTableChild -Key "jupyterlab" -State "done" -Final $said)
        } else {
            $saved = $env:EXAKIT_NOTEBOOK_JUPYTER
            $env:EXAKIT_NOTEBOOK_JUPYTER = "install"
            # The LAST thing it returns is the answer; anything a step inside it
            # let fall into the pipeline comes before.
            $got = $false
            try { $r = @(Confirm-NotebookJupyter); $got = ($r.Count -gt 0 -and $r[-1] -eq $true) }
            finally { $env:EXAKIT_NOTEBOOK_JUPYTER = $saved }
            if ($got) { [void](Set-ExakitAddonTableChild -Key "jupyterlab" -State "done" -Final ("installed" + (Get-NotebookPinSuffix "jupyterlab"))) }
            else { [void](Set-ExakitAddonTableChild -Key "jupyterlab" -State "failed" -Final "not installed - see the log") }
        }
    } else {
        Info "JupyterLab not set up; the kernel '$($script:NotebookKernelTitle)' is registered for any Jupyter - add it any time: exakit notebook --setup"
        [void](Set-ExakitAddonTableChild -Key "jupyterlab" -State "skipped")
    }
    if ($fronts -contains "marimo") {
        if (Test-Path (Get-NotebookMarimoCommand)) {
            [void](Copy-NotebookContent -Front marimo)
            Set-ExakitManifestValue "components.notebook.marimo" "kit"
        }
        if ((Test-Path (Get-NotebookMarimoCommand)) -or (Install-NotebookMarimo)) {
            Ok "Marimo with the notebooks in $(Join-Path $script:NotebookDir 'marimo') - start it with: exakit notebook --marimo"
            [void](Set-ExakitAddonTableChild -Key "marimo" -State "done" -Final ("installed" + (Get-NotebookPinSuffix "marimo")))
        } else {
            Warn2 "Marimo could not be installed (see the log) - retry with: exakit notebook --marimo"
            [void](Set-ExakitAddonTableChild -Key "marimo" -State "failed" -Final "not installed - see the log")
        }
    } else {
        Info "Marimo not installed - add it any time: exakit notebook --marimo"
        [void](Set-ExakitAddonTableChild -Key "marimo" -State "skipped")
    }
    if ($fronts -contains "positron") {
        $how = "" + @(Write-NotebookPositronNote)[-1]
        if ($how -eq "configured") { [void](Set-ExakitAddonTableChild -Key "positron" -State "done" -Final "configured") }
        elseif ($how -eq "absent") { [void](Set-ExakitAddonTableChild -Key "positron" -State "skipped" -Final "not on this machine - folder ready") }
        else { [void](Set-ExakitAddonTableChild -Key "positron" -State "failed" -Final "folder not prepared - see the log") }
    } else {
        Info "Positron not set up - any time: exakit notebook --positron"
        [void](Set-ExakitAddonTableChild -Key "positron" -State "skipped")
    }
    Set-ExakitManifestValue "components.notebook.front_ends" ($fronts -join ",")
}

# Get-NotebookPinSuffix <jupyterlab|marimo> - " <pin>" for a tool's table row,
# "" when no version is pinned. Twin of _notebook_pin_suffix.
function Get-NotebookPinSuffix {
    param([Parameter(Mandatory)][string]$Name)
    $pin = Get-NotebookFrontendPin $Name
    if ($pin) { return " $pin" }
    return ""
}

# Install-NotebookMarimo - Marimo, at its pin, into the kit's notebook
# environment (the one resolution, so an update keeps it), then the kit's
# Marimo notebooks into marimo\<persona>\. Twin of notebook_install_marimo.
function Install-NotebookMarimo {
    $script:ExakitActiveLabel = "Installing Marimo"
    $script:NotebookAddMarimo = $true
    try { $synced = Sync-NotebookPackages } finally { $script:NotebookAddMarimo = $false }
    if (-not $synced) { return $false }
    if (-not (Test-Path (Get-NotebookMarimoCommand))) { return $false }
    [void](Copy-NotebookContent -Front marimo)
    Set-ExakitManifestValue "components.notebook.marimo" "kit"
    Add-NotebookFrontEnd "marimo"
    return $true
}

# --- the servers: pid files, starting, waiting, stopping, logging in --------------

# Get-NotebookProcessCommandLine - the command line of a process, "" when it
# cannot be read. Win32_Process on Windows; ps where there is no CIM (pwsh on
# macOS or Linux, where the tests run).
function Get-NotebookProcessCommandLine {
    param([Parameter(Mandatory)][int]$Id)
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        try {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction Stop
            if ($proc) { return "$($proc.CommandLine)" }
            return ""
        } catch { }
    }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $line = & ps -p $Id -o command= 2>$null
        if ($LASTEXITCODE -eq 0) { return ("$line").Trim() }
    } catch { } finally { $ErrorActionPreference = $prevEap }
    return ""
}

# Test-NotebookProcessOurs - the process is alive AND its command line matches
# -Pattern (a -like pattern), so it is still the server the kit started. A pid
# file outlives its process and the number goes to someone else; that program
# is never reported as ours, waited for, or stopped. Twin of _notebook_proc_ours.
function Test-NotebookProcessOurs {
    param([string]$PidText, [Parameter(Mandatory)][string]$Pattern)
    if ("$PidText" -notmatch '^\d{1,9}$') { return $false }
    if (-not (Get-Process -Id ([int]$PidText) -ErrorAction SilentlyContinue)) { return $false }
    return ((Get-NotebookProcessCommandLine -Id ([int]$PidText)) -like $Pattern)
}

# Get-NotebookLivePid - the pid in the file while it is still ours; otherwise
# the file is stale: removed, and $null returned. Twin of _notebook_live_pid.
function Get-NotebookLivePid {
    param([Parameter(Mandatory)][string]$PidFile, [Parameter(Mandatory)][string]$Pattern)
    $pidText = ""
    if (Test-Path $PidFile) { $pidText = "$(Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)".Trim() }
    if (Test-NotebookProcessOurs -PidText $pidText -Pattern $Pattern) { return [int]$pidText }
    Remove-Item -Force -ErrorAction SilentlyContinue $PidFile
    return $null
}

# Wait-NotebookUp - wait until the server answers. Gives up at once when its
# process is gone, and after EXAKIT_NOTEBOOK_START_TIMEOUT seconds of wall time
# (not attempts: a port that accepts but never answers makes each probe slow).
# Twin of _notebook_wait_up.
function Wait-NotebookUp {
    param([Parameter(Mandatory)][scriptblock]$Answers, [Parameter(Mandatory)][string]$Port,
          [Parameter(Mandatory)][string]$PidFile, [Parameter(Mandatory)][string]$Pattern,
          [Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$Log)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if (& $Answers $Port) { return $true }
        if ($null -eq (Get-NotebookLivePid -PidFile $PidFile -Pattern $Pattern)) {
            Warn2 "$Label stopped while it was starting - see $Log"
            return $false
        }
        if ($clock.Elapsed.TotalSeconds -ge $script:NotebookStartTimeout) { break }
        Start-Sleep -Seconds 1
    }
    Warn2 "$Label did not answer within $($script:NotebookStartTimeout)s - see $Log"
    return $false
}

# Stop-NotebookProcess - the process and its children: taskkill /T on Windows,
# Stop-Process elsewhere (the tests).
function Stop-NotebookProcess {
    param([Parameter(Mandatory)][int]$Id)
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        if (Get-Command taskkill -ErrorAction SilentlyContinue) {
            & taskkill /PID $Id /T /F 2>$null | Out-Null
        } else {
            Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue
        }
    } catch { } finally { $ErrorActionPreference = $prevEap }
}

# Open-NotebookLoggedIn - the browser opens a short HTML file that forwards to
# the address with its token, as Jupyter does: a token on Start-Process's
# command line is readable by every process on the machine. The file sits in
# the notebook home, readable by the user only, and goes when the server
# stops. $false when no browser could be opened. Twin of
# _notebook_open_logged_in.
function Open-NotebookLoggedIn {
    param([Parameter(Mandatory)][string]$Front, [Parameter(Mandatory)][string]$Url)
    if ($Url -match '["<>]') { return $false }
    $file = Get-NotebookOpenFile $Front
    $href = $Url.Replace("&", "&amp;")
    try {
        New-Item -ItemType Directory -Force -Path $script:NotebookHome | Out-Null
        Remove-Item -Force -ErrorAction SilentlyContinue $file
        [System.IO.File]::WriteAllText($file, "<!DOCTYPE html>`n<html><head><meta charset=`"utf-8`"><meta http-equiv=`"refresh`" content=`"0;url=$href`">`n<title>Opening the notebooks</title></head>`n<body><p><a href=`"$href`">Open the notebooks</a></p></body></html>`n")
        Protect-ExakitFile $file
        Start-Process -FilePath $file | Out-Null
        return $true
    } catch {
        return $false
    }
}

# --- Marimo on demand --------------------------------------------------------------

function Test-NotebookMarimoAnswers {
    param([string]$Port)
    try {
        [void](Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2)
        return $true
    } catch {
        $response = $_.Exception.Response
        return ($null -ne $response -and [int]$response.StatusCode -lt 500)
    }
}

# Get-NotebookMarimoPort - where Marimo starts next: EXAKIT_MARIMO_PORT, else
# the recorded port, else the default.
function Get-NotebookMarimoPort {
    if ($env:EXAKIT_MARIMO_PORT) { return $env:EXAKIT_MARIMO_PORT }
    $recorded = Get-ExakitManifestValue "components.notebook.marimo_port"
    if ($recorded) { return $recorded }
    return $script:NotebookMarimoPort
}

# Get-NotebookMarimoRunningPort - where the Marimo the kit started serves: the
# port recorded when it started.
function Get-NotebookMarimoRunningPort {
    $recorded = Get-ExakitManifestValue "components.notebook.marimo_port"
    if ($recorded) { return "$recorded" }
    return $script:NotebookMarimoPort
}

# Get-NotebookMarimoState - running|starting|stopped|not installed. Twin of
# notebook_marimo_state.
function Get-NotebookMarimoState {
    if (-not (Test-Path (Get-NotebookMarimoCommand))) { return "not installed" }
    if ($null -ne (Get-NotebookLivePid -PidFile (Get-NotebookMarimoPidFile) -Pattern $script:NotebookMarimoMatch)) {
        if (Test-NotebookMarimoAnswers (Get-NotebookMarimoRunningPort)) { return "running" }
        return "starting"
    }
    return "stopped"
}

# Start-NotebookMarimo - Marimo in the background on 127.0.0.1 over the kit's
# Marimo notebooks. Marimo reads its token from the credential FILE and the
# wrapper masks it in the log. Twin of notebook_marimo_start.
function Start-NotebookMarimo {
    param([Parameter(Mandatory)][string]$Port)
    if (Test-NotebookMarimoAnswers $Port) {
        Warn2 "Port $Port already answers for another program - pick another with: exakit notebook --marimo --port <number>"
        return $false
    }
    [void](Get-NotebookSecret $script:NotebookMarimoCred)
    $dir = Join-Path $script:NotebookDir "marimo"
    $token = Join-Path $script:CredsDir $script:NotebookMarimoCred
    $log = Get-NotebookMarimoLogFile
    foreach ($folder in @($dir, $script:NotebookHome, (Split-Path -Parent $log))) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    $wrapper = Join-Path (Join-Path (Join-Path (Get-ExakitRepoRoot) "notebook") "kit") "marimo_wrapper.py"
    $proc = Start-Process -FilePath (Get-NotebookVenvPython) -WorkingDirectory $dir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError (Get-NotebookMarimoErrFile) `
        -ArgumentList @("`"$wrapper`"", "`"$token`"", "`"$(Get-NotebookMarimoCommand)`"", "edit", "`"$dir`"", "--headless",
                        "--host", "127.0.0.1", "--port", $Port, "--token-password-file", "`"$token`"", "--skip-update-check")
    Set-Content -Path (Get-NotebookMarimoPidFile) -Value $proc.Id -Encoding Ascii
    Set-ExakitManifestValue "components.notebook.marimo_port" $Port
    return (Wait-NotebookUp -Answers ${function:Test-NotebookMarimoAnswers} -Port $Port -PidFile (Get-NotebookMarimoPidFile) `
        -Pattern $script:NotebookMarimoMatch -Label "Marimo" -Log $log)
}

# Stop-NotebookMarimo [-Quiet] - stop the Marimo the kit started; a stale pid
# file is only removed. Twin of notebook_marimo_stop.
function Stop-NotebookMarimo {
    param([switch]$Quiet)
    $live = Get-NotebookLivePid -PidFile (Get-NotebookMarimoPidFile) -Pattern $script:NotebookMarimoMatch
    if ($null -ne $live) {
        Stop-NotebookProcess -Id $live
        Ok "Marimo stopped (your notebooks are saved in their folder)"
    } elseif (-not $Quiet) {
        Info "Marimo is not running"
    }
    Remove-Item -Force -ErrorAction SilentlyContinue (Get-NotebookMarimoPidFile)
    Remove-Item -Force -ErrorAction SilentlyContinue (Get-NotebookOpenFile "marimo")
}

# --- Positron ------------------------------------------------------------------------

# Find-NotebookPositron - Positron's CLI on PATH, else the installed app; $null
# when it is not there. Twin of notebook_find_positron.
function Find-NotebookPositron {
    $found = Get-Command positron -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    foreach ($place in @(@($env:LOCALAPPDATA, "Programs\Positron\Positron.exe"), @($env:ProgramFiles, "Positron\Positron.exe"))) {
        if (-not $place[0]) { continue }
        $app = Join-Path $place[0] $place[1]
        if (Test-Path $app) { return $app }
    }
    return $null
}

# Set-NotebookPositronFolder - the notebooks folder as a Positron workspace
# whose interpreter is the kit's notebook Python. VS Code's JSON with comments
# is read; a file with comments is never rewritten, so $false (the file left
# alone, the reason warned) unless it already names the kit's Python. Twin of
# notebook_prepare_positron.
function Set-NotebookPositronFolder {
    $result = Invoke-NotebookFolders "positron" $script:NotebookDir (Get-NotebookVenvPython) $script:NotebookVenv
    return ($result[0] -eq 0)
}

# Write-NotebookPositronNote - configure the folder for Positron and say what
# came of it: "configured" (Positron is here and now opens the folder with the
# kit's Python), "absent" (it is not on this machine; the folder is ready for
# it) or "failed" (the folder could not be prepared, the reason warned) - so
# the tool's row in the add-ons table can say which. Twin of
# notebook_positron_note.
function Write-NotebookPositronNote {
    if (-not (Set-NotebookPositronFolder)) { return "failed" }
    $found = Find-NotebookPositron
    if ($found) {
        Ok "Positron ($found) opens the notebooks with the kit's Python: exakit notebook --positron"
        return "configured"
    }
    Info "Positron is not on this machine, so there is nothing to configure in it - the notebooks folder is ready for it: $($script:NotebookPositronDownload)"
    return "absent"
}

# Get-NotebookFrontendPin - the version of a front end the kit installs:
# EXAKIT_NOTEBOOK_JUPYTERLAB_VERSION / EXAKIT_NOTEBOOK_MARIMO_VERSION when set,
# else versions.json components.notebook.frontends.<name> - the advertised
# document, then the kit copy's own. $null when neither names a version in the
# safe charset: it goes on a uv command line. Twin of notebook_frontend_pin.
function Get-NotebookFrontendPin {
    param([Parameter(Mandatory)][ValidateSet("jupyterlab", "marimo")][string]$Name)
    $version = $env:EXAKIT_NOTEBOOK_JUPYTERLAB_VERSION
    if ($Name -eq "marimo") { $version = $env:EXAKIT_NOTEBOOK_MARIMO_VERSION }
    if (-not $version) { $version = Get-ExakitVersionsValue -Path "components.notebook.frontends.$Name" }
    if (-not $version) {
        $baked = Get-ExakitVersionsBakedPath
        if ($baked) { $version = Get-ExakitVersionsValue -Path "components.notebook.frontends.$Name" -DocPath $baked }
    }
    if ("$version" -notmatch '^[A-Za-z0-9._+-]+$') { return $null }
    return "$version"
}

# Get-NotebookFrontendsInstalled - name -> version for each front end the kit's
# venv holds (jupyterlab, marimo); empty without a venv. Twin of
# _notebook_frontends_installed.
function Get-NotebookFrontendsInstalled {
    $found = @{}
    $python = Get-NotebookVenvPython
    if (-not (Test-Path $python)) { return $found }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $code = "import sys`nfrom importlib.metadata import PackageNotFoundError, version`nfor name in sys.argv[1:]:`n    try:`n        print(name + '=' + version(name))`n    except PackageNotFoundError:`n        pass"
        foreach ($line in @(& $python -c $code "jupyterlab" "marimo" 2>$null)) {
            $parts = "$line".Trim().Split("=", 2)
            if ($parts.Count -eq 2) { $found[$parts[0]] = $parts[1] }
        }
    } catch { } finally { $ErrorActionPreference = $prevEap }
    return $found
}

# Get-NotebookSpecs - the connector with its extras, the companion packages,
# the front ends the kit installs (asked for now, or already in the venv) at
# their pins, and the two packages the kit carries. JupyterLab is the
# connector's jupyter extra, its version held by jupyterlab==<pin>; a front end
# with no pin is warned about (JupyterLab then comes within the connector's
# range, Marimo is left out). Twin of _notebook_specs.
function Get-NotebookSpecs {
    $root = Get-ExakitRepoRoot
    $extras = $script:NotebookExtras
    $fronts = @()
    if ($script:NotebookAddJupyterLab -or (Test-Path (Join-Path (Join-Path $script:NotebookVenv "Scripts") "jupyter-lab.exe"))) {
        $extras = "$extras,jupyter"
        $pin = Get-NotebookFrontendPin "jupyterlab"
        if ($pin) { $fronts += "jupyterlab==$pin" }
        else { Warn2 "No JupyterLab version is pinned (versions.json components.notebook.frontends.jupyterlab) - the connector's range decides" }
    }
    if ($script:NotebookAddMarimo -or (Test-Path (Get-NotebookMarimoCommand))) {
        $pin = Get-NotebookFrontendPin "marimo"
        if ($pin) { $fronts += "marimo==$pin" }
        else { Warn2 "No Marimo version is pinned (versions.json components.notebook.frontends.marimo) - Marimo is left out" }
    }
    $version = $script:NotebookVersion
    if (-not $version) { $version = Get-NotebookPackageVersion }
    $specs = @("$($script:NotebookPackage)[$extras]==$version")
    $specs += $script:NotebookPackages
    $specs += $fronts
    $specs += (Join-Path (Join-Path $root "notebook") "package")
    $specs += (Join-Path (Join-Path $root "packages") "exasol-mlflow")
    return $specs
}

# Sync-NotebookPackages - the whole set into the venv in one resolution, with
# the kit's own two packages REINSTALLED from this kit copy, so a new notebook
# never runs against helpers an older kit installed. A front end the kit
# installed is in the set at its pin, so a pin that moved moves it too (said in
# one line). $true on success. Twin of notebook_sync_packages.
function Sync-NotebookPackages {
    $uv = Get-NotebookUv
    if (-not $uv) { return $false }
    $before = Get-NotebookFrontendsInstalled
    $pipArgs = @("pip", "install", "--python", (Get-NotebookVenvPython))
    foreach ($own in $script:NotebookOwnPackages) { $pipArgs += @("--reinstall-package", $own) }
    $pipArgs += (Get-NotebookSpecs)
    if ((Invoke-ExakitLogged $uv @pipArgs) -ne 0) { return $false }
    $after = Get-NotebookFrontendsInstalled
    foreach ($name in @($after.Keys)) {
        if ($before.ContainsKey($name) -and $before[$name] -ne $after[$name]) {
            Ok "$name $($before[$name]) -> $($after[$name]) (the version versions.json pins)"
        }
    }
    return $true
}

function Install-Notebook {
    if (-not $script:NotebookVersion) {
        $resolved = Get-ExakitComponentAvailable "notebook"
        if ($resolved) { $script:NotebookVersion = $resolved } else { $script:NotebookVersion = $script:NotebookVersionFallback }
    }
    $uv = Get-NotebookUv
    if (-not $uv) {
        return (Write-NotebookNotInstalled "uv (the Python tool runner) is not available - install it from https://docs.astral.sh/uv/ and re-run")
    }
    # The notebook tools first: the front ends the kit installs join the
    # connector's own resolution below.
    $script:NotebookFrontEnds = Get-NotebookFrontEnds
    Set-NotebookFrontEndPlan $script:NotebookFrontEnds
    $python = Get-NotebookVenvPython
    $current = Get-NotebookPackageVersion
    if ($current -and $current -eq $script:NotebookVersion -and $env:EXAKIT_FORCE_COMPONENT_INSTALL -ne "1") {
        Ok "notebook $current already installed: $script:NotebookVenv"
        $script:ExakitActiveLabel = "Refreshing the kit's notebook helpers"
        if (-not (Sync-NotebookPackages)) { Warn2 "The kit's notebook helpers could not be refreshed (see the log) - retry with: exakit update notebook" }
    } else {
        $script:ExakitActiveLabel = "Installing the notebook connector $($script:NotebookVersion)"
        Info "Installing the notebook connector $($script:NotebookVersion) (about 1 GB: it brings PyTorch for its transformer features)"
        if (-not (Test-Path $python)) {
            if ((Invoke-ExakitLogged $uv "venv" "--python" $script:ManagedPythonVersion $script:NotebookVenv) -ne 0) {
                return (Write-NotebookNotInstalled "the virtual environment at $script:NotebookVenv could not be created (see log)")
            }
        }
        if (-not (Sync-NotebookPackages)) {
            return (Write-NotebookNotInstalled "installing $($script:NotebookPackage)==$($script:NotebookVersion) and its companions failed (see log)")
        }
        if (-not (Get-NotebookPackageVersion)) {
            return (Write-NotebookNotInstalled "the venv cannot report a $($script:NotebookPackage) version after the install (see log)")
        }
        Ok "Notebook connector installed: $script:NotebookVenv"
    }
    Write-NotebookCopied -Folder (Join-Path $script:NotebookDir "starter-kit-notebooks")
    if (-not (Register-NotebookKernel)) {
        return (Write-NotebookNotInstalled "the Jupyter kernel could not be registered (see log)")
    }
    Ok "Kernel registered: $($script:NotebookKernelTitle)"
    Set-ExakitManifestValue "components.notebook.version" $script:NotebookVersion
    Set-ExakitManifestValue "components.notebook.venv" $script:NotebookVenv
    Set-ExakitManifestValue "components.notebook.python" $python
    Set-ExakitManifestValue "components.notebook.notebooks_dir" $script:NotebookDir
    Set-ExakitManifestValue "components.notebook.store_file" (Get-NotebookStoreFile)
    Set-ExakitManifestValue "components.notebook.master_file" (Join-Path $script:CredsDir $script:NotebookMasterCred)
    Set-ExakitManifestValue "components.notebook.kernel" $script:NotebookKernelName
    Install-NotebookFrontEnds
    return $true
}

# Test-Notebook - the packages import; with the database up, the connector
# connects from the store. Soft. Twin of notebook_validate.
function Test-Notebook {
    $python = Get-NotebookVenvPython
    if (-not (Test-Path $python)) { return }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $python -c "import exasol.nb_connector, exakit.nb, exakit_nb, exasol_mlflow, ipykernel" 2>$null | Out-Null
        $imports = ($LASTEXITCODE -eq 0)
    } finally { $ErrorActionPreference = $prevEap }
    if (-not $imports) {
        Warn2 "The notebook environment does not import - repair with: exakit update notebook"
        Set-ExakitManifestValue "components.notebook.validated" $false
        return
    }
    if (-not (Test-ExakitDbReachable)) {
        Set-ExakitManifestValue "components.notebook.validated" $true
        Set-ExakitManifestValue "components.notebook.validated_by" "import"
        return
    }
    [void](Write-NotebookConnection)
    if (Test-NotebookConnected) {
        Set-ExakitManifestValue "components.notebook.validated" $true
        Set-ExakitManifestValue "components.notebook.validated_by" "connection"
        Ok "Notebooks connect to the database - open them with: exakit notebook"
    } else {
        Set-ExakitManifestValue "components.notebook.validated" $false
        Warn2 "The notebook connector could not connect - check with: exakit notebook --check"
    }
}

function Update-Notebook {
    $available = Get-ExakitComponentAvailable "notebook"
    if (-not $available) { Fail "Could not resolve the advertised notebook connector version." }
    $current = Get-NotebookInstalledVersion
    if ($current -and $current -eq $available) {
        # The connector pin stands still, but this kit copy may carry new
        # notebooks, new helpers or a new companion package: bring the venv in
        # line with it before the notebooks are copied.
        $script:NotebookVersion = $current
        $script:ExakitActiveLabel = "Refreshing the kit's notebook helpers"
        if (-not (Sync-NotebookPackages)) { Warn2 "The kit's notebook helpers could not be refreshed (see the log) - retry with: exakit update notebook" }
        [void](Copy-NotebookContent)
        if (Test-Path (Get-NotebookMarimoCommand)) { [void](Copy-NotebookContent -Front marimo) }
        Set-ExakitManifestValue "components.notebook.master_file" (Join-Path $script:CredsDir $script:NotebookMasterCred)
        [void](Register-NotebookKernel)
        Test-Notebook
        Ok "notebook is already current ($current); the kit's notebook helpers were refreshed"
        return
    }
    Info "Updating notebook $(if ($current) { $current } else { 'not installed' }) -> $available"
    $script:NotebookVersion = $available
    $env:EXAKIT_FORCE_COMPONENT_INSTALL = "1"
    try {
        if (-not (Install-Notebook)) { Fail "The notebook add-on could not be updated - see the warning above and the log." }
    } finally {
        Remove-Item Env:EXAKIT_FORCE_COMPONENT_INSTALL -ErrorAction SilentlyContinue
    }
    Test-Notebook
    Set-ExakitManifestValue "desired.notebook" $script:NotebookVersion
    Ok "notebook updated; database data was not changed"
}

function Get-NotebookSummary { return "notebooks: exakit notebook" }

# --- JupyterLab on demand --------------------------------------------------------

function Test-NotebookApiAnswers {
    param([string]$Port)
    try {
        $answer = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/api" -TimeoutSec 2
        return ("$($answer.Content)" -like '*"version"*')
    } catch { return $false }
}

# Get-NotebookServerPort - where the JupyterLab the kit started serves: the
# port recorded when it started.
function Get-NotebookServerPort {
    $port = Get-ExakitManifestValue "components.notebook.port"
    if ($port) { return "$port" }
    return $script:NotebookPort
}

# Get-NotebookServerState - running|starting|stopped, from the pid the kit
# recorded (its process still the JupyterLab the kit started) and the API on
# the recorded port. Twin of notebook_server_state.
function Get-NotebookServerState {
    if ($null -ne (Get-NotebookLivePid -PidFile (Get-NotebookPidFile) -Pattern $script:NotebookJupyterMatch)) {
        if (Test-NotebookApiAnswers (Get-NotebookServerPort)) { return "running" }
        return "starting"
    }
    return "stopped"
}

# Write-NotebookJupyterConfig - the kit's JupyterLab settings file, written
# fresh on every start, and its path: the file browser hides the Marimo copies
# (the marimo folder) beside Jupyter's own defaults. Read through --config, so a
# JupyterLab of the user's own is never configured globally. Twin of
# _notebook_jupyter_config.
function Write-NotebookJupyterConfig {
    $path = Join-Path $script:NotebookHome "jupyter_server_config.json"
    Set-Content -Path $path -Encoding Ascii -Value '{"ContentsManager": {"hide_globs": ["__pycache__", "*.pyc", "*.pyo", ".DS_Store", "*~", ".ipynb_checkpoints", "marimo"]}}'
    return $path
}

# Start-NotebookServer - JupyterLab in the background on 127.0.0.1, rooted at
# the notebooks folder, with the token in its environment only. Twin of
# notebook_server_start.
function Start-NotebookServer {
    param([Parameter(Mandatory)][string]$Port)
    $found = Find-NotebookJupyter
    if (-not $found) { return $false }
    if (Test-NotebookApiAnswers $Port) {
        Warn2 "Port $Port already answers for another Jupyter - pick another with: exakit notebook --port <number>"
        return $false
    }
    New-Item -ItemType Directory -Force -Path $script:NotebookHome | Out-Null
    New-Item -ItemType Directory -Force -Path $script:NotebookDir | Out-Null
    $log = Get-NotebookLogFile
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
    $saved = $env:JUPYTER_TOKEN
    $env:JUPYTER_TOKEN = Get-NotebookSecret $script:NotebookTokenCred
    try {
        $proc = Start-Process -FilePath $found[1] -WorkingDirectory $script:NotebookDir -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Get-NotebookOutFile) -RedirectStandardError $log `
            -ArgumentList @("--no-browser", "--ServerApp.ip=127.0.0.1", "--ServerApp.port=$Port", "--ServerApp.port_retries=0", "--ServerApp.root_dir=`"$($script:NotebookDir)`"", "--config=`"$(Write-NotebookJupyterConfig)`"")
    } finally {
        $env:JUPYTER_TOKEN = $saved
    }
    Set-Content -Path (Get-NotebookPidFile) -Value $proc.Id -Encoding Ascii
    Set-ExakitManifestValue "components.notebook.port" $Port
    return (Wait-NotebookUp -Answers ${function:Test-NotebookApiAnswers} -Port $Port -PidFile (Get-NotebookPidFile) `
        -Pattern $script:NotebookJupyterMatch -Label "JupyterLab" -Log $log)
}

# Stop-NotebookServer [-Quiet] - stop the JupyterLab the kit started; a stale
# pid file is only removed. Twin of notebook_server_stop.
function Stop-NotebookServer {
    param([switch]$Quiet)
    $live = Get-NotebookLivePid -PidFile (Get-NotebookPidFile) -Pattern $script:NotebookJupyterMatch
    if ($null -ne $live) {
        Stop-NotebookProcess -Id $live
        Ok "JupyterLab stopped"
    } elseif (-not $Quiet) {
        Info "JupyterLab is not running"
    }
    Remove-Item -Force -ErrorAction SilentlyContinue (Get-NotebookPidFile)
    Remove-Item -Force -ErrorAction SilentlyContinue (Get-NotebookOpenFile "jupyter")
}

# Invoke-NotebookMarimoCmd - `exakit notebook --marimo`: Marimo installed when
# the user says yes (EXAKIT_NOTEBOOK_MARIMO=install|skip answers), then started
# and opened, logged in. $false when it could not be started. Twin of
# notebook_marimo_cmd.
function Invoke-NotebookMarimoCmd {
    param([bool]$Setup, [bool]$Browser, [string]$Port)
    if (-not (Test-Path (Get-NotebookMarimoCommand))) {
        $answer = "$env:EXAKIT_NOTEBOOK_MARIMO".ToLower()
        if (-not $answer) {
            if (Confirm-ExakitPrompt "Marimo is not installed. Install it into the kit's notebook environment" $true) { $answer = "install" } else { $answer = "skip" }
        }
        if ($answer -ne "install") { Info "Marimo was not installed. Add it any time with: exakit notebook --marimo"; return $true }
        if (-not (Install-NotebookMarimo)) { Fail "Marimo could not be installed - see the log." }
        Ok "Marimo installed into the kit's notebook environment"
    }
    $dir = Join-Path $script:NotebookDir "marimo"
    Write-NotebookCopied -Folder $dir -Front marimo
    if ($Setup) { Ok "Ready: Marimo, with the kit's notebooks in $dir"; return $true }
    $state = Get-NotebookMarimoState
    if ($state -eq "stopped") {
        if (-not $Port) { $Port = Get-NotebookMarimoPort }
        if (-not (Start-NotebookMarimo $Port)) { return $false }
    } else {
        # Up, or coming up (a second --marimo right after the first): wait for
        # that one rather than start another over its pid file.
        $running = Get-NotebookMarimoRunningPort
        if ($Port -and $Port -ne $running) {
            Info "Marimo is already running on port $running, so --port $Port is ignored (to move it: exakit notebook --stop --marimo, then exakit notebook --marimo --port $Port)"
        }
        $Port = $running
        if ($state -eq "starting") {
            if (-not (Wait-NotebookUp -Answers ${function:Test-NotebookMarimoAnswers} -Port $Port -PidFile (Get-NotebookMarimoPidFile) `
                    -Pattern $script:NotebookMarimoMatch -Label "Marimo" -Log (Get-NotebookMarimoLogFile))) { return $false }
        }
    }
    Ok "Marimo is running: http://127.0.0.1:$Port/   (stop it with: exakit notebook --stop --marimo)"
    Info "Marimo notebooks connect with: import exakit.nb as nb; conn = nb.connect()"
    if ($Browser) {
        if (-not (Open-NotebookLoggedIn -Front "marimo" -Url "http://127.0.0.1:$Port/?access_token=$(Get-NotebookSecret $script:NotebookMarimoCred)")) {
            Info "Open http://127.0.0.1:$Port/ - the login token is in $(Join-Path $script:CredsDir $script:NotebookMarimoCred)"
        }
    }
    return $true
}

# Invoke-NotebookPositronCmd - `exakit notebook --positron`: the notebooks
# folder set to the kit's Python, then opened in the user's Positron. Never
# installs it. Twin of notebook_positron_cmd.
function Invoke-NotebookPositronCmd {
    if (-not (Set-NotebookPositronFolder)) {
        Fail "The kit leaves $(Join-Path (Join-Path $script:NotebookDir '.vscode') 'settings.json') alone (see above) - choose the interpreter $(Get-NotebookVenvPython) in Positron yourself"
    }
    Add-NotebookFrontEnd "positron"
    $found = Find-NotebookPositron
    if ($found) {
        Start-Process -FilePath $found -ArgumentList @("`"$($script:NotebookDir)`"") | Out-Null
        Ok "Positron opened on $($script:NotebookDir) with the kit's Python ($(Get-NotebookVenvPython))"
    } else {
        Info "Positron is not on this machine. The folder is ready for it - get it at $($script:NotebookPositronDownload), then run: exakit notebook --positron"
    }
    Info "In a notebook or script: import exakit.nb as nb; conn = nb.connect()"
}

# Invoke-CmdNotebook - `exakit notebook [--marimo|--positron] [--check]
# [--setup] [--stop] [--no-browser] [--port N]`. Options are matched exactly,
# case and all, as the shell side does. A server that could not be started
# makes the command exit 1. Twin of notebook_cmd.
function Invoke-CmdNotebook {
    param([string[]]$CmdArgs = @())
    $check = $false; $setup = $false; $stop = $false; $browser = $true; $port = ""; $front = ""
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        switch -CaseSensitive ($CmdArgs[$i]) {
            { $_ -ceq "--marimo" -or $_ -ceq "--positron" } {
                $wanted = $CmdArgs[$i].Substring(2)
                if ($front -and $front -ne $wanted) { Fail "Pick one of --marimo and --positron" }
                $front = $wanted
            }
            "--check" { $check = $true }
            "--setup" { $setup = $true }
            "--stop" { $stop = $true }
            "--no-browser" { $browser = $false }
            "--port" {
                $i++
                $value = if ($i -lt $CmdArgs.Count) { "$($CmdArgs[$i])" } else { "" }
                # Checked as text first: [int] of a long string of digits throws.
                if ($value -notmatch '^\d{1,5}$' -or [int]$value -lt 1024 -or [int]$value -gt 65535) { Fail "--port needs a number between 1024 and 65535" }
                $port = $value
            }
            default { Fail "Unknown option for exakit notebook: $($CmdArgs[$i]) (see: exakit help notebook)" }
        }
    }
    if (-not (Get-NotebookInstalledVersion)) { Fail "The notebook add-on is not installed. Install it with: exakit marketplace notebook" }
    if ($stop) {
        if ($front -eq "marimo") { Stop-NotebookMarimo }
        elseif ($front -eq "positron") { Info "Positron is yours to close; the kit does not run it" }
        else { Stop-NotebookServer; Stop-NotebookMarimo -Quiet }
        return
    }
    if (-not (Test-ExakitDbReachable)) { Fail "The database is not running. Start it with: exakit start" }
    $connection = Write-NotebookConnection
    if ($null -eq $connection) { Warn2 "The notebooks' connection could not be refreshed (see the log) - repair with: exakit update notebook" }
    elseif ($connection -eq "changed") { Info "The database connection changed; the notebooks now use the new one" }
    if (-not (Register-NotebookKernel)) { Warn2 "The kernel could not be registered again (see the log)." }
    Write-NotebookCopied -Folder (Join-Path $script:NotebookDir "starter-kit-notebooks")
    if ($check) {
        if (-not (Test-NotebookConnected)) { Fail "The notebook connector could not connect to the database. Repair with: exakit update notebook" }
        Ok "Notebooks connect to the database"
        Info "JupyterLab: $(Get-NotebookServerState)   Marimo: $(Get-NotebookMarimoState)   Notebooks: $($script:NotebookDir)"
        return
    }
    if ($front -eq "marimo") {
        if (-not (Invoke-NotebookMarimoCmd -Setup $setup -Browser $browser -Port $port)) { $script:PendingExitCode = 1 }
        return
    }
    if ($front -eq "positron") { Invoke-NotebookPositronCmd; return }
    if (-not (Confirm-NotebookJupyter)) { return }
    if ($setup) {
        Add-NotebookFrontEnd "jupyterlab"
        Ok "Ready: $((Find-NotebookJupyter)[1]) with the kernel '$($script:NotebookKernelTitle)'"
        return
    }
    $state = Get-NotebookServerState
    if ($state -eq "stopped") {
        if (-not $port) { $port = Get-NotebookServerPort }
        if (-not (Start-NotebookServer $port)) { $script:PendingExitCode = 1; return }
    } else {
        # One the kit started is up, or coming up (a second `exakit notebook`
        # right after the first): use it, on the port it was started on, and
        # never start a second one over its pid file.
        $running = Get-NotebookServerPort
        if ($port -and $port -ne $running) {
            Info "JupyterLab is already running on port $running, so --port $port is ignored (to move it: exakit notebook --stop, then exakit notebook --port $port)"
        }
        $port = $running
        if ($state -eq "starting") {
            if (-not (Wait-NotebookUp -Answers ${function:Test-NotebookApiAnswers} -Port $port -PidFile (Get-NotebookPidFile) `
                    -Pattern $script:NotebookJupyterMatch -Label "JupyterLab" -Log (Get-NotebookLogFile))) { $script:PendingExitCode = 1; return }
        }
    }
    Ok "JupyterLab is running: http://127.0.0.1:$port/lab   (stop it with: exakit notebook --stop)"
    if ($browser) {
        if (-not (Open-NotebookLoggedIn -Front "jupyter" -Url "http://127.0.0.1:$port/lab?token=$(Get-NotebookSecret $script:NotebookTokenCred)")) {
            Info "Open http://127.0.0.1:$port/lab - the login token is in $(Join-Path $script:CredsDir $script:NotebookTokenCred)"
        }
    }
}

# Test-NotebookNotebooksGo - does this uninstall delete the notebooks folder?
# Only a full kit uninstall ($script:ExakitUninstallFull) asked to with
# EXAKIT_UNINSTALL_NOTEBOOKS=remove, and only for a folder inside the kit home.
# Twin of _notebook_notebooks_go.
function Test-NotebookNotebooksGo {
    if (-not $script:ExakitUninstallFull) { return $false }
    if ("$env:EXAKIT_UNINSTALL_NOTEBOOKS".ToLower() -ne "remove") { return $false }
    try {
        $kitHome = [System.IO.Path]::GetFullPath($script:ExakitHome).TrimEnd('\', '/')
        $dir = [System.IO.Path]::GetFullPath($script:NotebookDir)
    } catch { return $false }
    return $dir.StartsWith($kitHome + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

# Uninstall-Notebook - the kernel, the venv, the store and the servers go, and
# the kit's two settings come out of the notebooks folder's
# .vscode\settings.json; the notebooks folder (with any MLflow store beside
# the notebooks) and the user's own JupyterLab stay. A full kit uninstall keeps
# the folder too, unless EXAKIT_UNINSTALL_NOTEBOOKS=remove. Twin of
# notebook_uninstall.
function Uninstall-Notebook {
    param([switch]$DryRun)
    $settings = Join-Path (Join-Path $script:NotebookDir ".vscode") "settings.json"
    foreach ($path in @($script:NotebookVenv, (Get-NotebookStoreFile))) {
        if ($DryRun -and (Test-Path $path)) { Info "  will remove: $path" }
    }
    if ($DryRun) {
        if (Test-Path $settings) { Info "  will remove: the kit's interpreter settings from $settings" }
        if (Test-NotebookNotebooksGo) { Info "  will remove: your notebooks in $($script:NotebookDir) (EXAKIT_UNINSTALL_NOTEBOOKS=remove)" }
        elseif (Test-Path $script:NotebookDir) { Info "  your notebooks stay in $($script:NotebookDir)" }
        return $true
    }
    Stop-NotebookServer -Quiet | Out-Null
    Stop-NotebookMarimo -Quiet | Out-Null
    Unregister-NotebookKernel
    if (Test-Path $settings) {
        [void](Invoke-NotebookFolders "positron-remove" $script:NotebookDir (Get-NotebookVenvPython) $script:NotebookVenv)
    }
    foreach ($path in @($script:NotebookVenv, (Get-NotebookStoreFile), (Get-NotebookPidFile), (Get-NotebookMarimoPidFile),
                        (Get-NotebookOpenFile "jupyter"), (Get-NotebookOpenFile "marimo"))) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $path
    }
    if ((Test-Path $script:NotebookHome) -and -not @(Get-ChildItem -Force -Path $script:NotebookHome -ErrorAction SilentlyContinue).Count) {
        Remove-Item -Force -ErrorAction SilentlyContinue $script:NotebookHome
    }
    foreach ($name in @($script:NotebookMasterCred, $script:NotebookTokenCred, $script:NotebookMarimoCred)) {
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $script:CredsDir $name)
    }
    Remove-ExakitManifestValue "components.notebook"
    Remove-ExakitManifestValue "desired.notebook"
    if (Test-NotebookNotebooksGo) { Info "Your notebooks in $($script:NotebookDir) go with the kit home (EXAKIT_UNINSTALL_NOTEBOOKS=remove)" }
    elseif (Test-Path $script:NotebookDir) { Info "Your notebooks stay in $($script:NotebookDir)" }
    OkStep "notebook removed - reinstall any time with: exakit marketplace notebook"
    return $true
}
