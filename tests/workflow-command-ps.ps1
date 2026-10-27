#!/usr/bin/env pwsh
# workflow-command-ps.ps1 - the Windows twin of tests/workflow-command.sh:
# `exakit workflow list|show <id> [--json]` in setup/lib/workflow.ps1. Runs
# under Windows PowerShell 5.1 and pwsh; a sandboxed kit home, no database, no
# network, no real venv: the venv's Python is this machine's python3 with the
# kit's package on its path.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-workflow-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
Remove-Item Env:EXAKIT_WORKFLOW_ID -ErrorAction SilentlyContinue
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/notebook.ps1")
. (Join-Path $repo "setup/lib/workflow.ps1")
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
# Fail and Deny-ExakitInput end the run in the real CLI (exit 1 and 2); here
# they throw with the code, so a refusal is observable.
function Fail([string]$Msg) { throw "EXIT 1: $Msg" }
function Deny-ExakitInput { param([Parameter(Mandatory)][string]$Message, $Remedy = $null) throw "EXIT 2: $Message" }

# The venv's Python, stubbed: this machine's python3 on the kit's package.
$python3 = (Get-Command python3 -ErrorAction SilentlyContinue)
if (-not $python3) { $python3 = (Get-Command python -ErrorAction Stop) }
$script:StubPython = $python3.Source
$env:PYTHONPATH = Join-Path (Join-Path $repo "notebook") "package"
function Get-NotebookVenvPython { return $script:StubPython }
# The help renderer reads the installed kit's documents, which this sandbox has
# none of; what matters here is that --help asks for the command's page.
$script:HelpAsked = ""
function Show-ExakitHelpCommand { param([string]$Name) $script:HelpAsked = $Name }

# Run - the command; OUT is its output, CODE the exit code it would end with.
function Run {
    param([string[]]$CmdArgs = @())
    $script:PendingExitCode = 0
    $script:ExakitRefusalJson = $false
    try {
        $script:OUT = (@(Invoke-CmdWorkflow -CmdArgs $CmdArgs) | ForEach-Object { "$_" }) -join "`n"
        $script:CODE = $script:PendingExitCode
    } catch {
        $script:OUT = "$_"
        $script:CODE = 0
        if ("$_" -match '^EXIT (\d):') { $script:CODE = [int]$Matches[1] }
    }
}

try {
    Initialize-ExakitManifest

    Write-Host "bad arguments are refused with exit 2 before anything is read:"
    Run @();                  Check "no word" 2 $CODE; Contains "names the forms" "exakit workflow list | exakit workflow show <id>" $OUT
    Run @("frobnicate");      Check "an unknown word" 2 $CODE; Contains "names the words" "supported: list, show" $OUT
    Run @("list", "--bogus"); Check "an unknown option" 2 $CODE; Contains "names the option" "Unknown option '--bogus'" $OUT
    Run @("list", "extra");   Check "list with an argument" 2 $CODE
    Run @("show");            Check "show without an id" 2 $CODE; Contains "says where the ids are" "exakit workflow list" $OUT
    Run @("show", "nope");    Check "show with a word that is no id" 2 $CODE; Contains "says the shape" "wf-YYYYMMDD-xxxxxx" $OUT
    Run @("show", "..\x");    Check "a path is no id" 2 $CODE
    Run @("show", "WF-20261027-3F9A1C"); Check "upper case is no id" 2 $CODE
    Run @("show", "wf-20261027-3f9a1c", "wf-20261027-3f9a1d"); Check "two ids" 2 $CODE
    Check "nothing was written for a refusal" 0 @(Get-ChildItem -Path (Join-Path $env:EXAKIT_HOME "workflows") -Filter "wf-*.jsonl" -ErrorAction SilentlyContinue).Count

    Write-Host "without the notebook add-on the command says so:"
    Run @("list");            Check "exit 1" 1 $CODE; Contains "names the install command" "exakit marketplace notebook" $OUT
    Run @("show", "wf-20261027-3f9a1c"); Check "show too" 1 $CODE

    Write-Host "a missing notebook environment names the repair:"
    Set-ExakitManifestValue "components.notebook.version" "3.1.0"
    function Get-NotebookVenvPython { return (Join-Path $work "nowhere\python.exe") }
    Run @("list");            Check "exit 1" 1 $CODE; Contains "names exakit notebook setup" "exakit notebook setup" $OUT
    function Get-NotebookVenvPython { return $script:StubPython }

    Write-Host "list and show read the logs through the kit's notebook Python:"
    Run @("list");            Check "no workflows yet is still exit 0" 0 $CODE; Contains "and says so" "No workflows yet" $OUT
    $started = & $script:StubPython -c 'import importlib; w = importlib.import_module("exakit_nb.workflow"); wid = w.workflow("demo"); w.log_event(w.SQL, sql="SELECT 1", rows=1)'
    $wf = ("$started" -replace '^Workflow ([^:]*):.*$', '$1').Trim()
    Contains "the helper started a workflow" "wf-" $wf
    Check "its log is under the kit home" $true (Test-Path (Join-Path (Join-Path $env:EXAKIT_HOME "workflows") "$wf.jsonl"))
    Run @("list");            Check "list" 0 $CODE; Contains "has the id" $wf $OUT; Contains "and the name" "demo" $OUT
    Run @("list", "--json");  Check "list --json" 0 $CODE
    $rows = @($OUT | ConvertFrom-Json)
    Check "is a list with the workflow" "$wf|demo|2" "$($rows[0].id)|$($rows[0].name)|$($rows[0].events)"
    Run @("list", "-j");      Check "-j is --json" 0 $CODE; Contains "and answers JSON" "`"id`": `"$wf`"" $OUT
    Run @("show", $wf);       Check "show" 0 $CODE; Contains "has the start line" "start" $OUT; Contains "and the statement" "sql=SELECT 1" $OUT
    Run @("show", $wf, "--json"); Check "show --json" 0 $CODE
    Check "is the lines in order" "start,sql" ((@($OUT | ConvertFrom-Json) | ForEach-Object { $_.kind }) -join ",")
    Run @("show", "wf-20200101-abcdef"); Check "a workflow that is not there is exit 1" 1 $CODE
    Run @("--help");          Check "--help renders the page" 0 $CODE; Check "the command's own" "workflow" $script:HelpAsked
    $script:HelpAsked = ""
    Run @("show", "--help");  Check "so does show --help" 0 $CODE; Check "the same page" "workflow" $script:HelpAsked

    Write-Host "the CLI dispatches the command and the help document describes it:"
    $cli = Get-Content -Raw (Join-Path $repo "setup/exakit.ps1")
    Contains "setup/exakit.ps1 has the arm" 'Invoke-CmdWorkflow -CmdArgs $RestArgs' $cli
    Contains "and dot-sources the module" 'workflow.ps1' $cli
    $help = Get-Content -Raw (Join-Path $repo "setup/help/exakit.json") | ConvertFrom-Json
    Check "the help document has the command" 1 @($help.commands | Where-Object { $_.command -eq "workflow" }).Count
    Check "in the add-ons group" $true ((@($help.groups | Where-Object { $_.title -eq "Add-ons" })[0].commands) -contains "workflow")
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$(Split-Path -Leaf $PSCommandPath): $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -ne 0) { exit 1 }
