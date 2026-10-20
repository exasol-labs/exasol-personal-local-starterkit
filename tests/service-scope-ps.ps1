#!/usr/bin/env pwsh
# service-scope-ps.ps1 - `exakit start|stop <service>` on the Windows twin acts
# on ONE service, refuses what it cannot name, and `exakit stop database` asks
# before taking the database from under running add-ons. Twin of the stubbed
# half of tests/service-scope.sh, and the first suite to RUN these functions
# rather than grep the file for them: exakit.ps1 dispatches at the bottom, so
# it cannot be dot-sourced; the parser lifts the functions under test out of
# it and they run here over stubs - the database and an add-on's hooks are
# echoes, Deny throws where the CLI would exit 2, and the question is answered
# by EXAKIT_STOP_ADDONS the way a script answers it.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/service-scope-ps.ps1
#   pwsh -NoProfile -File tests/service-scope-ps.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Has($label, $needle, $haystack) {
    if ("$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$needle> in <$haystack>" }
}
function Lacks($label, $needle, $haystack) {
    if (-not "$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): did not expect <$needle> in <$haystack>" }
}

# --- the functions under test, lifted out of exakit.ps1 ----------------------
$wanted = @("Resolve-ExakitServiceScope", "Get-ExakitServiceIds", "Get-ExakitServiceStatus",
            "Start-ExakitService", "Stop-ExakitService", "Stop-ExakitDatabaseScoped",
            "Invoke-CmdStart", "Invoke-CmdStop")
# The service set itself lives in lib/exakit-common.ps1 (an add-on module stops
# and starts services around a restart); the scoped commands stay in the CLI.
$defs = @()
foreach ($file in @("setup\exakit.ps1", "setup\lib\exakit-common.ps1")) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$file does not parse: $($errors[0].Message)" }
    $defs += @($ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($wanted -contains $n.Name) }, $true))
}
Check "every function under test is defined in exakit.ps1 or lib/exakit-common.ps1" $wanted.Count $defs.Count
foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

# --- the machine, replaced by echoes --------------------------------------------
$script:log = New-Object System.Collections.ArrayList
function Note([string]$Text) { [void]$script:log.Add($Text) }
function Assert-ExakitInstalled { param([switch]$Json) Note "require-install" }
function Initialize-ExakitLogging { }
function Write-ExakitLog { param($Kind, $Text) }
function Get-RuntimeType { return "personal" }
function Get-ExakitManifestValue { param([string]$Path) if ($Path -eq "runtime.type") { return "personal" }; return $null }
function Stop-Personal { Note "STOP database" }
function Start-ExakitDatabase { Note "START database" }
function Test-PersonalDeploymentRunning { return ($env:DB_UP -ne "0") }
function Get-ExakitMarketplaceInstalledAddons { return @("zzfake") }
function Get-ExakitMarketplaceAddon {
    param([string]$Id)
    if ($Id -eq "zzfake") {
        return [pscustomobject]@{ Id = "zzfake"; StatusFn = "Invoke-ZzfakeStatus"; StartFn = "Invoke-ZzfakeStart"; StopFn = "Invoke-ZzfakeStop" }
    }
    if ($Id -eq "exasol-scheduler") { return [pscustomobject]@{ Id = "exasol-scheduler"; StatusFn = "Invoke-NoSuchFn" } }
    return $null
}
function Test-ExakitMarketplaceAddonInstalled { param([string]$Id) return ($Id -eq "zzfake") }
function Invoke-ZzfakeStatus { if ($env:ZZ_STATUS) { return $env:ZZ_STATUS }; return "running" }
function Invoke-ZzfakeStart { Note "START zzfake" }
function Invoke-ZzfakeStop { Note "STOP zzfake" }
function Info([string]$Msg) { Note "INFO $Msg" }
function Ok([string]$Msg) { Note "OK $Msg" }
function Warn2([string]$Msg) { Note "WARN $Msg" }
function Deny-ExakitInput { param([string]$Message, $Remedy = $null) Note "REJECT $Message"; throw "DENY" }
# The question, answered the way a script answers it; no console is asked.
function Confirm-ExakitEnvPrompt {
    param([string]$EnvName, [string]$Question, [bool]$DefaultYes = $false)
    $preset = [Environment]::GetEnvironmentVariable($EnvName)
    if ($preset -cmatch '^(1|y|Y|yes|YES|Yes)$') { return $true }
    if ($preset -cmatch '^(0|n|N|no|NO|No)$') { return $false }
    Note "ASKED $Question"
    return $DefaultYes
}
function Run([scriptblock]$Body) {
    $script:log.Clear()
    try { & $Body } catch { if ("$_" -notmatch "DENY") { throw } }
    return ($script:log -join "`n")
}
function Order($text, $first, $second) {
    $lines = @("$text" -split "`n"); $a = [array]::IndexOf($lines, $first); $b = [array]::IndexOf($lines, $second)
    if ($a -ge 0 -and $b -ge 0 -and $a -lt $b) { return "yes" }; return "no"
}
Remove-Item Env:EXAKIT_STOP_ADDONS -ErrorAction SilentlyContinue
Remove-Item Env:ZZ_STATUS -ErrorAction SilentlyContinue
Remove-Item Env:DB_UP -ErrorAction SilentlyContinue

Write-Host "--- stop"
$bare = Run { Invoke-CmdStop -Scope @() }
Has   "bare stop stops the add-on"                 "STOP zzfake"   $bare
Has   "...and then the database"                   "STOP database" $bare
Check "...add-ons first"                           "yes" (Order $bare "STOP zzfake" "STOP database")

$one = Run { Invoke-CmdStop -Scope @("zzfake") }
Has   "stop <addon> stops that add-on"             "STOP zzfake"   $one
Lacks "...and leaves the database alone"           "STOP database" $one

$env:EXAKIT_STOP_ADDONS = "0"
$dbNo = Run { Invoke-CmdStop -Scope @("database") }
Has   "stop database, answered no, stops the database" "STOP database" $dbNo
Lacks "...and leaves the running add-on alone"     "STOP zzfake"   $dbNo
Has   "...naming what still runs without it"       "Still running without it: zzfake" $dbNo
Has   "...and the start it will need afterwards"   "you must also start it: exakit start zzfake" $dbNo

$env:EXAKIT_STOP_ADDONS = "1"
$dbYes = Run { Invoke-CmdStop -Scope @("database") }
Has   "stop database, answered yes, stops the add-on too" "STOP zzfake" $dbYes
Has   "...and the database"                        "STOP database" $dbYes
Check "...add-ons first"                           "yes" (Order $dbYes "STOP zzfake" "STOP database")
Lacks "...with no reminder to give"                "you must also start" $dbYes

Remove-Item Env:EXAKIT_STOP_ADDONS
$dbAsk = Run { Invoke-CmdStop -Scope @("database") }
Has   "no answer and no console: the question was put" "ASKED Stop them too, before the database" $dbAsk
Has   "...and the add-on is stopped too (the safe default)" "STOP zzfake" $dbAsk
Has   "...after naming it"                         "Running add-on services need the database: zzfake" $dbAsk

$env:ZZ_STATUS = "stopped"
$dbQuiet = Run { Invoke-CmdStop -Scope @("database") }
Has   "a stopped add-on raises no question"        "STOP database" $dbQuiet
Lacks "...and is not stopped again"                "STOP zzfake"   $dbQuiet
Lacks "...nor named"                               "need the database" $dbQuiet
Remove-Item Env:ZZ_STATUS

$bad = Run { Invoke-CmdStop -Scope @("nosuch") }
Has   "stop nosuch is refused"                     "REJECT Unknown service 'nosuch'" $bad
Has   "...listing the services"                    "database, zzfake" $bad
Lacks "...and nothing was stopped"                 "STOP" $bad
$two = Run { Invoke-CmdStop -Scope @("a", "b") }
Has   "two ids are refused"                        "REJECT stop takes at most one service id" $two
Lacks "...and nothing was stopped"                 "STOP" $two
$gone = Run { Invoke-CmdStop -Scope @("exasol-scheduler") }
Has   "a registered add-on that is not installed is refused" "is not installed" $gone
Has   "...naming the marketplace"                  "exakit marketplace exasol-scheduler" $gone
Lacks "...and nothing was stopped"                 "STOP" $gone

Write-Host "--- start"
$bs = Run { Invoke-CmdStart -Scope @() }
Has   "bare start starts the database"             "START database" $bs
Has   "...and the add-on"                          "START zzfake"   $bs
$sa = Run { Invoke-CmdStart -Scope @("zzfake") }
Has   "start <addon> starts that add-on"           "START zzfake"   $sa
Lacks "...and does not start the database"         "START database" $sa
$sd = Run { Invoke-CmdStart -Scope @("database") }
Has   "start database starts the database"         "START database" $sd
Lacks "...and not the add-on"                      "START zzfake"   $sd
$env:DB_UP = "0"
$down = Run { Invoke-CmdStart -Scope @("zzfake") }
Has   "start <addon> with the database down is refused" "REJECT The database is not running, and zzfake needs it" $down
Has   "...naming the bare command"                 "exakit start" $down
Lacks "...starting nothing"                        "START" $down
Remove-Item Env:DB_UP

Write-Host ""
Write-Host "$($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
exit 0
