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

Write-Host "== the kit moves first, then the new kit updates the rest (#45) =="
# The real Invoke-ExakitUpdateRun with the updaters stood in: after the kit's own update this process holds the
# old code and manifest, so it must not update another component itself.
$run = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-ExakitUpdateRun" }, $true)
Invoke-Expression $run.Extent.Text
$script:VersionPolicy = "pinned"
$script:kit = "0.2.0"
$script:log = New-Object System.Collections.ArrayList
$script:BinDir = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-update-run-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
function Write-ExakitVersionsSourceLine { }
function Get-ExakitActualTarget([string]$Name) { return $Name }
function Get-ExakitComponentCurrent([string]$Name) { if ($Name -eq "exakit") { return $script:kit } return "1.0" }
function Get-ExakitComponentAvailable([string]$Name) { if ($Name -eq "exakit") { return "0.2.3" } return "2.0" }
function Test-ExakitComponentManaged { return $true }
function Test-ExakitComponentSupported { return $true }
function Test-ExakitComponentAhead { return $false }
function Test-ExakitComponentHeavy { return $false }
function Get-ExakitComponentMinKit { return "" }
function Test-ExakitMinKitSatisfied { return $true }
function Info([string]$Message) { [void]$script:log.Add("info:$Message") }
function Ok([string]$Message) { }
$script:notes = New-Object System.Collections.ArrayList
function Add-ExakitUpdateNote { param([string]$Component, [string]$Outcome, [string]$From, [string]$To, [string]$Remedy)
    if ($script:ExakitUpdateJson) { [void]$script:notes.Add("$Component|$Outcome|$Remedy") } }
function Update-ExakitSelf { [void]$script:log.Add("this-process:exakit"); $script:kit = "0.2.3" }
function Get-ExakitMarketplaceAddon([string]$Id) { return [pscustomobject]@{ UpdateFn = "Update-StandIn-$Id" } }
function Update-StandIn-dbt-exasol { [void]$script:log.Add("this-process:dbt-exasol") }
function Update-StandIn-exasol-scheduler { [void]$script:log.Add("this-process:exasol-scheduler") }
$onWindows = $true
if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { $onWindows = [bool]$IsWindows }
$fakeKit = Join-Path $script:BinDir "exakit.cmd"
$asked = Join-Path $script:BinDir "asked.txt"
if ($onWindows) {
    "@echo new-kit:%*> `"$asked`"" | Set-Content -Path $fakeKit -Encoding ascii
} else {
    "#!/bin/sh`nprintf 'new-kit:%s' `"`$*`" > `"$asked`"" | Set-Content -Path $fakeKit -Encoding ascii
    & chmod +x $fakeKit
}
try {
    $script:ExakitUpdateJson = $false
    Invoke-ExakitUpdateRun -Target "all" -Components @("exakit", "exasol-scheduler", "dbt-exasol")
    Check "the kit is updated in this process" "True" ($script:log -contains "this-process:exakit")
    Check "...and no add-on with the old code" "False" (($script:log -contains "this-process:exasol-scheduler") -or ($script:log -contains "this-process:dbt-exasol"))
    Check "the new kit is asked to update the rest" "new-kit:update exasol-scheduler dbt-exasol" ((Get-Content -Raw $asked).Trim())

    $script:kit = "0.2.0"; $script:log.Clear()
    $script:ExakitUpdateJson = $true
    $script:notes.Clear()
    Invoke-ExakitUpdateRun -Target "all" -Components @("exakit", "exasol-scheduler", "dbt-exasol")
    Check "under --json the rest is deferred with the command that applies it" "True" ($script:notes -contains "exasol-scheduler|deferred|exakit update exasol-scheduler dbt-exasol")
} finally {
    Remove-Item -Recurse -Force $script:BinDir -ErrorAction SilentlyContinue
}

Write-Host "update-targets-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
