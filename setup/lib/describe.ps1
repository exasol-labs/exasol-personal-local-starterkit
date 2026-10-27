# describe.ps1 - `exakit describe <table> [--sample N] [--id <slug>] [--json]
# [--write <path>]`: profile SCHEMA.TABLE and draft its descriptor (DS-5), a
# role per column with the evidence that chose it and, under missing, the
# roles no column fits; and the approve half: `exakit describe <id|draft.yaml>
# --approve [--role <role>=<COL>]... [--owner <who>] [--no-comments]`,
# `--show [--version n]`, `--versions`, `--comments`, all with --json. Twin of
# setup/lib/describe.sh; read that header. The profiling, the scoring and the
# approving live in one Python service, setup\lib\describe_service.py, which
# both twins run through the kit's notebook Python (the add-on has to be
# installed), connected as the kit's admin user the way udf-devkit.ps1 runs
# udf_tool.py: the password is read from its file by the child and never
# reaches a command line. The shell keeps only the argument check and the
# refusals. Drafting runs SELECTs only; approving writes comments (and the
# view for a virtual table) and nothing else.
#
# Exit codes: 0 ok; 1 the add-on is not installed; 2 bad arguments or roles;
# 3 the table or the id is not there; 4 the database is not reachable; 5 a
# version conflict (the service's own codes pass through). Dot-sourced after
# notebook.ps1.

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
# exakit describe <id|draft.yaml> --approve [--role r=COL]... [--owner x] [--no-comments] [--json]
# exakit describe <id> --show [--version n] | --versions | --comments [--json]
function Invoke-CmdDescribe {
    param([string[]]$CmdArgs = @())
    $target = ""; $sample = ""; $id = ""; $json = $false; $write = ""
    $mode = ""; $owner = ""; $version = ""; $noComments = $false; $roles = @()
    $i = 0
    while ($i -lt $CmdArgs.Count) {
        $arg = "$($CmdArgs[$i])"
        if ($arg -in @("--help", "-h")) { Show-ExakitHelpCommand -Name "describe" | Out-Null; return }
        elseif ($arg -in @("--json", "-j")) { $json = $true; $script:ExakitRefusalJson = $true }
        elseif ($arg -in @("--approve", "--show", "--versions", "--comments")) {
            if ($mode -and $mode -ne $arg) { Deny-ExakitInput "$mode and $arg are two different things; give one of --approve, --show, --versions, --comments." }
            $mode = $arg
        }
        elseif ($arg -eq "--no-comments") { $noComments = $true }
        elseif ($arg -in @("--sample", "--id", "--write", "--owner", "--version", "--role")) {
            $value = ""
            if ($i + 1 -lt $CmdArgs.Count) { $value = "$($CmdArgs[$i + 1])" }
            if (-not $value -or $value.StartsWith("-")) { Deny-ExakitInput "$arg needs a value: exakit describe ... $arg <value>" }
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
                "--owner" {
                    if ($owner) { Deny-ExakitInput "--owner was given twice." }
                    $owner = $value
                }
                "--version" {
                    if ($version) { Deny-ExakitInput "--version was given twice." }
                    if ($value -notmatch '^[1-9][0-9]*$') { Deny-ExakitInput "--version takes a version number (a positive integer), not '$value'." }
                    $version = $value
                }
                "--role" {
                    # role=COLUMN (text=A,B); the service checks the column against the table.
                    if ($value -cnotmatch '^(entity|category|date|label|text)=[A-Za-z][A-Za-z0-9_]*(,[A-Za-z][A-Za-z0-9_]*)*$') {
                        Deny-ExakitInput "--role takes role=COLUMN with the role one of entity, category, date, label, text (text takes A,B,...), not '$value'."
                    }
                    $roles += $value
                }
            }
            $i++
        }
        elseif ($arg.StartsWith("-")) { Deny-ExakitInput "Unknown option '$arg' for describe (supported: --sample, --id, --json, --write, --approve, --role, --owner, --no-comments, --show, --version, --versions, --comments)." }
        elseif ($target) { Deny-ExakitInput "Name one table or descriptor: exakit describe SCHEMA.TABLE | exakit describe <id> --approve|--show|--versions|--comments" }
        else { $target = $arg }
        $i++
    }
    $idShape = '^[a-z0-9]+([-_][a-z0-9]+)*$'
    $serviceArgs = @()
    if (-not $mode) {
        if ($owner -or $version -or $noComments -or $roles.Count -gt 0) {
            Deny-ExakitInput "--role, --owner, --no-comments and --version go with --approve or --show: exakit describe <id> --approve [--role role=COLUMN]... [--owner who] [--no-comments]"
        }
        if (-not $target) { Deny-ExakitInput "Name the table: exakit describe SCHEMA.TABLE [--sample N] [--id slug] [--json] [--write <path>] (exakit describe --help)." }
        # The table's shape, checked here so a stray word never reaches SQL: two
        # names joined by a dot, a part quoted when it is not a plain name.
        if ($target -notmatch '^("([^"]|"")+"|[A-Za-z_][A-Za-z0-9_]*)\.("([^"]|"")+"|[A-Za-z_][A-Za-z0-9_]*)$') {
            Deny-ExakitInput "Name the table as SCHEMA.TABLE (quote a part that is not a plain name: `"my schema`".`"order data`"), not '$target'."
        }
        $serviceArgs = @("draft", $target)
        if ($sample) { $serviceArgs += @("--sample", $sample) }
        if ($id) { $serviceArgs += @("--id", $id) }
        if ($json) { $serviceArgs += "--json" }
        if ($write) { $serviceArgs += @("--write", $write) }
    }
    elseif ($mode -eq "--approve") {
        if ($id -or $write -or $version) { Deny-ExakitInput "--id, --write and --version do not go with --approve (the id is the draft's; --show takes --version)." }
        if (-not $target) { Deny-ExakitInput "Name the draft to approve, a dataset id or a draft file: exakit describe <id|draft.yaml> --approve [--role role=COLUMN]... [--owner who] [--no-comments]" }
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -and ($target -cnotmatch $idShape)) {
            Deny-ExakitInput "--approve takes a dataset id (lower-case letters and digits, joined by - or _) or a draft file that exists, not '$target'."
        }
        $serviceArgs = @("approve", $target)
        if ($sample) { $serviceArgs += @("--sample", $sample) }
        if ($owner) { $serviceArgs += @("--owner", $owner) }
        if ($noComments) { $serviceArgs += "--no-comments" }
        if ($json) { $serviceArgs += "--json" }
        foreach ($role in $roles) { $serviceArgs += @("--role", $role) }
    }
    else {
        if ($id -or $write -or $sample -or $owner -or $noComments -or $roles.Count -gt 0) {
            $extra = ""
            if ($mode -eq "--show") { $extra = " and --version n" }
            Deny-ExakitInput "$mode takes a dataset id$extra and --json, nothing else."
        }
        if ($mode -ne "--show" -and $version) { Deny-ExakitInput "--version goes with --show: exakit describe <id> --show --version n" }
        if (-not $target) { Deny-ExakitInput "Name the dataset id: exakit describe <id> $mode [--json]" }
        if ($target -cnotmatch $idShape) { Deny-ExakitInput "$mode takes a dataset id (lower-case letters and digits, joined by - or _), not '$target'." }
        $serviceArgs = @($mode.Substring(2), $target)
        if ($version) { $serviceArgs += @("--version", $version) }
        if ($json) { $serviceArgs += "--json" }
    }
    if (-not (Test-DescribeInstalled)) { Fail "The notebook add-on is not installed; its Python runs the profiler. Install it with: exakit marketplace notebook" }
    Invoke-DescribeService -ServiceArgs $serviceArgs
}
