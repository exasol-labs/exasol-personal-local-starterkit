# workflow.ps1 - `exakit workflow list|show <id> [--json]`: the workflow logs
# the notebook helpers write (X-1), one JSON line per step under
# $ExakitHome\workflows\<id>.jsonl, every line carrying the id. Twin of
# setup/lib/workflow.sh; read that header. The reading lives in the helpers'
# own module, notebook\package\exakit_nb\workflow.py, which both twins run
# through the kit's notebook Python (the add-on has to be installed). The
# shell keeps only the argument check and the two refusals.
#
# Exit codes: 0 ok; 1 the add-on is not installed or no such workflow; 2 bad
# arguments. Dot-sourced after notebook.ps1.

# Test-WorkflowInstalled - the notebook add-on's record is there (the helpers
# and their Python live in its venv). Twin of workflow_installed.
function Test-WorkflowInstalled {
    return [bool](Get-ExakitManifestValue "components.notebook.version")
}

# Invoke-WorkflowModule - the module in the kit's notebook Python, with the kit
# home the CLI resolved. Its output flows through as the command's (so --json
# stays one object on stdout); its exit code, when not 0, becomes the CLI's
# through PendingExitCode - not a return value, which would swallow the
# output. Twin of workflow_run.
function Invoke-WorkflowModule {
    param([string[]]$ModuleArgs = @())
    if (-not (Get-Command Get-NotebookVenvPython -ErrorAction SilentlyContinue)) { Fail "The notebook module is missing from this kit copy. Repair with: exakit update" }
    $python = Get-NotebookVenvPython
    if (-not (Test-Path $python)) { Fail "The notebook environment is missing ($python). Repair it with: exakit notebook setup" }
    $savedHome = [Environment]::GetEnvironmentVariable("EXAKIT_HOME", "Process")
    $prevEap = $ErrorActionPreference
    try {
        [Environment]::SetEnvironmentVariable("EXAKIT_HOME", [string]$script:ExakitHome, "Process")
        $ErrorActionPreference = "Continue"
        & $python -m exakit_nb.workflow @ModuleArgs
        if ($LASTEXITCODE -ne 0) { $script:PendingExitCode = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prevEap
        [Environment]::SetEnvironmentVariable("EXAKIT_HOME", $savedHome, "Process")
    }
}

# exakit workflow list [--json] | show <id> [--json]
function Invoke-CmdWorkflow {
    param([string[]]$CmdArgs = @())
    $sub = ""
    if ($CmdArgs.Count -gt 0) { $sub = "$($CmdArgs[0])" }
    $rest = @()
    if ($CmdArgs.Count -gt 1) { $rest = @($CmdArgs[1..($CmdArgs.Count - 1)]) }
    if ($sub -in @("--help", "-h")) { Show-ExakitHelpCommand -Name "workflow" | Out-Null; return }
    $json = $false; $id = ""
    foreach ($arg in $rest) {
        if ($arg -in @("--json", "-j")) { $json = $true; $script:ExakitRefusalJson = $true }
        elseif ($arg -in @("--help", "-h")) { Show-ExakitHelpCommand -Name "workflow" | Out-Null; return }
        elseif ("$arg".StartsWith("-")) { Deny-ExakitInput "Unknown option '$arg' for workflow (supported: --json)." }
        elseif ($id) { Deny-ExakitInput "Name one workflow: exakit workflow show <id> [--json]" }
        else { $id = "$arg" }
    }
    switch ($sub) {
        "list" { if ($id) { Deny-ExakitInput "list takes no argument: exakit workflow list [--json]" } }
        "show" {
            if (-not $id) { Deny-ExakitInput "Name the workflow: exakit workflow show <id> [--json] (exakit workflow list)" }
            # The id's shape, checked here so a stray word never reaches the
            # file system as a name: wf-YYYYMMDD-<6 lowercase hex>.
            if ($id -cnotmatch '^wf-[0-9]{8}-[0-9a-f]{6}$') { Deny-ExakitInput "Not a workflow id: '$id' (expected wf-YYYYMMDD-xxxxxx; exakit workflow list)" }
        }
        ""     { Deny-ExakitInput "Name what to do: exakit workflow list | exakit workflow show <id> (exakit workflow --help)." }
        default { Deny-ExakitInput "Unknown workflow command '$sub' (supported: list, show)." }
    }
    if (-not (Test-WorkflowInstalled)) { Fail "The notebook add-on is not installed; its helpers write the workflow log. Install it with: exakit marketplace notebook" }
    $moduleArgs = @($sub)
    if ($id) { $moduleArgs += $id }
    if ($json) { $moduleArgs += "--json" }
    Invoke-WorkflowModule -ModuleArgs $moduleArgs
}
