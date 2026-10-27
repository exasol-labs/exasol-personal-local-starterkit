# describe.ps1 - `exakit describe <table> [--sample N] [--id <slug>] [--json]
# [--write <path>]`: profile SCHEMA.TABLE and draft its descriptor (DS-5), a
# role per column with the evidence that chose it and, under missing, the
# roles no column fits. Twin of setup/lib/describe.sh; read that header. The
# profiling and the scoring live in one Python service,
# setup\lib\describe_service.py, which both twins run through the kit's
# notebook Python (the add-on has to be installed), connected as the kit's
# admin user the way udf-devkit.ps1 runs udf_tool.py: the password is read
# from its file by the child and never reaches a command line. The shell keeps
# only the argument check and the refusals. Only SELECTs run.
#
# Exit codes: 0 ok; 1 the add-on is not installed; 2 bad arguments; 3 the
# table is not there; 4 the database is not reachable (the service's own codes
# pass through). Dot-sourced after notebook.ps1.

# Test-DescribeInstalled - the notebook add-on's record is there (the
# profiler's Python lives in its venv). Twin of describe_installed.
function Test-DescribeInstalled {
    return [bool](Get-ExakitManifestValue "components.notebook.version")
}

# Invoke-DescribeService - the service in the kit's notebook Python with the
# admin connection settings from the manifest (the password's FILE, never the
# password). Its output flows through as the command's (so --json stays one
# object on stdout); its exit code, when not 0, becomes the CLI's through
# PendingExitCode - not a return value, which would swallow the output. Twin
# of describe_run.
function Invoke-DescribeService {
    param([string[]]$ServiceArgs = @())
    if (-not (Get-Command Get-NotebookVenvPython -ErrorAction SilentlyContinue)) { Fail "The notebook module is missing from this kit copy. Repair with: exakit update" }
    $python = Get-NotebookVenvPython
    if (-not (Test-Path $python)) { Fail "The notebook environment is missing ($python). Repair it with: exakit notebook setup" }
    $service = Join-Path (Join-Path (Join-Path (Get-ExakitRepoRoot) "setup") "lib") "describe_service.py"
    $envs = @{ EXAKIT_PYX_DSN = (Get-ExakitManifestValue "runtime.dsn"); EXAKIT_PYX_USER = (Get-ExakitManifestValue "runtime.user")
               EXAKIT_PYX_PWFILE = (Get-ExakitManifestValue "runtime.password_file") }
    if (-not $envs.EXAKIT_PYX_USER) { $envs.EXAKIT_PYX_USER = "sys" }
    $saved = @{}
    foreach ($key in $envs.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, [string]$envs[$key], "Process")
    }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $python $service @ServiceArgs
        if ($LASTEXITCODE -ne 0) { $script:PendingExitCode = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prevEap
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process") }
    }
}

# exakit describe <table> [--sample N] [--id <slug>] [--json] [--write <path>]
function Invoke-CmdDescribe {
    param([string[]]$CmdArgs = @())
    $table = ""; $sample = ""; $id = ""; $json = $false; $write = ""
    $i = 0
    while ($i -lt $CmdArgs.Count) {
        $arg = "$($CmdArgs[$i])"
        if ($arg -in @("--help", "-h")) { Show-ExakitHelpCommand -Name "describe" | Out-Null; return }
        elseif ($arg -in @("--json", "-j")) { $json = $true; $script:ExakitRefusalJson = $true }
        elseif ($arg -in @("--sample", "--id", "--write")) {
            $value = ""
            if ($i + 1 -lt $CmdArgs.Count) { $value = "$($CmdArgs[$i + 1])" }
            if (-not $value -or $value.StartsWith("-")) { Deny-ExakitInput "$arg needs a value: exakit describe <table> $arg <value>" }
            switch ($arg) {
                "--sample" {
                    if ($sample) { Deny-ExakitInput "--sample was given twice." }
                    if ($value -notmatch '^[1-9][0-9]*$') { Deny-ExakitInput "--sample takes the number of rows to profile (a positive integer), not '$value'." }
                    $sample = $value
                }
                "--id" {
                    if ($id) { Deny-ExakitInput "--id was given twice." }
                    if ($value -cnotmatch '^[a-z0-9]+([-_][a-z0-9]+)*$') { Deny-ExakitInput "--id takes a dataset id (lower-case letters and digits, joined by - or _), not '$value'." }
                    $id = $value
                }
                "--write" {
                    if ($write) { Deny-ExakitInput "--write was given twice." }
                    $write = $value
                }
            }
            $i++
        }
        elseif ($arg -in @("--approve", "--show", "--versions")) { Deny-ExakitInput "$arg is not in this kit yet: exakit describe drafts; approving a draft comes with the next release. Draft with: exakit describe <table>" }
        elseif ($arg.StartsWith("-")) { Deny-ExakitInput "Unknown option '$arg' for describe (supported: --sample, --id, --json, --write)." }
        elseif ($table) { Deny-ExakitInput "Name one table: exakit describe SCHEMA.TABLE [--sample N] [--id slug] [--json] [--write <path>]" }
        else { $table = $arg }
        $i++
    }
    if (-not $table) { Deny-ExakitInput "Name the table: exakit describe SCHEMA.TABLE [--sample N] [--id slug] [--json] [--write <path>] (exakit describe --help)." }
    # The table's shape, checked here so a stray word never reaches SQL: two
    # names joined by a dot, a part quoted when it is not a plain name.
    if ($table -notmatch '^("([^"]|"")+"|[A-Za-z_][A-Za-z0-9_]*)\.("([^"]|"")+"|[A-Za-z_][A-Za-z0-9_]*)$') {
        Deny-ExakitInput "Name the table as SCHEMA.TABLE (quote a part that is not a plain name: `"my schema`".`"order data`"), not '$table'."
    }
    if (-not (Test-DescribeInstalled)) { Fail "The notebook add-on is not installed; its Python runs the profiler. Install it with: exakit marketplace notebook" }
    $serviceArgs = @("draft", $table)
    if ($sample) { $serviceArgs += @("--sample", $sample) }
    if ($id) { $serviceArgs += @("--id", $id) }
    if ($json) { $serviceArgs += "--json" }
    if ($write) { $serviceArgs += @("--write", $write) }
    Invoke-DescribeService -ServiceArgs $serviceArgs
}
