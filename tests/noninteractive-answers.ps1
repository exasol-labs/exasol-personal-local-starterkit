# noninteractive-answers.ps1 - PowerShell-native twin of
# tests/noninteractive-answers.sh. Proves the Windows install path resolves the
# same pre-set environment answers an agent-driven or scripted install relies
# on, so the documented EXAKIT_MCP_CLIENTS contract cannot silently drift from
# the bash side (as it had - the .ps1 path used to ignore these vars entirely).
#
# Pure logic: dot-sources the Windows lib chain against a throwaway state dir
# and exercises ConvertTo-McpClientSelection (what EXAKIT_MCP_CLIENTS feeds).
# No installs, no database, no changes to the real machine.
#
#   pwsh tests/noninteractive-answers.ps1        # PowerShell 7+
#   powershell tests/noninteractive-answers.ps1  # Windows PowerShell 5.1

$ErrorActionPreference = "Stop"
$lib = Join-Path $PSScriptRoot "..\setup\lib"

# Point the kit's state + bin dirs at a throwaway location so loading the libs
# never touches the real ~/.exasol-starter-kit.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-nia-" + [guid]::NewGuid().ToString("N"))
$env:EXAKIT_HOME = $tmp
$env:EXAKIT_BIN_DIR = Join-Path $tmp "bin"

$script:Pass = 0
$script:Fail = 0
function Check {  # Check <label> <expected> <actual (array or string)>
    param([string]$Label, [string]$Expected, $Actual)
    $got = ($Actual -join ",")
    if ($got -eq $Expected) {
        $script:Pass++; Write-Host ("  ok   {0} = {1}" -f $Label, $got)
    } else {
        $script:Fail++; Write-Host ("  FAIL {0}: expected {1}, got {2}" -f $Label, $Expected, $got)
    }
}

try {
    . (Join-Path $lib "exakit-common.ps1")
    . (Join-Path $lib "exapump.ps1")
    . (Join-Path $lib "mcp.ps1")

    Write-Host "the runtime update offer - an unattended run is never asked, so it never stops a database:"
    # `exakit update` applies the runtime (which stops the database) only for an
    # answer it was actually given. Twin of the same block in the bash test; the
    # helpers live in the CLI, loaded with a harmless command.
    . (Join-Path $PSScriptRoot "..\setup\exakit.ps1") -Command "help" *> $null
    Remove-Item Env:EXAKIT_CONFIRM_RUNTIME_UPDATE -ErrorAction SilentlyContinue
    $unanswered = Get-ExakitRuntimeUpdatePreanswer
    if (-not $unanswered) { $unanswered = "" }
    Check "nobody has answered yet" "" $unanswered
    $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = "1"
    Check "EXAKIT_CONFIRM_RUNTIME_UPDATE=1 opts in" "yes" (Get-ExakitRuntimeUpdatePreanswer)
    $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = "no"
    Check "=no is a deliberate refusal" "no" (Get-ExakitRuntimeUpdatePreanswer)
    $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = "maybe"
    $vague = Get-ExakitRuntimeUpdatePreanswer
    if (-not $vague) { $vague = "" }
    Check "an unrecognised value answers nothing" "" $vague
    Remove-Item Env:EXAKIT_CONFIRM_RUNTIME_UPDATE -ErrorAction SilentlyContinue
    Check "-Yes opts in for one run" "yes" (Get-ExakitRuntimeUpdatePreanswer -AssumeYes $true)
    Check "the major version is read the same way" "2026" (Get-ExakitMajorVersion "2026.2.0")

    Write-Host "EXAKIT_MCP_CLIENTS - client selection parses names, 'all', and numbers:"
    # "claude" (or 1) expands to both Claude surfaces (desktop app + Claude Code
    # CLI); "all" covers every supported client. Keep these in lockstep with
    # ConvertTo-McpClientSelection in setup/lib/mcp.ps1 and the bash twin.
    Check "claude,cursor" "claude_desktop,claude_code,cursor" (ConvertTo-McpClientSelection "claude,cursor")
    Check "all"           "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue" (ConvertTo-McpClientSelection "all")
    Check "1,2"           "claude_desktop,claude_code,codex" (ConvertTo-McpClientSelection "1,2")
    Check "opencode"      "opencode" (ConvertTo-McpClientSelection "opencode")
    Check "number 6"      "opencode" (ConvertTo-McpClientSelection "6")
    Check "continue"      "continue" (ConvertTo-McpClientSelection "continue")
    Check "number 7"      "continue" (ConvertTo-McpClientSelection "7")
    Check "dedupes"       "claude_desktop,claude_code" (ConvertTo-McpClientSelection "claude,1,claude")
    Check "single surface" "claude_code" (ConvertTo-McpClientSelection "claude_code")
    Check "copilot"       "vscode_copilot" (ConvertTo-McpClientSelection "copilot")
    Check "gemini"        "gemini_cli" (ConvertTo-McpClientSelection "gemini")

    # The same answer, however it is typed - case, spaces, a trailing comma - as on bash; empty and the
    # callers' own words ("skip") are not clients.
    Check "case and spaces" "claude_desktop,claude_code,cursor" ((ConvertTo-McpClientSelection " Claude , Cursor ") -join ",")
    Check "upper case"      "claude_desktop,claude_code" ((ConvertTo-McpClientSelection "CLAUDE") -join ",")
    Check "trailing comma"  "claude_desktop,claude_code" ((ConvertTo-McpClientSelection "claude,") -join ",")
    Check "ALL with spaces" "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue" ((ConvertTo-McpClientSelection " ALL ") -join ",")
    foreach ($bad in @("", "  ", ",", "skip", "none", "all,claude")) {
        $got = ConvertTo-McpClientSelection $bad
        if ($null -eq $got) { $script:Pass++; Write-Host "  ok   [$bad] is not a selection = rejected" }
        else { $script:Fail++; Write-Host ("  FAIL [$bad] is not a selection: expected rejected, got {0}" -f ($got -join ",")) }
    }
    $invalid = ConvertTo-McpClientSelection "bogus"
    if ($null -eq $invalid) {
        $script:Pass++; Write-Host "  ok   invalid rejected = rejected"
    } else {
        $script:Fail++; Write-Host ("  FAIL invalid rejected: expected rejected, got {0}" -f ($invalid -join ","))
    }

    Write-Host "every dataset already loaded, no console - nothing is asked, nothing fails:"
    # Twin of the same block in the bash test: the pre-ticked local-file row
    # must not stand when nobody is there to name a file.
    function Get-ExakitPendingDatasets { return @() }
    $script:UiFancy = $false
    $infoSeen = New-Object System.Collections.ArrayList
    function Info([string]$M) { [void]$infoSeen.Add($M) }
    $chosen = @(Select-ExakitDataLoad -FinalLabel "Skip" 6> $null)
    Check "selection is none, not local" "none" $chosen
    Check "...and says how to load a file unattended" "True" (($infoSeen -join " ").Contains("name it with EXAKIT_DATA_FILE"))

    Write-Host "the install's data answers - each row its own, in the table's order:"
    # The real installer step (Request-ExakitDataLoadOffer) with the loaders as
    # stubs: what ran, in order, then whether it threw. `external` names the
    # external-source row: unattended it is only ever the command to run - the
    # wizard (a stub here that says CONNECT) is never started. Twin of the same
    # block in the bash test.
    function Get-ExakitBundledDatasets { return @("tpch", "energy", "amazon_sales") | ForEach-Object { [pscustomobject]@{ Id = $_; Label = $_ } } }
    function Invoke-ExakitDatasetLoad { param($KitRoot, $Id, [switch]$Force) [void]$script:Ran.Add("LOAD $Id") }
    function Invoke-ExakitSampleDataLoad { param($KitRoot, [switch]$Force) [void]$script:Ran.Add("LOAD tpch(sample)") }
    function Import-ExakitLocalFile { [void]$script:Ran.Add("FILE $($env:EXAKIT_DATA_FILE)"); return "loaded" }
    function Invoke-ExakitVsConnectWizard { [void]$script:Ran.Add("CONNECT"); return 0 }
    function Warn2([string]$M) { [void]$infoSeen.Add($M) }
    function Fail([string]$M) { throw "FAIL: $M" }
    function Offer([hashtable]$Answers) {
        $script:Ran = New-Object System.Collections.ArrayList
        $infoSeen.Clear()
        foreach ($k in $Answers.Keys) { [Environment]::SetEnvironmentVariable($k, $Answers[$k], 'Process') }
        $threw = ""
        try { Request-ExakitDataLoadOffer -KitRoot $tmp } catch { $threw = "THREW" }
        foreach ($k in @("EXAKIT_DATASETS", "EXAKIT_LOAD_SAMPLE", "EXAKIT_DATA_FILE")) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
        return "$($script:Ran -join ';')~$threw"
    }
    $mine = Join-Path $tmp "mine.csv"
    Check "EXAKIT_DATASETS=tpch,external: the dataset loads, the wizard does not start" "LOAD tpch~" (Offer @{ EXAKIT_DATASETS = "tpch,external" })
    Check "...the external row is one line naming the command" "True" (($infoSeen -join " ").Contains("needs a terminal. Connect one any time with: exakit connect"))
    Check "...and external is not an unknown id" "False" (($infoSeen -join " ").Contains("Unknown dataset id 'external'"))
    Check "EXAKIT_DATASETS=external alone: an answer, nothing loaded, nothing failed" "~" (Offer @{ EXAKIT_DATASETS = "external" })
    Check "an id the kit does not ship still fails the step" "~THREW" (Offer @{ EXAKIT_DATASETS = "nope" })
    Check "EXAKIT_DATASETS and EXAKIT_DATA_FILE: the datasets, then the file" "LOAD amazon_sales;FILE $mine~" (Offer @{ EXAKIT_DATASETS = "amazon_sales,external"; EXAKIT_DATA_FILE = $mine })
    Check "...then the external row's command, last" "True" (($infoSeen[$infoSeen.Count - 1]).Contains("Connect one any time with: exakit connect"))
    Check "EXAKIT_LOAD_SAMPLE=0 and a file: the samples are skipped, the file loads" "FILE $mine~" (Offer @{ EXAKIT_LOAD_SAMPLE = "0"; EXAKIT_DATA_FILE = $mine })
    Check "EXAKIT_LOAD_SAMPLE=1 and a file: the sample, then the file" "LOAD tpch(sample);FILE $mine~" (Offer @{ EXAKIT_LOAD_SAMPLE = "1"; EXAKIT_DATA_FILE = $mine })
    [void](Offer @{ EXAKIT_LOAD_SAMPLE = "0" })
    Check "EXAKIT_LOAD_SAMPLE=0 alone still skips everything, as it said" "True" (($infoSeen -join " ").Contains("Skipping data loading (EXAKIT_LOAD_SAMPLE=0)"))
    function Get-ExakitPendingDatasets { return @([pscustomobject]@{ Id = "tpch"; Label = "TPC-H"; Description = "" }) }
    function Test-ExakitVsAvailable { return $true }
    Check "no answers, no console: the pending samples, never the wizard" "LOAD tpch~" (Offer @{})
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Remove-Item Env:EXAKIT_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:EXAKIT_BIN_DIR -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("noninteractive-answers (ps): {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -ne 0) { exit 1 }
