#!/usr/bin/env pwsh
# update-targets-ps.ps1 - `exakit update` takes several component ids, as `exakit marketplace` does (#47). The
# real Invoke-CmdUpdate from setup/exakit.ps1 runs with the run itself stood in, so what it would update is
# visible without updating anything. Twin of the #47 checks in update-command-surface.sh. Runs under Windows
# PowerShell 5.1 and pwsh.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0; $script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -ceq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/exakit.ps1"), [ref]$tokens, [ref]$errors)
$definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-CmdUpdate" }, $true)
Invoke-Expression $definition.Extent.Text

$known = @("exakit", "exapump", "uv", "mcp", "pyexasol", "dbt-exasol", "dash-server")
function Assert-ExakitInstalled { }
function Initialize-ExakitLogging { }
function Confirm-ExakitTlsPinned { }   # the TLS pin (SEC-14) has its own suite: tls-pin-ps.ps1
function Test-ExakitUpdateTarget([string]$Target) { return ($Target -eq "all" -or $known -contains $Target) }
function Get-ExakitUpdateTargets([string]$Target) { if ($Target -eq "all") { return $known } return @($Target) }
function Deny-ExakitInput([string]$Message) { throw "DENIED: $Message" }
function Invoke-ExakitUpdateRun { param([string]$Target, $Components, [bool]$AssumeYes)
    $script:ran = "target=$Target|components=$(@($Components) -join ',')" }

function Run([string]$Target, [string[]]$More) {
    $script:ran = ""
    try { Invoke-CmdUpdate -Target $Target -More $More; return $script:ran } catch { return "$($_.Exception.Message)" }
}

Write-Host "== several ids =="
Check "two ids update both" "target=exapump dbt-exasol|components=exapump,dbt-exasol" (Run "exapump" @("dbt-exasol"))
Check "a repeated id is updated once" "target=exapump dbt-exasol exapump|components=exapump,dbt-exasol" (Run "exapump" @("dbt-exasol", "exapump"))
Check "one id still updates just that one" "target=exapump|components=" (Run "exapump" @())

Write-Host "== refusals =="
Check "an unknown second id is named" "True" ((Run "exapump" @("nonsense")) -match "Unknown update target 'nonsense'")
Check "'all' beside other ids is refused" "True" ((Run "exapump" @("all")) -match "cannot be named beside other components")
Check "ids after 'all' are refused" "True" ((Run "all" @("exapump")) -match "updates everything")

Write-Host "== the kit moves first, then the new kit finishes the run (#45) =="
# The real Invoke-ExakitUpdateRun with the updaters stood in: after the kit's own update this process holds the
# old code and manifest, so it updates nothing else and hands the run to the new kit (core-setup.ps1's
# Invoke-ExakitUpdateHandover, stood in here; tests/core-setup.ps1 runs the real one). "all" stays all, named ids
# hand over the kit and the ids after it, and the run uses the ids -Components holds - never the joined -Target
# string, which once failed as "Unknown update target: exapump dbt-exasol". Twin of the #45 checks in
# update-command-surface.sh.
$run = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-ExakitUpdateRun" }, $true)
Invoke-Expression $run.Extent.Text
$hoTarget = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-ExakitHandoverTarget" }, $true)
Invoke-Expression $hoTarget.Extent.Text
$script:VersionPolicy = "pinned"
$script:kit = "0.2.0"
$script:log = New-Object System.Collections.ArrayList
function Write-ExakitVersionsSourceLine { }
function Get-ExakitActualTarget([string]$Name) { return $Name }
function Get-ExakitComponentCurrent([string]$Name) { if ($Name -eq "exakit") { return $script:kit } return "1.0" }
function Get-ExakitComponentAvailable([string]$Name) { if ($Name -eq "exakit") { return "0.2.3" } return "2.0" }
function Get-ExakitManifestValue([string]$Key) { if ($Key -eq "kit.version") { return $script:kit } return "" }
function Test-ExakitComponentManaged { return $true }
function Test-ExakitComponentSupported { return $true }
function Test-ExakitComponentAhead { return $false }
function Test-ExakitComponentHeavy { return $false }
function Get-ExakitComponentMinKit { return "" }
function Test-ExakitMinKitSatisfied { return $true }
function Info([string]$Message) { [void]$script:log.Add("info:$Message") }
function Ok([string]$Message) { }
function Warn2([string]$Message) { [void]$script:log.Add("warn:$Message") }
$script:notes = New-Object System.Collections.ArrayList
function Add-ExakitUpdateNote { param([string]$Component, [string]$Outcome, [string]$From, [string]$To, [string]$Remedy)
    [void]$script:notes.Add("$Component|$Outcome|$Remedy") }
function Update-ExakitSelf { [void]$script:log.Add("this-process:exakit"); $script:kit = "0.2.3"; $script:ExakitKitSwapped = $true }
function Get-ExakitMarketplaceAddon([string]$Id) { return [pscustomobject]@{ UpdateFn = "Update-StandIn-$Id" } }
function Update-StandIn-dbt-exasol { [void]$script:log.Add("this-process:dbt-exasol") }
function Update-StandIn-exasol-scheduler { [void]$script:log.Add("this-process:exasol-scheduler") }
$script:handedOver = $null
$script:handoverAnswer = 0
function Invoke-ExakitUpdateHandover { param([string]$Target = "all", [bool]$AssumeYes = $false)
    $script:handedOver = $Target
    # Under --json the new run's rows come back into this run's results (Invoke-ExakitUpdateHandover merges them).
    if ($null -ne $script:handoverAnswer -and $script:ExakitUpdateJson) {
        foreach ($id in @($Target -split ' ' | Where-Object { $_ -and $_ -ne "exakit" })) {
            if ($id -eq "all") { foreach ($one in @("exasol-scheduler", "dbt-exasol")) { [void]$script:notes.Add("$one|updated|") } }
            else { [void]$script:notes.Add("$id|updated|") }
        }
    }
    return $script:handoverAnswer
}
function Reset-Run { $script:kit = "0.2.0"; $script:log.Clear(); $script:notes.Clear(); $script:handedOver = $null; $script:handoverAnswer = 0 }

$script:ExakitUpdateJson = $false
Invoke-ExakitUpdateRun -Target "all" -Components @("exakit", "exasol-scheduler", "dbt-exasol")
Check "the kit is updated in this process" "True" ($script:log -contains "this-process:exakit")
Check "...and no add-on with the old code" "False" (($script:log -contains "this-process:exasol-scheduler") -or ($script:log -contains "this-process:dbt-exasol"))
Check "the new kit is handed the run: all stays all" "all" $script:handedOver

Reset-Run
$script:ExakitUpdateJson = $true
Invoke-ExakitUpdateRun -Target "all" -Components @("exakit", "exasol-scheduler", "dbt-exasol")
Check "under --json the handed-over run's rows are the answer" "exasol-scheduler|updated|;dbt-exasol|updated|" (@($script:notes | Where-Object { $_ -notlike "exakit|*" }) -join ";")
Check "...and nothing is deferred" "" (@($script:notes | Where-Object { $_ -like "*|deferred|*" }) -join ";")
$script:ExakitUpdateJson = $false

Reset-Run
Invoke-ExakitUpdateRun -Target "exasol-scheduler exakit dbt-exasol" -Components @("exasol-scheduler", "exakit", "dbt-exasol")
Check "several ids run from -Components, not the joined -Target" "this-process:exasol-scheduler|this-process:exakit" (@($script:log | Where-Object { $_ -like "this-process:*" }) -join "|")
Check "...the kit and the ids after it are handed over" "exakit dbt-exasol" $script:handedOver

Reset-Run
Invoke-ExakitUpdateRun -Target "exasol-scheduler dbt-exasol" -Components @("exasol-scheduler", "dbt-exasol")
Check "several ids without the kit: each is updated here, nothing is handed over" "this-process:exasol-scheduler|this-process:dbt-exasol|" ((@($script:log | Where-Object { $_ -like "this-process:*" }) -join "|") + "|" + $script:handedOver)

Reset-Run
$script:handoverAnswer = $null
$script:ExakitUpdateJson = $true
Invoke-ExakitUpdateRun -Target "all" -Components @("exakit", "exasol-scheduler", "dbt-exasol")
Check "no new command to hand over to: the rest is deferred to the next run" "exasol-scheduler|deferred|exakit update;dbt-exasol|deferred|exakit update" (@($script:notes | Where-Object { $_ -like "*|deferred|*" }) -join ";")
$script:ExakitUpdateJson = $false

Write-Host "update-targets-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
