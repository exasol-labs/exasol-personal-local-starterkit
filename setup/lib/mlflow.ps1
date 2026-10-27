# MLflow server and spool commands. The lifecycle is shared with sh in mlflow_service.py.
function Invoke-MlflowService {
    param([string[]]$ServiceArgs = @())
    $root = Get-ExakitRepoRoot
    $service = Join-Path (Join-Path $root "setup/lib") "mlflow_service.py"
    $saved = $env:EXAKIT_HOME
    try {
        $env:EXAKIT_HOME = $script:ExakitHome
        $python = if (Get-Command Get-NotebookVenvPython -ErrorAction SilentlyContinue) { Get-NotebookVenvPython } else { "" }
        if (-not $python -or -not (Test-Path $python)) { $python = Get-ExakitPersonaPython }
        if (-not $python) { return }
        & $python $service @ServiceArgs
        $script:PendingExitCode = $LASTEXITCODE
    } finally { $env:EXAKIT_HOME = $saved }
}

# Test-MlflowEnabled - the user or a persona asked for the server: exakit mlflow
# start records it, exakit mlflow disable (or stop --disable) clears it. exakit
# start brings MLflow back only then, so a udf-devkit user who never asked for
# it never gets a server; a plain stop is for the session and keeps it.
function Test-MlflowEnabled {
    return (("" + (Get-ExakitManifestValue "components.udf_devkit.mlflow.enabled")).ToLower() -eq "true")
}

function Get-MlflowExecutable { return (Join-Path $script:NotebookVenv "Scripts/mlflow.exe") }

function Assert-MlflowServer {
    if (-not (Get-ExakitManifestValue "components.udf_devkit.version")) {
        Fail "The UDF dev kit is not installed. Install it with: exakit marketplace udf-devkit"
    }
    $python = Get-NotebookVenvPython
    if (-not (Test-Path $python)) { Fail "The notebook add-on is needed for MLflow: exakit marketplace notebook" }
    # Continue, not the caller's Stop: on 5.1 the failed import writing to a
    # redirected stderr would be a terminating error - and a failed import is
    # exactly when the server is to be installed.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $python -c 'import mlflow.server' 2>$null
        $probe = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($probe -ne 0) {
        $uv = Get-NotebookUv
        if (-not $uv) { Fail "The notebook package installer is missing. Repair with: exakit update notebook" }
        if ((Invoke-ExakitLogged $uv "pip" "install" "--python" $python "mlflow>=3,<4") -ne 0) {
            Fail "MLflow server could not be installed. Read: exakit logs setup"
        }
    }
}

function Invoke-CmdMlflow {
    param([string[]]$CmdArgs = @())
    if (-not $CmdArgs -or $CmdArgs.Count -eq 0) { Deny-ExakitInput "Name an MLflow action: start, stop, status, url, replay or disable." }
    $action = "$($CmdArgs[0])"
    $rest = @()
    if ($CmdArgs.Count -gt 1) { $rest = @($CmdArgs[1..($CmdArgs.Count - 1)]) }
    if ($action -in @("--help", "-h")) { Show-ExakitHelpCommand -Name "mlflow" | Out-Null; return }
    if ($action -notin @("start", "stop", "status", "url", "replay", "disable")) {
        Deny-ExakitInput "Unknown MLflow action '$action' (start, stop, status, url, replay, disable)."
    }
    if ($action -eq "replay") {
        $python = Get-NotebookVenvPython
        if (-not (Test-Path $python)) { Fail "The notebook add-on is needed for replay: exakit marketplace notebook" }
        $saved = $env:EXAKIT_HOME
        try {
            $env:EXAKIT_HOME = $script:ExakitHome
            & $python -m exasol_mlflow replay @rest
            $script:PendingExitCode = $LASTEXITCODE
        } finally { $env:EXAKIT_HOME = $saved }
        return
    }
    if ($action -in @("stop", "disable")) {
        $disable = ($action -eq "disable")
        $stopArgs = @("stop")
        foreach ($arg in $rest) {
            if ($arg -eq "--json") { $stopArgs += "--json" }
            elseif ($arg -eq "--disable") { $disable = $true }
            else { Deny-ExakitInput "Unknown option '$arg' for exakit mlflow $action (--json, --disable)." }
        }
        Invoke-MlflowService -ServiceArgs $stopArgs
        if ($script:PendingExitCode -eq 0 -and $disable) {
            Set-ExakitManifestValue "components.udf_devkit.mlflow.enabled" $false
            if ($stopArgs -notcontains "--json") { Info "MLflow will not start with exakit start until: exakit mlflow start" }
        }
        return
    }
    $serviceArgs = @($action)
    if ($action -eq "start") {
        Assert-MlflowServer
        $serviceArgs += @("--executable", (Get-MlflowExecutable))
        $serviceArgs += $rest
        Invoke-MlflowService -ServiceArgs $serviceArgs
        if ($script:PendingExitCode -eq 0) { Set-ExakitManifestValue "components.udf_devkit.mlflow.enabled" $true }
        return
    } else {
        if (@($rest | Where-Object { $_ -ne "--json" }).Count -gt 0) { Deny-ExakitInput "Only --json is accepted for exakit mlflow $action" }
        $serviceArgs += $rest
    }
    Invoke-MlflowService -ServiceArgs $serviceArgs
}

function Get-UdfDevkitStatus {
    try {
        $doc = Invoke-MlflowService -ServiceArgs @("status", "--json") | ConvertFrom-Json
        if ($doc -and $doc.status -eq "stopped" -and -not (Test-MlflowEnabled)) { return "stopped (not enabled: exakit mlflow start)" }
        if ($doc -and $doc.status) { return "$($doc.status)" }
    } catch { }
    return "unknown"
}
function Start-UdfDevkit { if ((Test-MlflowEnabled) -and (Test-Path (Get-NotebookVenvPython))) { Invoke-CmdMlflow -CmdArgs @("start") } }
function Stop-UdfDevkit { Invoke-MlflowService -ServiceArgs @("stop", "--json") | Out-Null }
function Get-UdfDevkitUrl { Invoke-MlflowService -ServiceArgs @("url") }
function Get-UdfDevkitLogPath { return "udf-devkit-mlflow|MLflow server|$(Join-Path $script:ExakitHome 'mlflow/server.log')" }
