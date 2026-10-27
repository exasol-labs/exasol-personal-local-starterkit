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

function Get-MlflowExecutable { return (Join-Path $script:NotebookVenv "Scripts/mlflow.exe") }

function Assert-MlflowServer {
    if (-not (Get-ExakitManifestValue "components.udf_devkit.version")) {
        Fail "The UDF dev kit is not installed. Install it with: exakit marketplace udf-devkit"
    }
    $python = Get-NotebookVenvPython
    if (-not (Test-Path $python)) { Fail "The notebook add-on is needed for MLflow: exakit marketplace notebook" }
    & $python -c 'import mlflow.server' 2>$null
    if ($LASTEXITCODE -ne 0) {
        $uv = Get-NotebookUv
        if (-not $uv) { Fail "The notebook package installer is missing. Repair with: exakit update notebook" }
        if ((Invoke-ExakitLogged $uv "pip" "install" "--python" $python "mlflow>=3,<4") -ne 0) {
            Fail "MLflow server could not be installed. Read: exakit logs setup"
        }
    }
}

function Invoke-CmdMlflow {
    param([string[]]$CmdArgs = @())
    if (-not $CmdArgs -or $CmdArgs.Count -eq 0) { Deny-ExakitInput "Name an MLflow action: start, stop, status, url or replay." }
    $action = "$($CmdArgs[0])"
    $rest = @()
    if ($CmdArgs.Count -gt 1) { $rest = @($CmdArgs[1..($CmdArgs.Count - 1)]) }
    if ($action -in @("--help", "-h")) { Show-ExakitHelpCommand -Name "mlflow" | Out-Null; return }
    if ($action -notin @("start", "stop", "status", "url", "replay")) {
        Deny-ExakitInput "Unknown MLflow action '$action' (start, stop, status, url, replay)."
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
    $serviceArgs = @($action)
    if ($action -eq "start") {
        Assert-MlflowServer
        $serviceArgs += @("--executable", (Get-MlflowExecutable))
        $serviceArgs += $rest
    } else {
        if (@($rest | Where-Object { $_ -ne "--json" }).Count -gt 0) { Deny-ExakitInput "Only --json is accepted for exakit mlflow $action" }
        $serviceArgs += $rest
    }
    Invoke-MlflowService -ServiceArgs $serviceArgs
}

function Get-UdfDevkitStatus {
    try {
        $doc = Invoke-MlflowService -ServiceArgs @("status", "--json") | ConvertFrom-Json
        if ($doc -and $doc.status) { return "$($doc.status)" }
    } catch { }
    return "unknown"
}
function Start-UdfDevkit { if (Test-Path (Get-NotebookVenvPython)) { Invoke-CmdMlflow -CmdArgs @("start") } }
function Stop-UdfDevkit { Invoke-MlflowService -ServiceArgs @("stop", "--json") | Out-Null }
function Get-UdfDevkitUrl { Invoke-MlflowService -ServiceArgs @("url") }
function Get-UdfDevkitLogPath { return "udf-devkit-mlflow|MLflow server|$(Join-Path $script:ExakitHome 'mlflow/server.log')" }
