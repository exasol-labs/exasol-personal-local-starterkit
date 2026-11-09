#!/usr/bin/env pwsh
# core-setup.ps1 - the Windows twin of tests/core-setup.sh, run rather than
# grepped: setup\lib\core-setup.ps1 is dot-sourced as-is and the kit around it
# is replaced by stubs. The Python coordinators under setup\core are the REAL
# ones, so what is pending, what gets recorded and how the installer is rerun
# are exactly what a Windows machine runs.
#
#   1. tasks / pending / complete through Invoke-ExakitPythonFile, including
#      that no empty argument ever reaches a native command.
#   2. The database step: the handler's LAST output is its verdict, and a task
#      is recorded only after its step passed.
#   3. `exakit update`'s pending-task check: scoped updates, reruns and a
#      stopped database are left alone; a pending task reruns the installer
#      once, pinned to the installed versions, and the pins do not leak.
#   4. The handover: the new exakit.ps1 runs once, its --json rows are merged
#      back, and the environment is restored. Under --json the new run is a
#      --json run (a failed updater is a row, the rest are still tried), and
#      it writes the error and hint fields only to a parent that declared it
#      reads them, so an older kit's five-field reader keeps its remedy.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/core-setup.ps1
#   pwsh -NoProfile -File tests/core-setup.ps1
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

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-core-ps-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$isWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
# A temp HOME and bin dir for every child process below. Each one dot-sources
# exakit-common.ps1, which creates the kit's bin dir as it loads; with neither
# set that was an empty .local/bin in the developer's real home on macOS/Linux.
$env:HOME = Join-Path $work "userhome"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
New-Item -ItemType Directory -Force -Path $env:HOME | Out-Null

# The kit runs `python`. Where only python3 exists (macOS, many Linux images),
# a shim directory supplies the name.
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    $py3 = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $py3) { Write-Host "python is required for this suite"; exit 1 }
    $shim = Join-Path $work "shim"
    New-Item -ItemType Directory -Force -Path $shim | Out-Null
    New-Item -ItemType SymbolicLink -Path (Join-Path $shim "python") -Target $py3.Source | Out-Null
    $env:PATH = $shim + [System.IO.Path]::PathSeparator + $env:PATH
}

# --- the kit around the module, replaced -------------------------------------
$script:ExakitHome = Join-Path $work "home"
$script:ManifestPath = Join-Path $script:ExakitHome "manifest.json"
$script:LogFile = Join-Path $work "setup.log"
$script:ManagedPythonVersion = "3.12"
$script:ExakitUpdateJson = $false
New-Item -ItemType Directory -Force -Path $script:ExakitHome | Out-Null
$script:events = New-Object System.Collections.ArrayList
function Note([string]$Text) { [void]$script:events.Add($Text) }
function Test-ExakitSystemPython { return $true }
function Install-ExakitUv { throw "uv must not be needed here" }
function Write-ExakitLog { param($Level, $Msg) Add-Content -LiteralPath $script:LogFile -Value "$Level $Msg" }
function Info([string]$Msg) { Note "INFO $Msg" }
function Ok([string]$Msg) { Note "OK $Msg" }
function OkStep([string]$Msg) { Note "OKSTEP $Msg" }
function Warn2([string]$Msg) { Note "WARN $Msg" }
function Get-ExakitManifestValue {
    param([string]$Path)
    $doc = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
    $node = $doc
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $node -or -not $node.PSObject.Properties[$part]) { return $null }
        $node = $node.$part
    }
    return $node
}
function Get-ExakitComponentCurrent { param([string]$Component) if ($Component -eq "personal") { return "2.3.0" }; return $null }
function Test-PersonalDeploymentRunning { return ($env:FAKE_DB_UP -ne "0") }
function Get-ExakitRepoRoot { return (Join-Path $script:ExakitHome "kit") }
$script:notes = New-Object System.Collections.ArrayList
function Add-ExakitUpdateNote {
    param([string]$Component, [string]$Outcome, [string]$From = "", [string]$To = "", [string]$Remedy = "")
    [void]$script:notes.Add("$Component|$Outcome|$From|$To|$Remedy")
}

# Invoke-ExakitPythonFile lives in the shared layer; lifted out of it here so
# the rest of exakit-common.ps1 (logging, paths, the manifest) stays stubbed.
$commonAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo (Join-Path "setup" (Join-Path "lib" "exakit-common.ps1"))), [ref]$null, [ref]$null)
foreach ($def in @($commonAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -eq "Invoke-ExakitPythonFile" }, $true))) {
    . ([scriptblock]::Create($def.Extent.Text))
}
. (Join-Path $repo (Join-Path "setup" (Join-Path "lib" "core-setup.ps1")))

function New-Manifest { Set-Content -LiteralPath $script:ManifestPath -Value '{"components": {}, "kit": {"source": "exasol-labs/kit@main"}}' -Encoding ASCII }
function Get-Completed {
    $doc = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
    if (-not $doc.PSObject.Properties["core_tasks"]) { return "" }
    return (@($doc.core_tasks.completed) -join ",")
}

Write-Host ""
Write-Host "== the handler map and the task list =="
foreach ($name in $script:ExakitCoreTaskHandlers.Keys) {
    Check "handler for $name is a function in core-setup.ps1" $true ([bool](Get-Command $script:ExakitCoreTaskHandlers[$name] -ErrorAction SilentlyContinue))
}
Check "the shipped list's database tasks" "preprocessor" ((Get-ExakitCoreTasks -KitRoot $repo -Scope "database") -join ",")
Check "...and nothing else in the kit scope" "" ((Get-ExakitCoreTasks -KitRoot $repo -Scope "kit") -join ",")

Write-Host ""
Write-Host "== pending and complete through the real manage.py =="
New-Manifest
Check "a fresh manifest: the preprocessor is pending" "preprocessor" ((Get-ExakitCorePending -KitRoot $repo) -join ",")
Check "complete records it" $true (Complete-ExakitCoreTask -KitRoot $repo -Name "preprocessor")
Check "...and nothing is pending any more" "" ((Get-ExakitCorePending -KitRoot $repo) -join ",")
$script:events.Clear()
Check "an unknown task is refused" $false (Complete-ExakitCoreTask -KitRoot $repo -Name "nope")
Has "...with a warning that names it" "nope" ($script:events -join "|")
Check "a kit copy without setup\core reads as unknown, not as nothing pending" $true ($null -eq (Get-ExakitCorePending -KitRoot $work))

Write-Host ""
Write-Host "== the database step =="
function Begin-ExakitStep { param($Name, $Description) Note "STEP $Description"; return $true }
function Register-ExakitSoftFailure { param($Component, $Repair, $Reason = "", $Label = "") Note "SOFT $Component|$Repair|$Reason" }
function Set-ExakitFailureReason { param([string]$Reason) $script:reason = $Reason }
function Get-ExakitFailureReason { $r = $script:reason; $script:reason = ""; return $r }
function Invoke-ExakitSoftStep {
    param($Component, $Repair, $Body, $Label = "")
    $result = & $Body
    if ($result -is [bool] -and -not $result) { Register-ExakitSoftFailure -Component $Component -Repair $Repair -Reason (Get-ExakitFailureReason); return $false }
    return $true
}
New-Manifest
$script:events.Clear()
function Invoke-ExakitCoreTaskPreprocessor { param($KitRoot) "a leaked pipeline object"; Set-ExakitFailureReason "the slot is taken"; return $false }
Invoke-ExakitCoreDatabaseStep -Label "Step 4/7  Configure database features" -KitRoot $repo
Has "a handler that leaked output and then failed is a failure" "SOFT preprocessor|exakit update|the slot is taken" ($script:events -join "|")
Check "...and nothing is recorded" "" (Get-Completed)
function Invoke-ExakitCoreTaskPreprocessor { param($KitRoot) OkStep "fake framework ready"; return $true }
$script:events.Clear()
Invoke-ExakitCoreDatabaseStep -Label "Step 4/7  Configure database features" -KitRoot $repo
Has "the step announces itself" "STEP Step 4/7  Configure database features" ($script:events -join "|")
Check "a passing handler records the task" "preprocessor" (Get-Completed)

Write-Host ""
Write-Host "== exakit update: the pending-task check =="
$kit = Join-Path $script:ExakitHome "kit"
$kitSetup = Join-Path $kit "setup"
New-Item -ItemType Directory -Force -Path $kitSetup | Out-Null
Copy-Item -Recurse -Force (Join-Path $repo (Join-Path "setup" "core")) $kitSetup
$calls = Join-Path $work "installer-calls"
$fakeInstaller = @'
param()
Add-Content -LiteralPath '__CALLS__' -Value ("ran " + $env:EXAKIT_CORE_RERUN + " " + $env:EXAKIT_PERSONAL_VERSION + " " + $env:EXAKIT_KIT_SOURCE)
if ($env:FAKE_TASK_FAILS -ne "1") {
    & python (Join-Path (Join-Path (Join-Path '__KIT__' 'setup') 'core') 'manage.py') complete --tasks (Join-Path (Join-Path (Join-Path '__KIT__' 'setup') 'core') 'tasks.json') --manifest '__MANIFEST__' preprocessor
}
exit 0
'@
$fakeInstaller = $fakeInstaller.Replace("__CALLS__", $calls).Replace("__KIT__", $kit).Replace("__MANIFEST__", $script:ManifestPath)
Set-Content -LiteralPath (Join-Path $kitSetup "setup-windows.ps1") -Value $fakeInstaller -Encoding ASCII

function Reset-Update { New-Manifest; Remove-Item -Force -LiteralPath $calls -ErrorAction SilentlyContinue; $script:notes.Clear(); $script:events.Clear() }

Reset-Update
Check "a scoped update leaves it alone" $true (Invoke-ExakitCoreUpdateCheck -Target "exapump")
Check "...nothing ran" $false (Test-Path -LiteralPath $calls)

Reset-Update
$env:EXAKIT_CORE_RERUN = "1"
[void](Invoke-ExakitCoreUpdateCheck -Target "all")
Remove-Item Env:\EXAKIT_CORE_RERUN
Check "so does a check inside a rerun" $false (Test-Path -LiteralPath $calls)

Reset-Update
$env:FAKE_DB_UP = "0"
Check "a stopped database defers" $true (Invoke-ExakitCoreUpdateCheck -Target "all")
Remove-Item Env:\FAKE_DB_UP
Check "...without running the installer" $false (Test-Path -LiteralPath $calls)
Check "...booked as deferred with the remedy" "core-setup|deferred||preprocessor|exakit start && exakit update" ($script:notes -join ";")
Check "...and counted as work" $true $script:ExakitCoreUpdateActed

Reset-Update
$env:EXAKIT_EXAPUMP_VERSION = "9.9.9-mine"
Check "a pending task reruns the installer and completes" $true (Invoke-ExakitCoreUpdateCheck -Target "all")
Check "...exactly once, as a rerun, pinned, with the kit source" "ran 1 2.3.0 exasol-labs/kit@main" ((Get-Content -LiteralPath $calls) -join "|")
Check "...booked as updated" "core-setup|updated||preprocessor|" ($script:notes -join ";")
Check "...the pins it set do not outlive the rerun" "" "$env:EXAKIT_PERSONAL_VERSION"
Check "...and a pin the caller set is left as it was" "9.9.9-mine" "$env:EXAKIT_EXAPUMP_VERSION"
Remove-Item Env:\EXAKIT_EXAPUMP_VERSION

Remove-Item -Force -LiteralPath $calls -ErrorAction SilentlyContinue
$script:notes.Clear()
Check "with nothing pending, nothing runs" $true (Invoke-ExakitCoreUpdateCheck -Target "all")
Check "...no installer" $false (Test-Path -LiteralPath $calls)
Check "...not counted as work" $false $script:ExakitCoreUpdateActed

Reset-Update
$env:FAKE_TASK_FAILS = "1"
Check "a rerun that leaves the task pending fails the check" $false (Invoke-ExakitCoreUpdateCheck -Target "all")
Remove-Item Env:\FAKE_TASK_FAILS
Check "...booked as failed with the retry" "core-setup|failed||preprocessor|exakit update" ($script:notes -join ";")

Write-Host ""
Write-Host "== exakit update: the handover =="
$handoverCalls = Join-Path $work "handover-calls"
$fakeExakit = @'
Add-Content -LiteralPath '__CALLS__' -Value ("new " + ($args -join " ") + " handover=" + $env:EXAKIT_UPDATE_HANDOVER + " rows=" + $env:EXAKIT_UPDATE_ROW_FIELDS)
if ($env:EXAKIT_UPDATE_RESULTS_FILE) {
    Add-Content -LiteralPath $env:EXAKIT_UPDATE_RESULTS_FILE -Value "exapump|updated|1.0|2.0|"
    Add-Content -LiteralPath $env:EXAKIT_UPDATE_RESULTS_FILE -Value "mcp|failed|1.0|2.0|exakit update mcp|uvx did not answer|the hint"
}
exit 3
'@
Set-Content -LiteralPath (Join-Path $kitSetup "exakit.ps1") -Value $fakeExakit.Replace("__CALLS__", $handoverCalls) -Encoding ASCII
$script:ExakitUpdateJson = $true
$script:ExakitUpdateResults = New-Object System.Collections.ArrayList
$code = Invoke-ExakitUpdateHandover -Target "all" -AssumeYes $true
$script:ExakitUpdateJson = $false
Check "the new exakit.ps1 runs once, with the target, --yes and --json, told this reader takes seven fields" "new update all --yes --json handover=1 rows=7" ((Get-Content -LiteralPath $handoverCalls) -join "|")
Check "...its exit code comes back" 3 $code
Check "...a seven-field row keeps its error and hint" "mcp|exakit update mcp|uvx did not answer|the hint" (@($script:ExakitUpdateResults | Where-Object { $_.component -eq "mcp" } | ForEach-Object { "$($_.component)|$($_.remedy)|$($_.error)|$($_.hint)" }) -join ";")
Check "...its --json rows are merged into this run's" "exapump|updated|1.0|2.0|;mcp|failed|1.0|2.0|exakit update mcp" (($script:ExakitUpdateResults | ForEach-Object { "$($_.component)|$($_.outcome)|$($_.from)|$($_.to)|$($_.remedy)" }) -join ";")
Check "...and the handover variables are gone again" "||" ("$env:EXAKIT_UPDATE_HANDOVER|$env:EXAKIT_UPDATE_RESULTS_FILE|$env:EXAKIT_UPDATE_ROW_FIELDS")
Remove-Item -Force -LiteralPath (Join-Path $kitSetup "exakit.ps1")
Check "no new exakit.ps1: no handover" $true ($null -eq (Invoke-ExakitUpdateHandover -Target "all"))

# The two sides of a handover run different kits. The new run's rows are read
# by the OLD kit, and kits before the error and hint fields split a row into
# five and glued the rest onto remedy ("exakit update --yes||"). The real
# Add-ExakitUpdateNote, in its own process (this suite stubs it above).
Write-Host ""
Write-Host "== handover rows: five fields unless the reader declared seven =="
$rowsScript = Join-Path $work "rows.ps1"
Set-Content -LiteralPath $rowsScript -Encoding ASCII -Value @'
param([string]$Repo, [string]$Home2)
$env:EXAKIT_HOME = $Home2
New-Item -ItemType Directory -Force -Path $Home2 | Out-Null
. (Join-Path $Repo "setup/lib/exakit-common.ps1") *> $null
$script:ExakitUpdateJson = $true
$script:ExakitUpdateResults = New-Object System.Collections.ArrayList
Add-ExakitUpdateNote -Component "runtime" -Outcome "deferred" -From "2.3.0" -To "2.4.0" -Remedy "exakit update --yes" -ErrorText "a|b" -Hint "the hint"
Add-ExakitUpdateNote -Component "uv" -Outcome "updated" -From "0.13.6" -To "0.13.7"
'@
$rowsFile = Join-Path $work "rows"
$savedRowFields = $env:EXAKIT_UPDATE_ROW_FIELDS
$env:EXAKIT_UPDATE_HANDOVER = "1"
$env:EXAKIT_UPDATE_RESULTS_FILE = $rowsFile
foreach ($marker in @("", "7")) {
    Remove-Item -Force -LiteralPath $rowsFile -ErrorAction SilentlyContinue
    if ($marker) { $env:EXAKIT_UPDATE_ROW_FIELDS = $marker } else { Remove-Item Env:\EXAKIT_UPDATE_ROW_FIELDS -ErrorAction SilentlyContinue }
    & ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -File $rowsScript -Repo $repo -Home2 (Join-Path $work "rows-home") *> $null
    $lines = @(Get-Content -LiteralPath $rowsFile -ErrorAction SilentlyContinue)
    if (-not $marker) {
        Check "no marker: every row has exactly five fields" "5;5" (@($lines | ForEach-Object { @("$_" -split '\|').Count }) -join ";")
        # The reader of kits before the error and hint fields, verbatim.
        $oldRemedies = @($lines | ForEach-Object { $parts = "$_" -split '\|', 5; $parts[4] })
        Check "...and a five-field reader keeps each remedy intact" "exakit update --yes;" ($oldRemedies -join ";")
    } else {
        Check "marker 7: error and hint are written, the separator taken out" "runtime|deferred|2.3.0|2.4.0|exakit update --yes|a/b|the hint" $lines[0]
    }
}
$env:EXAKIT_UPDATE_HANDOVER = $null
$env:EXAKIT_UPDATE_RESULTS_FILE = $null
$env:EXAKIT_UPDATE_ROW_FIELDS = $savedRowFields

# A run handed over by a --json run is a --json run: the new kit's updater
# fails, and that is a row with its reason while the rest are still tried.
# Without it the first Fail ended the new run, no row named it, and every
# later component was never tried. The REAL Invoke-CmdUpdate and
# Invoke-ExakitUpdateRun from setup/exakit.ps1, started the way
# Invoke-ExakitUpdateHandover starts the new kit: the handover environment,
# and (as a kit before 0.3.0 starts it) no --json on the command line.
Write-Host ""
Write-Host "== a handed-over --json run is a --json run =="
$childScript = Join-Path $work "child.ps1"
Set-Content -LiteralPath $childScript -Encoding ASCII -Value @'
param([string]$Repo, [string]$Home2, [string]$Calls)
$env:EXAKIT_HOME = $Home2
New-Item -ItemType Directory -Force -Path $Home2 | Out-Null
. (Join-Path $Repo "setup/lib/exakit-common.ps1") *> $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo "setup/exakit.ps1"), [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent.Parent -eq $ast }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:VersionPolicy = "pinned"
function Assert-ExakitInstalled { param([switch]$Json) }
function Initialize-ExakitLogging { }
function Test-ExakitUpdateTarget { param($t) return $true }
function Get-ExakitUpdateTargets { param([string]$Target) return @("pyexasol", "uv") }
function Get-ExakitActualTarget { param($c) return $c }
function Get-ExakitComponentCurrent { param($c) return "1.0" }
function Get-ExakitComponentAvailable { param($c) return "2.0" }
function Test-ExakitComponentSupported { param($c) return $true }
function Test-ExakitComponentAhead { param($c) return $false }
function Test-ExakitComponentHeavy { param($c) return $false }
function Get-ExakitComponentMinKit { param($c) return "" }
function Write-ExakitVersionsSourceLine { }
function Invoke-ExakitWithSpinner { param([string]$Label, [scriptblock]$Body) & $Body }
function Invoke-ExakitCoreUpdateCheck { param([string]$Target) Add-Content -LiteralPath $Calls -Value "core-check"; return $true }
function Update-Pyexasol { Add-Content -LiteralPath $Calls -Value "pyexasol"; throw "pyexasol download failed: HTTP 503" }
function Update-ExakitUv { Add-Content -LiteralPath $Calls -Value "uv"; return $true }
Invoke-CmdUpdate -Target "all" -AssumeYes $false -Json $false
'@
$childCalls = Join-Path $work "child-calls"
$env:EXAKIT_UPDATE_HANDOVER = "1"
$env:EXAKIT_UPDATE_RESULTS_FILE = $rowsFile
$env:EXAKIT_UPDATE_ROW_FIELDS = "7"
Remove-Item -Force -LiteralPath $rowsFile, $childCalls -ErrorAction SilentlyContinue
& ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -File $childScript -Repo $repo -Home2 (Join-Path $work "child-home") -Calls $childCalls *> $null
$childCode = $LASTEXITCODE
$env:EXAKIT_UPDATE_HANDOVER = $null
$env:EXAKIT_UPDATE_RESULTS_FILE = $null
$env:EXAKIT_UPDATE_ROW_FIELDS = $savedRowFields
Check "the failed updater did not end the run: the next one ran, then the task check" "pyexasol|uv|core-check" (@(Get-Content -LiteralPath $childCalls -ErrorAction SilentlyContinue) -join "|")
$childRows = @(Get-Content -LiteralPath $rowsFile -ErrorAction SilentlyContinue)
Check "...the failure is a row with its reason and remedy" "pyexasol|failed|1.0|2.0|exakit update pyexasol|pyexasol download failed: HTTP 503|" (@($childRows | Where-Object { "$_".StartsWith("pyexasol|") }) -join ";")
Check "...the next component's row is there too" "uv|updated|1.0|2.0|||" (@($childRows | Where-Object { "$_".StartsWith("uv|") }) -join ";")
Check "...and the new run exits 1, as a --json run with a failed row does" 1 $childCode

# A KIT SWAP THAT WAS NOT HANDED OVER - on Windows usually staged for the
# moment the command exits - ends the work on the old code: the components
# after the kit are deferred to the next `exakit update`, and the new-setup
# check is not made here (this process holds the OLD task list and would rerun
# the OLD installer from a kit directory about to be renamed). The same REAL
# Invoke-CmdUpdate, a plain --json run, with Update-ExakitSelf staging the swap.
Write-Host ""
Write-Host "== a kit swap that was not handed over defers the rest and the new-setup check =="
$swapScript = Join-Path $work "swap.ps1"
Set-Content -LiteralPath $swapScript -Encoding ASCII -Value ((Get-Content -LiteralPath $childScript -Raw).Replace(
    'function Get-ExakitUpdateTargets { param([string]$Target) return @("pyexasol", "uv") }',
    'function Get-ExakitUpdateTargets { param([string]$Target) return @("exakit", "pyexasol") }
function Update-ExakitSelf { param($Advertised, $Installed) Add-Content -LiteralPath $Calls -Value "exakit"; $script:ExakitKitSwapped = $true }').Replace(
    'Invoke-CmdUpdate -Target "all" -AssumeYes $false -Json $false',
    'Invoke-CmdUpdate -Target "all" -AssumeYes $false -Json $true'))
$swapCalls = Join-Path $work "swap-calls"
Remove-Item -Force -LiteralPath $swapCalls -ErrorAction SilentlyContinue
# A Continue window: on 5.1 a native call with redirected stderr under Stop
# is a terminating error before its output is read.
$eapSwap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$swapOut = (& ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -File $swapScript -Repo $repo -Home2 (Join-Path $work "swap-home") -Calls $swapCalls 2>$null) -join "`n"
$ErrorActionPreference = $eapSwap
$swapJson = $null
try { $swapJson = $swapOut | ConvertFrom-Json } catch { }
Check "only the kit was updated: nothing ran after it, no new-setup check" "exakit" (@(Get-Content -LiteralPath $swapCalls -ErrorAction SilentlyContinue) -join "|")
Check "...the next component is deferred to the next run" "pyexasol:exakit update" (@($swapJson.deferred | ForEach-Object { "$($_.component):$($_.remedy)" }) -join ";")
Check "...and the run says so" "deferred|the starter kit itself was updated; run 'exakit update' again so the rest is updated by the new kit" ("$($swapJson.status)|$($swapJson.remedy_hint)")

# A HANDED-OVER RUN THAT FAILS OUTSIDE EVERY ROW - a Fail in the run body, or a
# throw from the new-setup check - still names its reason in the ONE object
# the parent prints. The new run's own object is discarded with its screen, so
# the reason travels as a run-level row (no component) in the results file;
# the parent used to answer only "the updated kit's update run did not finish
# (exit 1)" with remedy "exakit update". The REAL Invoke-CmdUpdate on both
# sides and the REAL Invoke-ExakitUpdateHandover between them: an in-place kit
# swap, `exakit update --json`, and a new kit whose new-setup check fails.
Write-Host ""
Write-Host "== a handed-over run that fails outside every row: the parent names the reason =="
$hoHome = Join-Path $work "handover-home"
$hoSetup = Join-Path $hoHome (Join-Path "kit" "setup")
New-Item -ItemType Directory -Force -Path $hoSetup | Out-Null
$hoCalls = Join-Path $work "handover-run-calls"
$hoReason = "The database could not start: this WSL kernel cannot create the deployment network. Run: wsl --update"
$hoPreamble = @'
. (Join-Path '__REPO__' "setup/lib/exakit-common.ps1") *> $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path '__REPO__' "setup/exakit.ps1"), [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent.Parent -eq $ast }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
. (Join-Path '__REPO__' "setup/lib/core-setup.ps1")
$script:VersionPolicy = "pinned"
function Assert-ExakitInstalled { param([switch]$Json) }
function Initialize-ExakitLogging { }
function Test-ExakitUpdateTarget { param($t) return $true }
function Get-ExakitUpdateTargets { param([string]$Target) return @("exakit") }
function Get-ExakitActualTarget { param($c) return $c }
function Get-ExakitComponentCurrent { param($c) return "1.0" }
function Get-ExakitComponentAvailable { param($c) return "2.0" }
function Test-ExakitComponentSupported { param($c) return $true }
function Test-ExakitComponentAhead { param($c) return $false }
function Test-ExakitComponentHeavy { param($c) return $false }
function Get-ExakitComponentMinKit { param($c) return "" }
function Write-ExakitVersionsSourceLine { }
function Invoke-ExakitWithSpinner { param([string]$Label, [scriptblock]$Body) & $Body }
function Get-ExakitManifestValue { param([string]$Path) if ($Path -eq "kit.version") { return "2.0" }; return $null }

'@
$hoPreamble = $hoPreamble.Replace("__REPO__", $repo)
# The new kit: the handed-over run skips the kit itself, so no component row
# is written before its new-setup check fails.
$hoNew = $hoPreamble + @'
function Invoke-ExakitCoreUpdateCheck { param([string]$Target) Add-Content -LiteralPath '__CALLS__' -Value "new: core-check"; Fail '__REASON__' }
Invoke-CmdUpdate -Target $args[1] -AssumeYes ($args -contains "--yes") -Json ($args -contains "--json")
'@
Set-Content -LiteralPath (Join-Path $hoSetup "exakit.ps1") -Encoding ASCII -Value $hoNew.Replace("__CALLS__", $hoCalls).Replace("__REASON__", $hoReason)
# The old kit: it swaps itself in place, then hands the rest of the run over.
$hoOld = $hoPreamble + @'
function Update-ExakitSelf { param($Advertised, $Installed) Add-Content -LiteralPath '__CALLS__' -Value "old: exakit" }
function Invoke-ExakitCoreUpdateCheck { param([string]$Target) Add-Content -LiteralPath '__CALLS__' -Value "old: core-check"; return $true }
Invoke-CmdUpdate -Target "all" -AssumeYes $false -Json $true
'@
$hoParent = Join-Path $work "handover-parent.ps1"
Set-Content -LiteralPath $hoParent -Encoding ASCII -Value $hoOld.Replace("__CALLS__", $hoCalls)
Remove-Item -Force -LiteralPath $hoCalls -ErrorAction SilentlyContinue
$savedHome = $env:EXAKIT_HOME
$env:EXAKIT_HOME = $hoHome
# A Continue window: on 5.1 a native call with redirected stderr under Stop
# is a terminating error before its output is read.
$eapHo = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$hoOut = (& ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -File $hoParent 2>$null) -join "`n"
$hoCode = $LASTEXITCODE
$ErrorActionPreference = $eapHo
$hoJson = $null
try { $hoJson = $hoOut | ConvertFrom-Json } catch { }
Check "the old kit swapped itself and handed over; the new kit's check ran, the old one's did not" "old: exakit|new: core-check" (@(Get-Content -LiteralPath $hoCalls -ErrorAction SilentlyContinue) -join "|")
Check "...the parent's one object fails, with the kit itself updated" "False|failed|exakit|1" ("$($hoJson.ok)|$($hoJson.status)|$(@($hoJson.updated | ForEach-Object { $_.component }) -join ',')|$hoCode")
Check "...its one failed entry is run-level and carries the new run's reason" ("|" + $hoReason + "|wsl --update") (@($hoJson.failed | ForEach-Object { "$($_.component)|$($_.error)|$($_.remedy)" }) -join ";")
Has "...with the hint that reason calls for" "this WSL kernel cannot create the deployment network" ("" + @($hoJson.failed)[0].remedy_hint)
Check "...and the object's remedy and hint are that entry's" ("wsl --update|" + @($hoJson.failed)[0].remedy_hint) ("$($hoJson.remedy)|$($hoJson.remedy_hint)")
Check "...not the anonymous end of the new run" $false ($hoOut.Contains("did not finish"))

# An older parent never sees that row: every kit before it reads a row only
# when it names a component, so it still answers with its own "did not finish"
# entry. The new kit run straight, for a five-field parent.
$hoRows = Join-Path $work "handover-rows"
Remove-Item -Force -LiteralPath $hoRows -ErrorAction SilentlyContinue
$env:EXAKIT_UPDATE_HANDOVER = "1"
$env:EXAKIT_UPDATE_RESULTS_FILE = $hoRows
Remove-Item Env:\EXAKIT_UPDATE_ROW_FIELDS -ErrorAction SilentlyContinue
& ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -File (Join-Path $hoSetup "exakit.ps1") update all *> $null
$env:EXAKIT_UPDATE_HANDOVER = $null
$env:EXAKIT_UPDATE_RESULTS_FILE = $null
$env:EXAKIT_UPDATE_ROW_FIELDS = $savedRowFields
$env:EXAKIT_HOME = $savedHome
$hoLines = @(Get-Content -LiteralPath $hoRows -ErrorAction SilentlyContinue)
Check "a five-field parent gets the run-level row in five fields, no component" "|failed|||wsl --update" ($hoLines -join ";")
# The reader of kits before this row, verbatim.
$hoOldRead = @($hoLines | Where-Object { $parts = @("$_" -split '\|', 7); $parts.Count -ge 5 -and $parts[0] })
Check "...and an older reader skips it" 0 $hoOldRead.Count

Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 }
exit 0
