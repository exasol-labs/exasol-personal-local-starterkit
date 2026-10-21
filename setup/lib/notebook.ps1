# notebook.ps1 - notebook (Jupyter notebooks connected to the local database):
# managed install + validation + the `exakit notebook` command. Twin of
# setup/lib/notebook.sh; read that header for the facts. The Python steps (the
# encrypted store, the kernel, the connection check) are the shared scripts in
# notebook/kit/, so the two sides cannot drift there.
#
#   - venv:      $ExakitHome\notebook-venv
#   - store:     $ExakitHome\notebook\connection.scs
#   - notebooks: $ExakitHome\notebooks\starter-kit-notebooks\<persona>\ and
#                ...\marimo\<persona>\ (notebook\catalog.json; copied once,
#                never overwritten; kept by an uninstall)
#   - the notebook tools: one checklist at the install, JupyterLab, Marimo and
#     Positron all ticked; Positron is only ever configured, never installed.

$script:NotebookPackage = "exasol-notebook-connector"
$script:NotebookVersionFallback = if ($env:EXAKIT_NOTEBOOK_VERSION_FALLBACK) { $env:EXAKIT_NOTEBOOK_VERSION_FALLBACK } else { "3.1.0" }
$script:NotebookVersion = if ($env:EXAKIT_NOTEBOOK_VERSION) { $env:EXAKIT_NOTEBOOK_VERSION } else { "" }
$script:NotebookVenv = if ($env:EXAKIT_NOTEBOOK_VENV) { $env:EXAKIT_NOTEBOOK_VENV } else { Join-Path $script:ExakitHome "notebook-venv" }
$script:NotebookHome = if ($env:EXAKIT_NOTEBOOK_HOME) { $env:EXAKIT_NOTEBOOK_HOME } else { Join-Path $script:ExakitHome "notebook" }
$script:NotebookDir = if ($env:EXAKIT_NOTEBOOK_DIR) { $env:EXAKIT_NOTEBOOK_DIR } else { Join-Path $script:ExakitHome "notebooks" }
$script:NotebookPort = if ($env:EXAKIT_NOTEBOOK_PORT) { $env:EXAKIT_NOTEBOOK_PORT } else { "8888" }
$script:NotebookExtras = "bucketfs,ibis,pyexasol,sqlalchemy"
$script:NotebookPackages = @("ipykernel>=6.29,<8", "langfuse>=3,<4", "openai>=1.40,<3", "scikit-learn>=1.4,<2", "mlflow-skinny>=2.14,<4", "alembic>=1.13,<2")
$script:NotebookJupyterLab = "jupyterlab>=4.2,<5"
$script:NotebookKernelName = "exasol-starter-kit"
$script:NotebookKernelTitle = "Exasol (Starter Kit)"
$script:NotebookInstallGuide = "https://jupyter.org/install"
$script:NotebookMasterCred = "notebook_store_master_password"
$script:NotebookTokenCred = "notebook_jupyter_token"
$script:NotebookMarimoCred = "notebook_marimo_token"
$script:NotebookMarimoPackage = "marimo>=0.25.2,<0.26"
$script:NotebookMarimoPort = if ($env:EXAKIT_MARIMO_PORT) { $env:EXAKIT_MARIMO_PORT } else { "2718" }
$script:NotebookPositronDownload = "https://positron.posit.co/download.html"

function Get-NotebookVenvPython { return (Join-Path $script:NotebookVenv "Scripts\python.exe") }
function Get-NotebookStoreFile { return (Join-Path $script:NotebookHome "connection.scs") }
function Get-NotebookPidFile { return (Join-Path $script:NotebookHome "jupyter.pid") }
function Get-NotebookLogFile {
    $dir = if ($script:LogDir) { $script:LogDir } else { Join-Path $script:ExakitHome "logs" }
    return (Join-Path $dir "notebook.log")
}
function Get-NotebookMarimoPidFile { return (Join-Path $script:NotebookHome "marimo.pid") }
function Get-NotebookMarimoLogFile { return (Join-Path (Split-Path -Parent (Get-NotebookLogFile)) "notebook-marimo.log") }
function Get-NotebookMarimoCommand { return (Join-Path (Join-Path $script:NotebookVenv "Scripts") "marimo.exe") }

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
# notebooks and prepares the folder for Positron: standard library only, so
# the venv's Python, the system one or uv's runs it. Returns @(exit code,
# output lines). Twin of _notebook_folders.
function Invoke-NotebookFolders {
    param([Parameter(ValueFromRemainingArguments)]$FolderArgs)
    $script = Join-Path (Join-Path (Join-Path (Get-ExakitRepoRoot) "notebook") "kit") "notebooks.py"
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $venvPython = Get-NotebookVenvPython
        if (Test-Path $venvPython) {
            $lines = @(& $venvPython $script @FolderArgs 2>$null | ForEach-Object { "$_" })
        } elseif (Test-ExakitSystemPython) {
            $lines = @(& python $script @FolderArgs 2>$null | ForEach-Object { "$_" })
        } else {
            $uv = Get-NotebookUv
            $lines = @(& $uv run --python $script:ManagedPythonVersion --no-project python $script @FolderArgs 2>$null | ForEach-Object { "$_" })
        }
        $code = $LASTEXITCODE
    } catch {
        $lines = @(); $code = 1
    } finally {
        $ErrorActionPreference = $prevEap
    }
    return ,@($code, $lines)
}

# Copy-NotebookContent [-Front jupyter|marimo] - the kit's notebooks into their
# persona folders, as notebook\catalog.json says; one already there is the
# user's and is never overwritten. Returns persona/file per one added. Twin of
# notebook_copy_notebooks.
function Copy-NotebookContent {
    param([ValidateSet("jupyter", "marimo")][string]$Front = "jupyter")
    New-Item -ItemType Directory -Force -Path $script:NotebookDir | Out-Null
    $result = Invoke-NotebookFolders "copy" $Front (Get-ExakitRepoRoot) $script:NotebookDir
    return @($result[1] | Where-Object { $_ })
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
        $uv = Get-NotebookUv
        if ($uv) {
            $script:ExakitActiveLabel = "Installing JupyterLab"
            if ((Invoke-ExakitLogged $uv "pip" "install" "--python" (Get-NotebookVenvPython) $script:NotebookJupyterLab) -eq 0) {
                Set-ExakitManifestValue "components.notebook.jupyter" "kit"
                Ok "JupyterLab installed into the kit's notebook environment"
                return $true
            }
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

# Get-NotebookFrontEnds - which notebook tools, as one checklist with all three
# ticked: jupyterlab, marimo, positron (or none). EXAKIT_NOTEBOOK_FRONTENDS
# answers it; EXAKIT_NOTEBOOK_JUPYTER / EXAKIT_NOTEBOOK_MARIMO=skip leave one
# out; without a console the ticks stand. Twin of notebook_choose_front_ends.
function Get-NotebookFrontEnds {
    $given = ("$env:EXAKIT_NOTEBOOK_FRONTENDS".ToLower() -replace '\s', '')
    if ($given) { return $given }
    $keys = @("jupyterlab", "marimo", "positron")
    $defaults = @()
    if (-not (Test-NotebookSkipped $env:EXAKIT_NOTEBOOK_JUPYTER)) { $defaults += 1 }
    if (-not (Test-NotebookSkipped $env:EXAKIT_NOTEBOOK_MARIMO)) { $defaults += 2 }
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

# Install-NotebookFrontEnds - the install's notebook tools, one line each.
# Twin of notebook_front_ends_setup.
function Install-NotebookFrontEnds {
    $fronts = @((Get-NotebookFrontEnds) -split ',')
    if ($fronts -contains "jupyterlab") {
        $found = Find-NotebookJupyter
        if ($found) {
            $whose = if ($found[0] -eq "kit") { "the kit's" } else { "yours" }
            Ok "JupyterLab ($($whose): $($found[1])) with the kernel '$($script:NotebookKernelTitle)' - open it with: exakit notebook"
        } else {
            $saved = $env:EXAKIT_NOTEBOOK_JUPYTER
            $env:EXAKIT_NOTEBOOK_JUPYTER = "install"
            try { [void](Confirm-NotebookJupyter) } finally { $env:EXAKIT_NOTEBOOK_JUPYTER = $saved }
        }
    } else {
        Info "JupyterLab not set up; the kernel '$($script:NotebookKernelTitle)' is registered for any Jupyter - add it any time: exakit notebook --setup"
    }
    if ($fronts -contains "marimo") {
        if ((Test-Path (Get-NotebookMarimoCommand)) -or (Install-NotebookMarimo)) {
            Ok "Marimo with the notebooks in $(Join-Path $script:NotebookDir 'marimo') - start it with: exakit notebook --marimo"
        } else {
            Warn2 "Marimo could not be installed (see the log) - retry with: exakit notebook --marimo"
        }
    } else {
        Info "Marimo not installed - add it any time: exakit notebook --marimo"
    }
    if ($fronts -contains "positron") { Write-NotebookPositronNote } else { Info "Positron not set up - any time: exakit notebook --positron" }
    Set-ExakitManifestValue "components.notebook.front_ends" ($fronts -join ",")
}

# Install-NotebookMarimo - Marimo into the kit's notebook environment, then the
# kit's Marimo notebooks into marimo\<persona>\. Twin of notebook_install_marimo.
function Install-NotebookMarimo {
    $uv = Get-NotebookUv
    if (-not $uv) { return $false }
    $script:ExakitActiveLabel = "Installing Marimo"
    if ((Invoke-ExakitLogged $uv "pip" "install" "--python" (Get-NotebookVenvPython) $script:NotebookMarimoPackage) -ne 0) { return $false }
    if (-not (Test-Path (Get-NotebookMarimoCommand))) { return $false }
    [void](Copy-NotebookContent -Front marimo)
    Set-ExakitManifestValue "components.notebook.marimo" "kit"
    return $true
}

function Test-NotebookMarimoAnswers {
    param([string]$Port)
    try {
        [void](Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3)
        return $true
    } catch {
        $response = $_.Exception.Response
        return ($null -ne $response -and [int]$response.StatusCode -lt 500)
    }
}

function Get-NotebookMarimoPort {
    if ($env:EXAKIT_MARIMO_PORT) { return $env:EXAKIT_MARIMO_PORT }
    $recorded = Get-ExakitManifestValue "components.notebook.marimo_port"
    if ($recorded) { return $recorded }
    return $script:NotebookMarimoPort
}

# Get-NotebookMarimoState - running|starting|stopped|not installed. Twin of
# notebook_marimo_state.
function Get-NotebookMarimoState {
    if (-not (Test-Path (Get-NotebookMarimoCommand))) { return "not installed" }
    $pidFile = Get-NotebookMarimoPidFile
    $pidText = if (Test-Path $pidFile) { (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1) } else { "" }
    if ($pidText -and (Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue)) {
        if (Test-NotebookMarimoAnswers (Get-NotebookMarimoPort)) { return "running" }
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
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
        -ArgumentList @("`"$wrapper`"", "`"$token`"", "`"$(Get-NotebookMarimoCommand)`"", "edit", "`"$dir`"", "--headless",
                        "--host", "127.0.0.1", "--port", $Port, "--token-password-file", "`"$token`"", "--skip-update-check")
    Set-Content -Path (Get-NotebookMarimoPidFile) -Value $proc.Id -Encoding Ascii
    Set-ExakitManifestValue "components.notebook.marimo_port" $Port
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-NotebookMarimoAnswers $Port) { return $true }
        Start-Sleep -Seconds 1
    }
    Warn2 "Marimo did not answer within 60s - see $log"
    return $false
}

function Stop-NotebookMarimo {
    param([switch]$Quiet)
    $pidFile = Get-NotebookMarimoPidFile
    $pidText = if (Test-Path $pidFile) { (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1) } else { "" }
    if ($pidText -and (Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue)) {
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & taskkill /PID $pidText /T /F 2>$null | Out-Null
        } finally { $ErrorActionPreference = $prevEap }
        Ok "Marimo stopped (your notebooks are saved in their folder)"
    } elseif (-not $Quiet) {
        Info "Marimo is not running"
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $pidFile
}

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
# whose interpreter is the kit's notebook Python; $false (the file left alone)
# when its settings file is not valid JSON. Twin of notebook_prepare_positron.
function Set-NotebookPositronFolder {
    $result = Invoke-NotebookFolders "positron" $script:NotebookDir (Get-NotebookVenvPython) $script:NotebookVenv
    return ($result[0] -eq 0)
}

# Write-NotebookPositronNote - configure the folder for Positron and say what
# came of it. Twin of notebook_positron_note.
function Write-NotebookPositronNote {
    if (-not (Set-NotebookPositronFolder)) {
        Warn2 "$(Join-Path $script:NotebookDir '.vscode\settings.json') is not valid JSON, so it was left alone - choose the interpreter $(Get-NotebookVenvPython) in Positron yourself"
        return
    }
    $found = Find-NotebookPositron
    if ($found) {
        Ok "Positron ($found) opens the notebooks with the kit's Python: exakit notebook --positron"
    } else {
        Info "Positron is not on this machine, so there is nothing to configure in it - the notebooks folder is ready for it: $($script:NotebookPositronDownload)"
    }
}

function Get-NotebookSpecs {
    $root = Get-ExakitRepoRoot
    $specs = @("$($script:NotebookPackage)[$($script:NotebookExtras)]==$($script:NotebookVersion)")
    $specs += $script:NotebookPackages
    $specs += (Join-Path (Join-Path $root "notebook") "package")
    $specs += (Join-Path (Join-Path $root "packages") "exasol-mlflow")
    return $specs
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
    $python = Get-NotebookVenvPython
    $current = Get-NotebookPackageVersion
    if ($current -and $current -eq $script:NotebookVersion -and $env:EXAKIT_FORCE_COMPONENT_INSTALL -ne "1") {
        Ok "notebook $current already installed: $script:NotebookVenv"
    } else {
        $script:ExakitActiveLabel = "Installing the notebook connector $($script:NotebookVersion)"
        Info "Installing the notebook connector $($script:NotebookVersion) (about 1 GB: it brings PyTorch for its transformer features)"
        if (-not (Test-Path $python)) {
            if ((Invoke-ExakitLogged $uv "venv" "--python" $script:ManagedPythonVersion $script:NotebookVenv) -ne 0) {
                return (Write-NotebookNotInstalled "the virtual environment at $script:NotebookVenv could not be created (see log)")
            }
        }
        $args = @("pip", "install", "--python", $python) + (Get-NotebookSpecs)
        if ((Invoke-ExakitLogged $uv @args) -ne 0) {
            return (Write-NotebookNotInstalled "installing $($script:NotebookPackage)==$($script:NotebookVersion) and its companions failed (see log)")
        }
        if (-not (Get-NotebookPackageVersion)) {
            return (Write-NotebookNotInstalled "the venv cannot report a $($script:NotebookPackage) version after the install (see log)")
        }
        Ok "Notebook connector installed: $script:NotebookVenv"
    }
    $added = @(Copy-NotebookContent)
    if ($added.Count) { Ok "Notebooks in $(Join-Path $script:NotebookDir 'starter-kit-notebooks'): $($added -join ', ')" }
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
        & $python -c "import exasol.nb_connector, exakit_nb, exasol_mlflow, ipykernel" 2>$null | Out-Null
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
        [void](Copy-NotebookContent)
        if (Test-Path (Get-NotebookMarimoCommand)) { [void](Copy-NotebookContent -Front marimo) }
        Set-ExakitManifestValue "components.notebook.master_file" (Join-Path $script:CredsDir $script:NotebookMasterCred)
        [void](Register-NotebookKernel)
        Test-Notebook
        Ok "notebook is already current ($current)"
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
        $answer = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/api" -TimeoutSec 3
        return ("$($answer.Content)" -like '*"version"*')
    } catch { return $false }
}

# Get-NotebookServerState - running|starting|stopped, from the pid the kit
# recorded and the API on the recorded port. Twin of notebook_server_state.
function Get-NotebookServerState {
    $pidText = if (Test-Path (Get-NotebookPidFile)) { (Get-Content (Get-NotebookPidFile) -ErrorAction SilentlyContinue | Select-Object -First 1) } else { "" }
    $port = Get-ExakitManifestValue "components.notebook.port"
    if (-not $port) { $port = $script:NotebookPort }
    if ($pidText -and (Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue)) {
        if (Test-NotebookApiAnswers $port) { return "running" }
        return "starting"
    }
    return "stopped"
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
    $log = Get-NotebookLogFile
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
    $saved = $env:JUPYTER_TOKEN
    $env:JUPYTER_TOKEN = Get-NotebookSecret $script:NotebookTokenCred
    try {
        $proc = Start-Process -FilePath $found[1] -WorkingDirectory $script:NotebookDir -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
            -ArgumentList @("--no-browser", "--ServerApp.ip=127.0.0.1", "--ServerApp.port=$Port", "--ServerApp.port_retries=0", "--ServerApp.root_dir=`"$($script:NotebookDir)`"")
    } finally {
        $env:JUPYTER_TOKEN = $saved
    }
    Set-Content -Path (Get-NotebookPidFile) -Value $proc.Id -Encoding Ascii
    Set-ExakitManifestValue "components.notebook.port" $Port
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-NotebookApiAnswers $Port) { return $true }
        Start-Sleep -Seconds 1
    }
    Warn2 "JupyterLab did not answer within 60s - see $log"
    return $false
}

function Stop-NotebookServer {
    $pidFile = Get-NotebookPidFile
    $pidText = if (Test-Path $pidFile) { (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1) } else { "" }
    if ($pidText -and (Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue)) {
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & taskkill /PID $pidText /T /F 2>$null | Out-Null
        } finally { $ErrorActionPreference = $prevEap }
        Ok "JupyterLab stopped"
    } else {
        Info "JupyterLab is not running"
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $pidFile
}

# Invoke-NotebookMarimoCmd - `exakit notebook --marimo`: Marimo installed when
# the user says yes (EXAKIT_NOTEBOOK_MARIMO=install|skip answers), then started
# and opened, logged in. Twin of notebook_marimo_cmd.
function Invoke-NotebookMarimoCmd {
    param([bool]$Setup, [bool]$Browser, [string]$Port)
    if (-not (Test-Path (Get-NotebookMarimoCommand))) {
        $answer = "$env:EXAKIT_NOTEBOOK_MARIMO".ToLower()
        if (-not $answer) {
            if (Confirm-ExakitPrompt "Marimo is not installed. Install it into the kit's notebook environment" $true) { $answer = "install" } else { $answer = "skip" }
        }
        if ($answer -ne "install") { Info "Marimo was not installed. Add it any time with: exakit notebook --marimo"; return }
        if (-not (Install-NotebookMarimo)) { Fail "Marimo could not be installed - see the log." }
        Ok "Marimo installed into the kit's notebook environment"
    }
    $dir = Join-Path $script:NotebookDir "marimo"
    $added = @(Copy-NotebookContent -Front marimo)
    if ($added.Count) { Ok "New notebooks in $($dir): $($added -join ', ')" }
    if ($Setup) { Ok "Ready: Marimo, with the kit's notebooks in $dir"; return }
    if (-not $Port) { $Port = Get-NotebookMarimoPort }
    if ((Get-NotebookMarimoState) -ne "running") {
        if (-not (Start-NotebookMarimo $Port)) { return }
    } else {
        $Port = Get-NotebookMarimoPort
    }
    Ok "Marimo is running: http://127.0.0.1:$Port/   (stop it with: exakit notebook --stop --marimo)"
    Info "Marimo notebooks connect with: import exakit_nb; conn = exakit_nb.connect()"
    if ($Browser) {
        try {
            Start-Process "http://127.0.0.1:$Port/?access_token=$(Get-NotebookSecret $script:NotebookMarimoCred)"
        } catch {
            Info "Open http://127.0.0.1:$Port/ - the login token is in $(Join-Path $script:CredsDir $script:NotebookMarimoCred)"
        }
    }
}

# Invoke-NotebookPositronCmd - `exakit notebook --positron`: the notebooks
# folder set to the kit's Python, then opened in the user's Positron. Never
# installs it. Twin of notebook_positron_cmd.
function Invoke-NotebookPositronCmd {
    if (-not (Set-NotebookPositronFolder)) {
        Fail "$(Join-Path $script:NotebookDir '.vscode\settings.json') is not valid JSON, so the kit leaves it alone - choose the interpreter $(Get-NotebookVenvPython) in Positron yourself"
    }
    $found = Find-NotebookPositron
    if ($found) {
        Start-Process -FilePath $found -ArgumentList @("`"$($script:NotebookDir)`"") | Out-Null
        Ok "Positron opened on $($script:NotebookDir) with the kit's Python ($(Get-NotebookVenvPython))"
    } else {
        Info "Positron is not on this machine. The folder is ready for it - get it at $($script:NotebookPositronDownload), then run: exakit notebook --positron"
    }
    Info "In a notebook or script: import exakit_nb; conn = exakit_nb.connect()"
}

# Invoke-CmdNotebook - `exakit notebook [--marimo|--positron] [--check]
# [--setup] [--stop] [--no-browser] [--port N]`. Twin of notebook_cmd.
function Invoke-CmdNotebook {
    param([string[]]$CmdArgs = @())
    $check = $false; $setup = $false; $stop = $false; $browser = $true; $port = ""; $front = ""
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        switch ($CmdArgs[$i]) {
            { $_ -eq "--marimo" -or $_ -eq "--positron" } {
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
                $value = if ($i -lt $CmdArgs.Count) { $CmdArgs[$i] } else { "" }
                if ($value -notmatch '^\d+$' -or [int]$value -lt 1024 -or [int]$value -gt 65535) { Fail "--port needs a number between 1024 and 65535" }
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
    if ((Write-NotebookConnection) -eq "changed") { Info "The database connection changed; the notebooks now use the new one" }
    if (-not (Register-NotebookKernel)) { Warn2 "The kernel could not be registered again (see the log)." }
    $added = @(Copy-NotebookContent)
    if ($added.Count) { Ok "New notebooks in $($script:NotebookDir): $($added -join ', ')" }
    if ($check) {
        if (-not (Test-NotebookConnected)) { Fail "The notebook connector could not connect to the database. Repair with: exakit update notebook" }
        Ok "Notebooks connect to the database"
        Info "JupyterLab: $(Get-NotebookServerState)   Marimo: $(Get-NotebookMarimoState)   Notebooks: $($script:NotebookDir)"
        return
    }
    if ($front -eq "marimo") { Invoke-NotebookMarimoCmd -Setup $setup -Browser $browser -Port $port; return }
    if ($front -eq "positron") { Invoke-NotebookPositronCmd; return }
    if (-not (Confirm-NotebookJupyter)) { return }
    if ($setup) {
        Ok "Ready: $((Find-NotebookJupyter)[1]) with the kernel '$($script:NotebookKernelTitle)'"
        return
    }
    if (-not $port) { $port = Get-ExakitManifestValue "components.notebook.port" }
    if (-not $port) { $port = $script:NotebookPort }
    if ((Get-NotebookServerState) -ne "running") {
        if (-not (Start-NotebookServer $port)) { return }
    }
    Ok "JupyterLab is running: http://127.0.0.1:$port/lab   (stop it with: exakit notebook --stop)"
    if ($browser) {
        try {
            Start-Process "http://127.0.0.1:$port/lab?token=$(Get-NotebookSecret $script:NotebookTokenCred)"
        } catch {
            Info "Open http://127.0.0.1:$port/lab - the login token is in $(Join-Path $script:CredsDir $script:NotebookTokenCred)"
        }
    }
}

# Uninstall-Notebook - the kernel, the venv, the store and the server go; the
# notebooks folder and the user's own JupyterLab stay. Twin of
# notebook_uninstall.
function Uninstall-Notebook {
    param([switch]$DryRun)
    foreach ($path in @($script:NotebookVenv, (Get-NotebookStoreFile))) {
        if ($DryRun -and (Test-Path $path)) { Info "  will remove: $path" }
    }
    if ($DryRun) {
        Info "  your notebooks stay in $($script:NotebookDir)"
        return $true
    }
    Stop-NotebookServer | Out-Null
    Stop-NotebookMarimo -Quiet | Out-Null
    Unregister-NotebookKernel
    foreach ($path in @($script:NotebookVenv, (Get-NotebookStoreFile), (Get-NotebookPidFile), (Get-NotebookMarimoPidFile))) {
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
    Info "Your notebooks stay in $($script:NotebookDir)"
    OkStep "notebook removed - reinstall any time with: exakit marketplace notebook"
    return $true
}
