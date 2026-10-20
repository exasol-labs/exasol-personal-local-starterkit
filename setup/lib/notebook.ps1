# notebook.ps1 - notebook (Jupyter notebooks connected to the local database):
# managed install + validation + the `exakit notebook` command. Twin of
# setup/lib/notebook.sh; read that header for the facts. The Python steps (the
# encrypted store, the kernel, the connection check) are the shared scripts in
# notebook/kit/, so the two sides cannot drift there.
#
#   - venv:      $ExakitHome\notebook-venv
#   - store:     $ExakitHome\notebook\connection.scs
#   - notebooks: $ExakitHome\notebooks (copied once, never overwritten; kept by
#                an uninstall)

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

function Get-NotebookVenvPython { return (Join-Path $script:NotebookVenv "Scripts\python.exe") }
function Get-NotebookStoreFile { return (Join-Path $script:NotebookHome "connection.scs") }
function Get-NotebookPidFile { return (Join-Path $script:NotebookHome "jupyter.pid") }
function Get-NotebookLogFile {
    $dir = if ($script:LogDir) { $script:LogDir } else { Join-Path $script:ExakitHome "logs" }
    return (Join-Path $dir "notebook.log")
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

# Copy-NotebookContent - the kit's notebooks into the user's folder; one
# already there is the user's and is never overwritten. Returns the added
# names. Twin of notebook_copy_notebooks.
function Copy-NotebookContent {
    New-Item -ItemType Directory -Force -Path $script:NotebookDir | Out-Null
    $source = Join-Path (Join-Path (Get-ExakitRepoRoot) "notebook") "notebooks"
    $added = @()
    foreach ($file in @(Get-ChildItem -Path $source -Filter "*.ipynb" -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $target = Join-Path $script:NotebookDir $file.Name
        if (Test-Path $target) { continue }
        Copy-Item -Path $file.FullName -Destination $target
        $added += $file.Name
    }
    return $added
}

function Register-NotebookKernel {
    [void](Get-NotebookSecret $script:NotebookMasterCred)
    $result = Invoke-NotebookPy -Script "register_kernel.py" -Env @{
        EXAKIT_KERNEL_NAME = $script:NotebookKernelName; EXAKIT_KERNEL_TITLE = $script:NotebookKernelTitle
        EXAKIT_NB_STORE = (Get-NotebookStoreFile); EXAKIT_NB_MASTER_FILE = (Join-Path $script:CredsDir $script:NotebookMasterCred)
        EXAKIT_NB_DATASETS = (Join-Path (Join-Path (Get-ExakitRepoRoot) "data") "datasets") }
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
    if ($added.Count) { Ok "Notebooks in $($script:NotebookDir): $($added -join ', ')" }
    if (-not (Register-NotebookKernel)) {
        return (Write-NotebookNotInstalled "the Jupyter kernel could not be registered (see log)")
    }
    Ok "Kernel registered: $($script:NotebookKernelTitle)"
    Set-ExakitManifestValue "components.notebook.version" $script:NotebookVersion
    Set-ExakitManifestValue "components.notebook.venv" $script:NotebookVenv
    Set-ExakitManifestValue "components.notebook.python" $python
    Set-ExakitManifestValue "components.notebook.notebooks_dir" $script:NotebookDir
    Set-ExakitManifestValue "components.notebook.store_file" (Get-NotebookStoreFile)
    Set-ExakitManifestValue "components.notebook.kernel" $script:NotebookKernelName
    [void](Confirm-NotebookJupyter)
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

# Invoke-CmdNotebook - `exakit notebook [--check] [--setup] [--stop]
# [--no-browser] [--port N]`. Twin of notebook_cmd.
function Invoke-CmdNotebook {
    param([string[]]$CmdArgs = @())
    $check = $false; $setup = $false; $stop = $false; $browser = $true; $port = ""
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        switch ($CmdArgs[$i]) {
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
    if ($stop) { Stop-NotebookServer; return }
    if (-not (Test-ExakitDbReachable)) { Fail "The database is not running. Start it with: exakit start" }
    if ((Write-NotebookConnection) -eq "changed") { Info "The database connection changed; the notebooks now use the new one" }
    if (-not (Register-NotebookKernel)) { Warn2 "The kernel could not be registered again (see the log)." }
    $added = @(Copy-NotebookContent)
    if ($added.Count) { Ok "New notebooks in $($script:NotebookDir): $($added -join ', ')" }
    if ($check) {
        if (-not (Test-NotebookConnected)) { Fail "The notebook connector could not connect to the database. Repair with: exakit update notebook" }
        Ok "Notebooks connect to the database"
        Info "JupyterLab: $(Get-NotebookServerState)   Notebooks: $($script:NotebookDir)"
        return
    }
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
    Unregister-NotebookKernel
    foreach ($path in @($script:NotebookVenv, (Get-NotebookStoreFile), (Get-NotebookPidFile))) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $path
    }
    if ((Test-Path $script:NotebookHome) -and -not @(Get-ChildItem -Force -Path $script:NotebookHome -ErrorAction SilentlyContinue).Count) {
        Remove-Item -Force -ErrorAction SilentlyContinue $script:NotebookHome
    }
    foreach ($name in @($script:NotebookMasterCred, $script:NotebookTokenCred)) {
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $script:CredsDir $name)
    }
    Remove-ExakitManifestValue "components.notebook"
    Remove-ExakitManifestValue "desired.notebook"
    Info "Your notebooks stay in $($script:NotebookDir)"
    OkStep "notebook removed - reinstall any time with: exakit marketplace notebook"
    return $true
}
