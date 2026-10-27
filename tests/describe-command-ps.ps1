#!/usr/bin/env pwsh
# describe-command-ps.ps1 - the Windows twin of tests/describe-command.sh:
# `exakit describe <table> [--sample N] [--id <slug>] [--json] [--write <path>]`
# and the approve half (--approve/--show/--versions/--comments) in
# setup/lib/describe.ps1. Runs under Windows PowerShell 5.1 and pwsh; a
# sandboxed kit home, no database, no network, no real venv: the venv's Python
# is this machine's python3, and the kit copy is a sandbox whose
# describe_service.py is test_data/describe/stub_service.py.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-describe-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $work "root\setup\lib") | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
foreach ($name in @("EXAKIT_PYX_DSN", "EXAKIT_PYX_USER", "EXAKIT_PYX_PWFILE", "STUB_EXIT")) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/notebook.ps1")
. (Join-Path $repo "setup/lib/describe.ps1")
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

# The venv's Python, stubbed: this machine's python3. The kit copy, stubbed: a
# sandbox whose service records what it was asked.
$python3 = (Get-Command python3 -ErrorAction SilentlyContinue)
if (-not $python3) { $python3 = (Get-Command python -ErrorAction Stop) }
$script:StubPython = $python3.Source
Copy-Item (Join-Path $repo "test_data/describe/stub_service.py") (Join-Path $work "root\setup\lib\describe_service.py")
$script:StubRoot = Join-Path $work "root"
function Get-NotebookVenvPython { return $script:StubPython }
function Get-ExakitRepoRoot { return $script:StubRoot }
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
        $script:OUT = (@(Invoke-CmdDescribe -CmdArgs $CmdArgs) | ForEach-Object { "$_" }) -join "`n"
        $script:CODE = $script:PendingExitCode
    } catch {
        $script:OUT = "$_"
        $script:CODE = 0
        if ("$_" -match '^EXIT (\d):') { $script:CODE = [int]$Matches[1] }
    }
}
# Asked - one field of the stub's answer in OUT.
function Asked([string]$Key) {
    $answer = $script:OUT | ConvertFrom-Json
    $value = $answer.$Key
    if ($value -is [array]) { return ($value -join " ") }
    return "$value"
}

try {
    Initialize-ExakitManifest

    Write-Host "bad arguments are refused with exit 2 before anything runs:"
    Run @();                                     Check "no table" 2 $CODE; Contains "names the shape" "exakit describe SCHEMA.TABLE" $OUT
    Run @("READINGS");                           Check "a bare name" 2 $CODE; Contains "asks for SCHEMA.TABLE" "SCHEMA.TABLE" $OUT
    Run @("A.B.C");                              Check "three parts" 2 $CODE
    Run @("LAB.1X");                             Check "a part that starts with a digit" 2 $CODE
    Run @("LAB.READINGS", "LAB.OTHER");          Check "two tables" 2 $CODE; Contains "says one" "Name one table" $OUT
    Run @("LAB.READINGS", "--bogus");            Check "an unknown option" 2 $CODE; Contains "names the option" "Unknown option '--bogus'" $OUT
    Run @("LAB.READINGS", "--sample");           Check "--sample without a value" 2 $CODE; Contains "says so" "--sample needs a value" $OUT
    Run @("LAB.READINGS", "--sample", "--json"); Check "--sample followed by an option" 2 $CODE
    Run @("LAB.READINGS", "--sample", "x");      Check "--sample with a word" 2 $CODE; Contains "says positive integer" "positive integer" $OUT
    Run @("LAB.READINGS", "--sample", "0");      Check "--sample 0" 2 $CODE
    Run @("LAB.READINGS", "--sample", "5", "--sample", "6"); Check "--sample twice" 2 $CODE
    Run @("LAB.READINGS", "--id", "Bad Id");     Check "--id that is no dataset id" 2 $CODE; Contains "says the shape" "lower-case letters and digits" $OUT
    Run @("LAB.READINGS", "--id", "UPPER");      Check "an upper-case id is no dataset id" 2 $CODE
    Run @("LAB.READINGS", "--write");            Check "--write without a path" 2 $CODE
    Run @("LAB.READINGS", "--approve");          Check "--approve on a table name (no id, no file)" 2 $CODE; Contains "says what it takes" "--approve takes a dataset id" $OUT
    Run @("LAB.READINGS", "--versions");         Check "--versions on a table name" 2 $CODE
    Run @("readings", "--approve", "--show");    Check "two modes" 2 $CODE; Contains "names both" "--approve and --show are two different things" $OUT
    Run @("readings", "--approve", "--role");    Check "--role without a value" 2 $CODE
    Run @("readings", "--approve", "--role", "owner=X"); Check "--role with no such role" 2 $CODE; Contains "names the roles" "one of entity, category, date, label, text" $OUT
    Run @("readings", "--approve", "--role", "entity=1x"); Check "--role with a column that is no plain name" 2 $CODE
    Run @("readings", "--approve", "--role", "entity=A B"); Check "--role with a space" 2 $CODE
    Run @("readings", "--approve", "--owner");   Check "--owner without a value" 2 $CODE
    Run @("readings", "--approve", "--owner", "a", "--owner", "b"); Check "--owner twice" 2 $CODE
    Run @("readings", "--approve", "--id", "x"); Check "--id does not go with --approve" 2 $CODE; Contains "says so" "do not go with --approve" $OUT
    Run @("readings", "--approve", "--version", "2"); Check "nor --version" 2 $CODE
    Run @("--approve");                          Check "--approve without a target" 2 $CODE; Contains "asks for the draft" "Name the draft to approve" $OUT
    Run @("Bad.Id", "--approve");                Check "--approve with neither an id nor a file" 2 $CODE
    Run @("LAB.READINGS", "--role", "entity=ID"); Check "--role without --approve" 2 $CODE; Contains "says where it goes" "go with --approve" $OUT
    Run @("LAB.READINGS", "--no-comments");      Check "--no-comments without --approve" 2 $CODE
    Run @("readings", "--show", "--version", "x"); Check "--show --version with a word" 2 $CODE; Contains "says positive integer" "positive integer" $OUT
    Run @("readings", "--show", "--version", "0"); Check "--show --version 0" 2 $CODE
    Run @("readings", "--show", "--role", "entity=ID"); Check "--show with --role" 2 $CODE; Contains "says what --show takes" "--show takes a dataset id and --version n and --json" $OUT
    Run @("readings", "--versions", "--version", "2"); Check "--versions with --version" 2 $CODE; Contains "says --version goes with --show" "--version goes with --show" $OUT
    Run @("readings", "--comments", "--sample", "5"); Check "--comments with --sample" 2 $CODE
    Run @("--versions");                         Check "--versions without an id" 2 $CODE; Contains "asks for the id" "Name the dataset id" $OUT
    Run @("Readings", "--versions");             Check "--versions with an upper-case id" 2 $CODE; Contains "says the shape" "lower-case letters and digits" $OUT
    Run @("LAB.READINGS", "--json", "--bogus");  Check "with --json the refusal is still exit 2" 2 $CODE
    Check "and the refusal is flagged for JSON" $true $script:ExakitRefusalJson

    Write-Host "without the notebook add-on the command says so:"
    Run @("LAB.READINGS");                       Check "exit 1" 1 $CODE; Contains "names the install command" "exakit marketplace notebook" $OUT

    Write-Host "a missing notebook environment names the repair:"
    Set-ExakitManifestValue "components.notebook.version" "3.1.0"
    function Get-NotebookVenvPython { return (Join-Path $work "nowhere\python.exe") }
    Run @("LAB.READINGS");                       Check "exit 1" 1 $CODE; Contains "names exakit notebook setup" "exakit notebook setup" $OUT
    function Get-NotebookVenvPython { return $script:StubPython }

    Write-Host "the service runs with the manifest's connection settings and the arguments given:"
    $pwfile = Join-Path (Join-Path $env:EXAKIT_HOME "credentials") "personal_sys_password"
    Set-ExakitManifestValue "runtime.dsn" "127.0.0.1:8563"
    Set-ExakitManifestValue "runtime.user" "sys"
    Set-ExakitManifestValue "runtime.password_file" $pwfile
    Run @("LAB.READINGS");                       Check "exit 0" 0 $CODE
    Check "draft, the table" "draft LAB.READINGS" (Asked "args")
    Check "the dsn" "127.0.0.1:8563" (Asked "dsn"); Check "the user" "sys" (Asked "user")
    Check "the password file's path, not its content" $pwfile (Asked "pwfile")
    Check "the settings do not stay in this process" "" "$env:EXAKIT_PYX_PWFILE"
    $outPath = Join-Path $work "out.yaml"
    Run @("lab.readings", "--sample", "500", "--id", "lab-readings", "--json", "--write", $outPath)
    Check "every option passes through, in the service's order" "draft lab.readings --sample 500 --id lab-readings --json --write $outPath" (Asked "args")
    Run @("LAB.READINGS", "-j");                 Check "-j is --json" "draft LAB.READINGS --json" (Asked "args")
    Run @('"my schema"."order data"');           Check "a quoted table passes through as typed" 'draft "my schema"."order data"' (Asked "args")
    $env:STUB_EXIT = "3"
    Run @("LAB.NOPE");                           Check "the service's exit code is the command's (3: no such table)" 3 $CODE
    $env:STUB_EXIT = "4"
    Run @("LAB.READINGS");                       Check "and 4: database unreachable" 4 $CODE
    Remove-Item Env:STUB_EXIT -ErrorAction SilentlyContinue
    Write-Host "the approve half passes through the same way:"
    Run @("readings", "--approve");              Check "approve, the id" "approve readings" (Asked "args")
    Run @("readings", "--approve", "--role", "entity=ID", "--role", "text=A,B", "--owner", "lee", "--no-comments", "--json", "--sample", "500")
    Check "every approve option, in the service's order" "approve readings --sample 500 --owner lee --no-comments --json --role entity=ID --role text=A,B" (Asked "args")
    $draftPath = Join-Path $work "draft.yaml"
    Set-Content -Path $draftPath -Value "schema_version: 2"
    Run @($draftPath, "--approve");              Check "a draft file by its path" "approve $draftPath" (Asked "args")
    Run @("readings", "--show");                 Check "show" "show readings" (Asked "args")
    Run @("readings", "--show", "--version", "2", "--json"); Check "show with a version and --json" "show readings --version 2 --json" (Asked "args")
    Run @("readings", "--show", "--show");       Check "the same mode twice is one mode" "show readings" (Asked "args")
    Run @("readings", "--versions");             Check "versions" "versions readings" (Asked "args")
    Run @("readings", "--comments", "-j");       Check "comments" "comments readings --json" (Asked "args")
    Check "the dsn reaches the approve half too" "127.0.0.1:8563" (Asked "dsn")
    $env:STUB_EXIT = "2"
    Run @("readings", "--approve", "--role", "entity=NOPE"); Check "the service's 2 (a bad role) is the command's" 2 $CODE
    $env:STUB_EXIT = "3"
    Run @("nowhere", "--versions");              Check "3: no such id" 3 $CODE
    $env:STUB_EXIT = "5"
    Run @("readings", "--approve");              Check "5: a version conflict" 5 $CODE
    Remove-Item Env:STUB_EXIT -ErrorAction SilentlyContinue
    Run @("--help");                             Check "--help renders the page" 0 $CODE; Check "the command's own" "describe" $script:HelpAsked
    $script:HelpAsked = ""
    Run @("LAB.READINGS", "--help");             Check "so does <table> --help" 0 $CODE; Check "the same page" "describe" $script:HelpAsked

    Write-Host "the real service, with no connection settings, is exit 4:"
    function Get-ExakitRepoRoot { return $repo }
    Set-ExakitManifestValue "runtime.dsn" ""
    Set-ExakitManifestValue "runtime.password_file" ""
    Run @("LAB.READINGS");                       Check "exit 4" 4 $CODE
    function Get-ExakitRepoRoot { return $script:StubRoot }

    Write-Host "the CLI dispatches the command and the help document describes it:"
    $cli = Get-Content -Raw (Join-Path $repo "setup/exakit.ps1")
    Contains "setup/exakit.ps1 has the arm" 'Invoke-CmdDescribe -CmdArgs $RestArgs' $cli
    Contains "and dot-sources the module" 'describe.ps1' $cli
    Contains "and its header names the command" 'describe <table>' $cli
    $help = Get-Content -Raw (Join-Path $repo "setup/help/exakit.json") | ConvertFrom-Json
    Check "the help document has the command" 1 @($help.commands | Where-Object { $_.command -eq "describe" }).Count
    Check "in the add-ons group" $true ((@($help.groups | Where-Object { $_.title -eq "Add-ons" })[0].commands) -contains "describe")
    $page = @($help.commands | Where-Object { $_.command -eq "describe" })[0]
    foreach ($opt in @("--approve", "--role", "--owner", "--no-comments", "--show", "--version", "--versions", "--comments")) {
        Contains "the options list $opt" $opt $page.options
    }
    Contains "the page says what approve writes" "descriptors/<id>/v<n>.yaml" $page.description
    Contains "and the comment it writes" "role: <role> (starter kit, descriptor <id> v<n>)" $page.description
    Contains "and the view for a virtual table" "STARTER_KIT.<ID>_DESCRIBED" $page.description
    Contains "and exit 5" "5 when another approve" $page.description
    Contains "with an approve example" "exakit describe orders --approve" ($page.examples -join "`n")
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$(Split-Path -Leaf $PSCommandPath): $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -ne 0) { exit 1 }
