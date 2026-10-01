#!/usr/bin/env pwsh
# legacy-crossing-ps.ps1 - behavioural tests for setup/lib/legacy-crossing.ps1,
# the Windows twin of the crossing from a container database onto Exasol
# Personal. tests/legacy-crossing.sh proves the twin EXISTS function for
# function; this file runs it, against a sandboxed kit home, a fault-injection
# engine and a fault-injection exapump, through the same faults the sh suite
# throws at the sh module - and ends by measuring how much of the module it
# walked, with a floor.
#
#   pwsh -NoProfile -File tests/legacy-crossing-ps.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/legacy-crossing-ps.ps1
#
# The stubs are the PowerShell twins in tests/lib/, behind a .cmd wrapper on
# Windows and a #!/bin/sh wrapper elsewhere, so one stub implementation meets
# the module on every host. Their behaviour comes from files in a control
# directory, exactly as for the sh suite.

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}
function Has($label, $needle, $haystack) {
    if (("" + $haystack).Contains($needle)) { Check $label "present" "present" } else { Check $label "present" "MISSING" }
}
function Lacks($label, $needle, $haystack) {
    if (("" + $haystack).Contains($needle)) { Check $label "absent" "PRESENT" } else { Check $label "absent" "absent" }
}

# --- sandbox ----------------------------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-legacy-ps-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
# The exapump profile writer puts its file under the PROFILE home. That is the
# developer's real ~/.exapump unless this is set - and one of these runs writes
# a legacy profile. USERPROFILE outranks HOME in Get-ExakitProfileHome.
$env:USERPROFILE = Join-Path $work "profile"
New-Item -ItemType Directory -Force -Path $env:USERPROFILE, $env:EXAKIT_HOME, $env:EXAKIT_BIN_DIR | Out-Null
Remove-Item Env:EXAKIT_LEGACY_DATA -ErrorAction SilentlyContinue
$env:EXAKIT_ENGINE_PROBE_TIMEOUT = "2"
$onWindows = ($env:OS -like "*Windows*")

# --- the two stubs, once, reached through PATH and EXAKIT_EXAPUMP_BIN ----------
$stub = Join-Path $work "stub"
New-Item -ItemType Directory -Force -Path $stub | Out-Null
Copy-Item (Join-Path $repo "tests/lib/legacy-fault-engine.ps1")  (Join-Path $stub "fault-engine.ps1")
Copy-Item (Join-Path $repo "tests/lib/legacy-fault-exapump.ps1") (Join-Path $stub "fault-exapump.ps1")
function New-StubWrapper([string]$Name, [string]$Target) {
    if ($onWindows) {
        $path = Join-Path $stub "$Name.cmd"
        Set-Content -Path $path -Encoding Ascii -Value @(
            "@echo off",
            "powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$Target`" %*",
            "exit /b %ERRORLEVEL%")
    } else {
        $path = Join-Path $stub $Name
        # THE INTERPRETER AND THE SCRIPT ARE BOTH BAKED IN, so the wrapper needs
        # nothing on PATH but the shell itself. It used to locate its own
        # directory with `dirname "$0"` - an EXTERNAL binary, in /usr/bin - and
        # the PATH filter below drops any directory that holds a container
        # engine. On ubuntu-latest docker lives in /usr/bin, so that filter
        # amputated /usr/bin and took dirname (and every other coreutil) with
        # it. Every stub call then died with
        #     stub/exapump: 2: dirname: not found
        # and the suite reported thirty-odd assertion failures about container
        # states and table lists - none of which were about the module. macOS
        # keeps docker outside /usr/bin, so it was green there and on Windows.
        # The stub directory is known right here; there is nothing to look up.
        $pwsh = (Get-Process -Id $PID).Path
        if (-not $pwsh) { $pwsh = Join-Path $PSHOME "pwsh" }
        if (-not $pwsh -or -not (Test-Path $pwsh)) {
            throw "cannot resolve the running pwsh to build the $Name stub - it would be written unrunnable and every check below would fail for the wrong reason"
        }
        Set-Content -Path $path -Value @(
            "#!/bin/sh",
            "exec `"$pwsh`" -NoProfile -File `"$stub/$Target`" `"`$@`"")
        chmod +x $path
    }
    return $path
}
[void](New-StubWrapper "fakeengine" "fault-engine.ps1")
$env:EXAKIT_EXAPUMP_BIN = New-StubWrapper "exapump" "fault-exapump.ps1"
# A PATH WITH NO REAL CONTAINER ENGINE ON IT. The crossing no longer trusts the
# recorded engine name alone: when that one cannot be run it asks whichever
# engine on this machine actually holds the container, docker before podman. On
# a developer laptop or a CI runner - both of which have a real docker - that
# turned every "the recorded engine is gone" scenario into "some other engine
# answered", and the suite started describing the machine it ran on instead of
# the module. Drop the directories that hold one, keep everything else, so the
# stub below is the only engine reachable.
$_lcEnginePath = @()
foreach ($dir in ($env:PATH -split [IO.Path]::PathSeparator)) {
    if (-not $dir) { continue }
    $hasEngine = $false
    foreach ($exe in @("docker", "podman", "docker.exe", "podman.exe")) {
        if (Test-Path (Join-Path $dir $exe)) { $hasEngine = $true; break }
    }
    if (-not $hasEngine) { $_lcEnginePath += $dir }
}
$env:PATH = (@($stub) + $_lcEnginePath) -join [IO.Path]::PathSeparator

# --- line coverage, by breakpoint --------------------------------------------
# Every line of the module that can hold a statement gets a breakpoint whose
# action records the line. Breakpoints are set BEFORE the module is
# dot-sourced, so the top-level assignments count too. What is excluded is
# what a breakpoint can never fire on: blank and comment lines, a lone brace,
# the `} else {` / `} catch {` / `} finally {` joints, a function header, and
# the continuation lines of a statement split with a backtick, a comma or an
# open parenthesis - which are folded into the line the statement starts on.
$module = (Resolve-Path (Join-Path $repo "setup/lib/legacy-crossing.ps1")).Path
$script:covHits = @{}
$lines = Get-Content $module
$executable = @{}; $groupOf = @{}
$prevContinues = $false; $group = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    $n = $i + 1; $t = $lines[$i].Trim()
    if (-not $prevContinues) { $group = $n }
    $groupOf[$n] = $group
    $exe = $true
    if ($t -eq "" -or $t.StartsWith("#")) { $exe = $false }
    elseif ($prevContinues) { $exe = $false }
    elseif ($t -match '^(\}|\{|\}\s*else\s*\{|else\s*\{|try\s*\{|\}\s*catch\s*\{|\}\s*finally\s*\{)$') { $exe = $false }
    elseif ($t -match '^function\s+[A-Za-z-]+\s*\{$') { $exe = $false }
    elseif ($t -match '^param\(') { $exe = $false }
    if ($exe) { $executable[$n] = $true }
    $prevContinues = ($t -match '(`|,|\()$')
}
$breakpoints = @()
foreach ($n in $executable.Keys) {
    $action = [scriptblock]::Create("`$script:covHits[$n] = 1")
    $breakpoints += Set-PSBreakpoint -Script $module -Line $n -Action $action
}

. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/exapump.ps1")
. $module

# --- scenario plumbing ---------------------------------------------------------
$PASSWORD = "legacysecret-Zq7"
$script:allEngine = @(); $script:allExapump = @(); $script:screens = @()

# Seed - a kit home holding what an OLDER kit recorded. -Type, -NoPassword,
# -EmptyPassword, -NoDsn, -NoContainer, -NoVolume and -Engine shape the record.
function Seed {
    param([string]$Type = "nano", [switch]$NoPassword, [switch]$EmptyPassword, [switch]$NoDsn,
          [switch]$NoContainer, [switch]$NoVolume, [string]$Engine = "fakeengine")
    # The module memoises the engine it resolved, and every scenario here runs
    # in ONE PowerShell process: without this, a record seeded now is still
    # answered by the engine the record before it cached.
    Reset-LegacyEngineCache
    Remove-Item -Recurse -Force $env:EXAKIT_HOME -ErrorAction SilentlyContinue
    $ctrl = Join-Path $env:EXAKIT_HOME "ctrl"
    New-Item -ItemType Directory -Force -Path (Join-Path $env:EXAKIT_HOME "credentials"), $ctrl, $env:EXAKIT_BIN_DIR | Out-Null
    $env:EXAKIT_FAULT_DIR = $ctrl
    $script:LegacyExportDir = Join-Path $env:EXAKIT_HOME "migration"
    $pw = Join-Path $env:EXAKIT_HOME "credentials\nano_sys_password"
    if (-not $NoPassword) {
        if ($EmptyPassword) { Set-Content -Path $pw -Value "" -NoNewline } else { Set-Content -Path $pw -Value $PASSWORD }
    }
    $rt = [ordered]@{ type = $Type; engine = $Engine; user = "sys"; status = "healthy"; image = "docker.io/exasol/nano:2026.2.0-nano.2" }
    if (-not $NoContainer) { $rt.container = "exasol-nano" }
    if (-not $NoVolume)    { $rt.volume = "exasol-nano-data" }
    if (-not $NoDsn)       { $rt.dsn = "127.0.0.1:8563" }
    $rt.password_file = $pw
    $doc = [ordered]@{ manifest_version = 1; kit_level = 1
        kit = [ordered]@{ version = "0.1.0"; source = "exasol-labs/exasol-personal-local-starterkit@0.1.0" }
        runtime = $rt; steps_completed = @("runtime") }
    Set-Content -Path (Join-Path $env:EXAKIT_HOME "manifest.json") -Value ($doc | ConvertTo-Json -Depth 5)
    Set-Content -Path (Join-Path $ctrl "db.tables") -Value "S1.T1`nS1.T2`nS2.T3"
    Set-Content -Path (Join-Path $ctrl "db.columns") -Value "S1.T1|ID<<:>>DECIMAL(18,0)`nS1.T1|NAME<<:>>VARCHAR(25) UTF8`nS1.T2|WHEN_TS<<:>>TIMESTAMP WITH LOCAL TIME ZONE`nS2.T3|my col<<:>>DOUBLE"
    # The module caches nothing between calls, but its result variables do
    # carry over; a scenario starts from zero.
    $script:LegacyChoice = ""; $script:LegacyRestored = 0; $script:LegacySkipped = 0
    $script:LegacySkippedNames = ""; $script:LegacyRestoreFailed = 0
}
function Fault([string]$Name, [string]$Value) { Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR $Name) -Value $Value -NoNewline }
function Calls([string]$Which) {
    $p = Join-Path $env:EXAKIT_FAULT_DIR "$Which.calls"
    if (Test-Path $p) { return @(Get-Content $p) }
    return @()
}
function Verbs { return ((Calls "engine") | ForEach-Object { ($_ -split " ")[0] }) -join " " }
function MGet([string]$Path) { return ("" + (Get-ExakitManifestValue $Path)) }
# Screen - everything a call writes, on any stream, as one string; remembered
# for the invariants at the end.
function Screen([scriptblock]$Body) {
    # -Width, or the capture is folded at the HOST console width and these
    # assertions start matching the terminal rather than the module.
    #
    # It bit once, on the Windows runner only. The "no longer needed" line
    # carries the export directory, and a Windows temp path is long enough
    # (172 characters all told) that the fold landed at column 128 - inside
    # the phrase, splitting it into "no lo" and "nger needed". The module had
    # printed it correctly; the check read MISSING. The line after it passed
    # on the same screen because its phrase sits at column 24, before any
    # fold. Nothing reproduces this under pwsh 7, which does not fold these
    # records at all, so the suite was green everywhere except the one host
    # that matters for a 5.1 test.
    $out = (& $Body *>&1 | Out-String -Width 4096)
    $script:screens += $out
    return $out
}
function Remember {
    $script:allEngine += (Calls "engine"); $script:allExapump += (Calls "exapump")
}
$unattended = [Console]::IsInputRedirected -or -not [Environment]::UserInteractive

# =============================================================================
Write-Host "the record is the whole test:"
Seed
Check "a container runtime recorded is a legacy install" $true (Test-LegacyDbRecorded)
Seed -Type personal
Check "a Personal install is not" $false (Test-LegacyDbRecorded)
Seed -Type ""
Check "no runtime type at all is not" $false (Test-LegacyDbRecorded)

Write-Host ""
Write-Host "the container's state, through the recorded engine:"
Seed;                               Check "running"  "running" (Get-LegacyContainerState)
Fault "engine.state" "stopped";     Check "stopped"  "stopped" (Get-LegacyContainerState)
Fault "engine.state" "absent";      Check "absent"   "absent"  (Get-LegacyContainerState)
Fault "engine.state" "unknown";     Check "unparseable is unknown, never absent" "unknown" (Get-LegacyContainerState)
Seed -Engine "no-such-engine";      Check "an engine that is gone answers unknown" "unknown" (Get-LegacyContainerState)
Check "...and the engine is never asked for" 0 @(Calls "engine").Count
# Docker Desktop stopped: the CLI is there, inspect fails and the server version
# is empty. An engine that will not talk, not a missing container.
Seed; Fault "engine.state" "down";  Check "a stopped engine is unknown, never absent" "unknown" (Get-LegacyContainerState)
Seed -NoContainer;                  Check "no container name reads as absent" "absent" (Get-LegacyContainerState)
Check "...and the removal command has nothing to name" "" (Get-LegacyRemoveCommand)

Write-Host ""
Write-Host "start and stop, and what they change:"
Seed; Fault "engine.state" "stopped"
Check "a stopped container starts" $true (Start-LegacyContainer)
Check "...and then reads as running" "running" (Get-LegacyContainerState)
Check "stop succeeds" $true (Stop-LegacyContainer)
Check "...records itself" "True" (MGet "legacy.container_stopped")
Check "...and a second stop is a no-op, not an error" $true (Stop-LegacyContainer)
Check "exactly one stop was issued" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
Seed; Fault "engine.start_rc" "1"; Fault "engine.state" "stopped"
Check "a start the engine refuses is reported" $false (Start-LegacyContainer)
Seed; Fault "engine.stop_rc" "1"
$s = Screen { $script:stopResult = Stop-LegacyContainer }
Check "a stop the engine refuses is reported" $false $script:stopResult
Has "...and warned about" "may find its port busy" $s

Write-Host ""
Write-Host "the removal command names both things that hold data:"
Seed
$rm = Get-LegacyRemoveCommand
Has "the container" "exasol-nano" $rm
Has "the volume" "exasol-nano-data" $rm
Has "the recorded engine" "fakeengine" $rm
Seed -NoVolume
Lacks "without a recorded volume it invents none" "volume rm" (Get-LegacyRemoveCommand)

Write-Host ""
Write-Host "talking to the old database:"
Seed -NoPassword;   Check "no password file: no profile" $false (Write-LegacyProfile)
Seed -EmptyPassword; Check "an empty password file: no profile" $false (Write-LegacyProfile)
Seed -NoDsn;        Check "no dsn: no profile" $false (Write-LegacyProfile)
Seed
Check "a complete record writes the profile" $true (Write-LegacyProfile)
$cfg = Join-Path $env:USERPROFILE ".exapump\config.toml"
Check "...under the sandboxed profile home" $true (Test-Path $cfg)
Has "...as the LEGACY profile section" "[starter-kit-legacy]" (Get-Content $cfg -Raw)
Has "...pointing at the recorded port" "port = 8563" (Get-Content $cfg -Raw)
Check "the database answers through it" $true (Test-LegacyDbAnswers)
Check "the tables are listed" "S1.T1 S1.T2 S2.T3" ((Get-LegacyTables) -join " ")
Fault "db.answer_after" "never"
Check "a database that never answers says so" $false (Test-LegacyDbAnswers)
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.tables") -Value ""
Check "an empty database lists nothing" 0 @(Get-LegacyTables).Count

Write-Host ""
Write-Host "the DDL keeps the source's types:"
Seed
$ddl = Get-LegacyTableDdl -Schema "S1" -Table "T1"
Check "both identifiers quoted, types carried" 'CREATE TABLE "S1"."T1" ("ID" DECIMAL(18,0), "NAME" VARCHAR(25) UTF8)' $ddl
Has "a multi-word type survives the marker split" '"WHEN_TS" TIMESTAMP WITH LOCAL TIME ZONE' (Get-LegacyTableDdl -Schema "S1" -Table "T2")
Has "a column name with a space is quoted" '"my col" DOUBLE' (Get-LegacyTableDdl -Schema "S2" -Table "T3")
Check "a table with no catalogue yields no DDL" "" (Get-LegacyTableDdl -Schema "S9" -Table "NOPE")

Write-Host ""
Write-Host "copying out tolerates partial failure:"
Seed; Fault "export.fail" "S1.T2"; [void](Write-LegacyProfile)
$dir = $script:LegacyExportDir
$s = Screen { $script:exportResult = Export-LegacyTables -Dir $dir -Tables @("S1.T1", "S1.T2", "S2.T3") }
Check "two of three land, so the copy counts as made" $true $script:exportResult
Has "the failed table is named" "Could not copy S1.T2" $s
Check "exported" "2" (MGet "legacy.exported")
Check "export_failed" "1" (MGet "legacy.export_failed")
$index = Get-Content (Join-Path $dir "index")
Check "two index lines" 2 @($index).Count
Check "the failed table is not indexed" 0 @($index | Where-Object { $_ -match "`tT2`t" }).Count
Check "...and its partial file is gone" $false (Test-Path (Join-Path $dir "t2.csv"))
Check "the files are positional" "t1.csv t3.csv" ((Get-ChildItem $dir -Filter "t*.csv" | Sort-Object Name | ForEach-Object { $_.Name }) -join " ")
Has "the index carries the DDL" 'CREATE TABLE "S1"."T1"' ($index -join "`n")
Seed; Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "export.fail") -Value "S1.T1`nS1.T2`nS2.T3"; [void](Write-LegacyProfile)
$s = Screen { $script:exportResult = Export-LegacyTables -Dir $script:LegacyExportDir -Tables @("S1.T1", "S1.T2", "S2.T3") }
Check "when every table fails, the copy is not made" $false $script:exportResult
Check "...zero exported, three failed" "0/3" ((MGet "legacy.exported") + "/" + (MGet "legacy.export_failed"))
Seed; [void](Write-LegacyProfile)
[void](Export-LegacyTables -Dir $script:LegacyExportDir -Tables @("My Schema.T.with.dots", "nodot"))
$index = Get-Content (Join-Path $script:LegacyExportDir "index")
Has "a schema is split at the FIRST dot" "My Schema`tT.with.dots" ($index -join "`n")
Check "a name with no dot is skipped, not mangled" 1 @($index).Count
Lacks "no parquet is ever asked for" "parquet" ((Calls "exapump") -join "`n")

Write-Host ""
Write-Host "restoring tolerates partial failure and heals what it can:"
Seed; [void](Write-LegacyProfile)
[void](Export-LegacyTables -Dir $script:LegacyExportDir -Tables @("S1.T1", "S1.T2", "S2.T3"))
Fault "import.exists" "S1.T2"; Fault "upload.fail" "S2.T3"
$s = Screen { $script:importResult = Import-LegacyTables -Dir $script:LegacyExportDir }
Check "a mixed restore returns" $true $script:importResult
Check "one restored" 1 $script:LegacyRestored
Check "one left alone" 1 $script:LegacySkipped
Check "...by name" " S1.T2" $script:LegacySkippedNames
Check "one failed" 1 $script:LegacyRestoreFailed
Has "...and named, with its kept copy" "Could not restore S2.T3" $s
Check "no upload for the table left alone" 0 @((Calls "exapump") | Where-Object { $_ -like "upload *" -and $_ -like '*"S1"."T2"*' }).Count
Check "the counts are recorded" "1/1/1" ((MGet "legacy.restored") + "/" + (MGet "legacy.restore_skipped") + "/" + (MGet "legacy.restore_failed"))
Seed; [void](Write-LegacyProfile)
[void](Export-LegacyTables -Dir $script:LegacyExportDir -Tables @("S1.T1", "S1.T2", "S2.T3"))
Remove-Item (Join-Path $script:LegacyExportDir "t2.csv")
Fault "import.schema_rc" "1"
[void](Import-LegacyTables -Dir $script:LegacyExportDir)
Check "a missing file is skipped without a count" "2" (MGet "legacy.restored")
Check "...not as a failure" "" (MGet "legacy.restore_failed")
Check "and a refused CREATE SCHEMA does not stop the restore" 2 $script:LegacyRestored
Add-Content -Path (Join-Path $script:LegacyExportDir "index") -Value "`n`nnot-a-real-line`n"
[void](Import-LegacyTables -Dir $script:LegacyExportDir)
Check "blank and malformed index lines are stepped over" 2 $script:LegacyRestored
Seed
Check "a directory with no index is refused" $false (Import-LegacyTables -Dir (Join-Path $env:EXAKIT_HOME "nowhere"))

Write-Host ""
Write-Host "the answers:"
Seed
$env:EXAKIT_LEGACY_DATA = "migrate"; Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "";  Check "migrate" "migrate" $script:LegacyChoice
$env:EXAKIT_LEGACY_DATA = "yes";     Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "";  Check "yes is migrate" "migrate" $script:LegacyChoice
$env:EXAKIT_LEGACY_DATA = "1";       Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "";  Check "1 is migrate" "migrate" $script:LegacyChoice
$env:EXAKIT_LEGACY_DATA = "skip";    Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "";  Check "skip" "skip" $script:LegacyChoice
$env:EXAKIT_LEGACY_DATA = "no";      Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "";  Check "no is skip" "skip" $script:LegacyChoice
$env:EXAKIT_LEGACY_DATA = "0";       Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "";  Check "0 is skip" "skip" $script:LegacyChoice
$env:EXAKIT_LEGACY_DATA = "migrate"
$s = Screen { Select-LegacyChoice -TableCount 3 -CanMigrate $false -Why "the container is gone" }
Check "a migration that cannot be done is refused" "skip" $script:LegacyChoice
Has "...with the reason" "the container is gone" $s
Remove-Item Env:EXAKIT_LEGACY_DATA
$s = Screen { Select-LegacyChoice -TableCount 3 -CanMigrate $false -Why "no password" }
Check "no answer and no possible copy: skip" "skip" $script:LegacyChoice
Has "...saying why" "no password" $s
if ($unattended) {
    $env:EXAKIT_LEGACY_DATA = "maybe"
    $s = Screen { Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "" }
    Check "a value the kit does not know, off a terminal, is skip" "skip" $script:LegacyChoice
    Has "...with the hint" "EXAKIT_LEGACY_DATA=migrate" $s
    Remove-Item Env:EXAKIT_LEGACY_DATA
} else {
    Check "unattended default (needs redirected stdin)" "skipped" "skipped"
    Check "unattended hint (needs redirected stdin)" "skipped" "skipped"
}

Write-Host ""
Write-Host "the first half, gate by gate:"
Seed -Type personal
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a Personal install: nothing said" "" $s.Trim()
Check "...nothing asked of the engine" 0 @(Calls "engine").Count
Seed; Set-ExakitManifestValue "legacy.crossing_done" $true
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a crossing already done: nothing said" "" $s.Trim()
# NOT "no probe at all" any more, and deliberately so. The container publishes
# the port the new deployment needs, so a crossing that is over must still take
# it out of the way - without that the install died on "port 8563 is in use" on
# every later run. It says nothing while doing it; the engine log is where the
# work shows. The sh twin pins the same behaviour on its own gate.
# One line, and no "\": that is a SHELL continuation, and PowerShell does not
# have it. Written this way the "\" was simply the third argument, so this
# asserted "stop" against a backslash and failed on every run since it landed,
# while the line below it ran as a statement of its own and printed to the
# screen. Backtick is PowerShell's continuation; one line needs neither.
$freedPort = @(Calls "engine") | Where-Object { $_ -like "stop *" } | ForEach-Object { "stop" } | Select-Object -First 1
Check "...but the port is still freed" "stop" $freedPort
Seed; Fault "engine.state" "absent"
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a container that is gone: nothing said" "" $s.Trim()
Check "...but settled for good" "True" (MGet "legacy.crossing_done")
Check "...as skip" "skip" (MGet "legacy.choice")
Seed -Engine "no-such-engine"
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a recorded engine that is gone: nothing said" "" $s.Trim()
# RETRYABLE, NOT SETTLED. An engine that is missing today may be installed
# tomorrow, so this records WHY it could not ask and leaves the crossing open -
# it does not quietly write "skip" over a database it never reached. The sh
# twin pins the same three facts on its own retry branch.
Check "...records why it could not ask" "the container engine this database needs is not on this machine any more" (MGet "legacy.offer_blocked")
Check "...and chooses nothing" "" (MGet "legacy.choice")
Check "...leaving the crossing open for the next run" "" (MGet "legacy.crossing_done")
Seed
$realExapump = $env:EXAKIT_EXAPUMP_BIN; $env:EXAKIT_EXAPUMP_BIN = Join-Path $env:EXAKIT_HOME "no-such-exapump"
$s = Screen { Invoke-LegacyCrossingBefore }
$env:EXAKIT_EXAPUMP_BIN = $realExapump
Check "no exapump: nothing said" "" $s.Trim()
Check "...and no query attempted" 0 @(Calls "exapump").Count
Seed -NoPassword
$s = Screen { Invoke-LegacyCrossingBefore }
Check "no password: nothing said" "" $s.Trim()
Check "...the database never queried" 0 @((Calls "exapump") | Where-Object { $_ -like "*EXAKIT_LEGACY_OK*" }).Count
Check "...and the container stopped for the port" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
Seed; Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.tables") -Value ""
$s = Screen { Invoke-LegacyCrossingBefore }
Check "an empty database: nothing said" "" $s.Trim()
Check "...settled" "True" (MGet "legacy.crossing_done")
Seed; Fault "engine.state" "stopped"; Fault "engine.start_rc" "1"
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a container that will not start: nothing said" "" $s.Trim()
Check "...start attempted once" 1 @((Calls "engine") | Where-Object { $_ -like "start *" }).Count
Seed; Fault "db.answer_after" "never"; Fault "engine.state" "stopped"; $env:EXAKIT_LEGACY_READY_TIMEOUT = "5"
$t0 = Get-Date
$s = Screen { Invoke-LegacyCrossingBefore }
Remove-Item Env:EXAKIT_LEGACY_READY_TIMEOUT
Check "a database that never answers: nothing said" "" $s.Trim()
Check "...within the configured budget" $true (((Get-Date) - $t0).TotalSeconds -lt 20)
Check "...and the container it started is stopped again" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
Seed; Fault "db.answer_after" "2"; $env:EXAKIT_LEGACY_DATA = "migrate"
$s = Screen { Invoke-LegacyCrossingBefore }
$s2 = Screen { Invoke-LegacyCrossingAfter }
Has "a database that answers late is still copied" "Restored 3 table(s)" $s2
Check "...all three tables" "3" (MGet "legacy.exported")
Remove-Item Env:EXAKIT_LEGACY_DATA
Seed; Set-ExakitManifestValue "legacy.choice" "migrate"
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a resumed attempt: nothing said" "" $s.Trim()
Check "...the container it left running is stopped" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
Check "...and nothing is copied twice" 0 @((Calls "exapump") | Where-Object { $_ -like "export *" }).Count
Remember

Write-Host ""
Write-Host "the whole road, end to end:"
# THE QUESTION IS IN THE OTHER HALF, and so is everything that follows from
# it. The first half reads the tables out while the container still holds the
# port and says only what it does to the machine; the banner, the question, and
# the choice it settles belong to the half that runs after exapump, where a
# copy already exists to ask about. The sh twin's "the first half never asks"
# block pins the same split on that side. These checks used to read the whole
# crossing off the first half, which is why every one of them went red the day
# the question moved.
Seed; $env:EXAKIT_LEGACY_DATA = "migrate"
$s = Screen { Invoke-LegacyCrossingBefore }
Check "the first half says only what it is doing to the machine" "" (
    ($s -split "`n" | Where-Object { $_.Trim() -and $_ -notlike "*Stopping the old database container*" }) -join "")
Check "...and settles nothing on its own" "/" ((MGet "legacy.choice") + "/" + (MGet "legacy.crossing_done"))
Check "...but the copy is already made" "3" (MGet "legacy.exported")
Check "crossed_from" "nano" (MGet "legacy.crossed_from")
Check "export_dir" $script:LegacyExportDir (MGet "legacy.export_dir")
Check "container_stopped" "True" (MGet "legacy.container_stopped")
Check "the engine saw inspect, inspect, stop - nothing else" "container container stop" (Verbs)
Check "every export used the LEGACY profile" 3 @((Calls "exapump") | Where-Object { $_ -like "export -p starter-kit-legacy *" }).Count
$s2 = Screen { Invoke-LegacyCrossingAfter }
Has "the banner names the container and the state it left it in" "container 'exasol-nano' (stopped for this install)" $s2
Has "...and the count that is the user's own" "3 table(s) in 2 schema(s) of your own" $s2
Has "...and the CSV caveat" "empty string arrives as NULL" $s2
Check "choice" "migrate" (MGet "legacy.choice")
Check "crossing_done" "True" (MGet "legacy.crossing_done")
Has "the second half restores" "Restored 3 table(s)" $s2
Has "...and declares the copy expendable" "no longer needed" $s2
Has "...naming the original's home" "still holds the original" $s2
Check "every upload used the KIT's profile" 3 @((Calls "exapump") | Where-Object { $_ -like "upload -p starter-kit *" }).Count
Check "restored" "3" (MGet "legacy.restored")
$uploads = @((Calls "exapump") | Where-Object { $_ -like "upload *" }).Count
$s3 = Screen { Invoke-LegacyCrossingAfter }
Check "a second restore is silent" "" $s3.Trim()
Check "...and issues no more uploads" $uploads @((Calls "exapump") | Where-Object { $_ -like "upload *" }).Count
$s4 = Screen { Invoke-LegacyCrossingBefore }
Check "and a later install asks nothing again" "" $s4.Trim()
Remember
Seed; Fault "engine.state" "stopped"; $env:EXAKIT_LEGACY_DATA = "migrate"
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a stopped container is copied too" "3" (MGet "legacy.exported")
Check "...started, then stopped - inspect before each" "container start container stop" (Verbs)
Remember
Seed; $env:EXAKIT_LEGACY_DATA = "skip"
$s = Screen { Invoke-LegacyCrossingBefore }
# THE COPY IS MADE BEFORE THE QUESTION IS ASKED, because it can only be made
# while the old container still holds the port - so "skip" is not "do not
# copy", it is "do not restore". Asserting zero exports here was asserting the
# order the kit deliberately stopped using.
Check "the copy is taken out anyway, while the port is still there" 3 @((Calls "exapump") | Where-Object { $_ -like "export *" }).Count
Check "the container was stopped" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
$s2 = Screen { Invoke-LegacyCrossingAfter }
Has "skip leaves the old database alone, and says so" "left exactly as it was, stopped, with its data" $s2
Has "...naming the command that copies it later" "exakit migrate docker-nano" $s2
Has "...and the removal command" "fakeengine rm -f exasol-nano; fakeengine volume rm exasol-nano-data" $s2
Check "...and nothing is uploaded into the new database" 0 @((Calls "exapump") | Where-Object { $_ -like "upload *" }).Count
Check "...with skip recorded and the crossing closed" "skip/True" ((MGet "legacy.choice") + "/" + (MGet "legacy.crossing_done"))
Remember
Seed; $env:EXAKIT_LEGACY_DATA = "migrate"; Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "export.fail") -Value "S1.T1`nS1.T2`nS2.T3"
$s = Screen { Invoke-LegacyCrossingBefore }
Has "when a table will not copy, that table is named" "Could not copy S1.T1 out of the old database" $s
# RETRYABLE, like the missing engine above: an export that failed today is not
# an answer, so nothing is chosen and the crossing stays open.
Check "...and when none of them copy, it records why" "nothing could be copied out of the old database" (MGet "legacy.offer_blocked")
Check "...chooses nothing" "" (MGet "legacy.choice")
Check "...leaves the crossing open" "" (MGet "legacy.crossing_done")
Check "...leaving no export_dir" "" (MGet "legacy.export_dir")
Remember
Seed; $env:EXAKIT_LEGACY_DATA = "migrate"; Fault "engine.stop_rc" "1"
$s = Screen { Invoke-LegacyCrossingBefore }
Has "a stop the engine refuses is warned about on the migrate road" "may find its port busy" $s
[void](Screen { Invoke-LegacyCrossingAfter })
Check "...and the crossing is still done" "True" (MGet "legacy.crossing_done")
Remember
Seed; $env:EXAKIT_LEGACY_DATA = "migrate"
[void](Screen { Invoke-LegacyCrossingBefore }); Fault "upload.fail" "S2.T3"; Fault "import.exists" "S1.T2"
$s2 = Screen { Invoke-LegacyCrossingAfter }
Has "a mixed restore counts what landed" "Restored 1 table(s)" $s2
Has "...names what it left alone" "Left alone (this install had already created them): S1.T2" $s2
Has "...keeps the copy for the failure" "did not restore" $s2
Lacks "...and does not call it expendable" "no longer needed" $s2
Remember
Remove-Item Env:EXAKIT_LEGACY_DATA

Write-Host ""
Write-Host "the kit's own sample data is left out of the copy:"
# TPCH.REGION with the row count the kit's own CSV has (5) is the bundled
# sample, unchanged, and is not the user's to copy. TPCH.NATION with one row
# fewer than the CSV (24 of 25) has been changed, so it IS the user's. The
# catalog is read from the kit's real data\datasets, so the numbers are the
# kit's, not the suite's.
Seed; $env:EXAKIT_LEGACY_DATA = "migrate"
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.tables") -Value "S1.T1`nTPCH.NATION`nTPCH.REGION"
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.rows") -Value "TPCH.NATION|24`nTPCH.REGION|5"
$s = Screen { Invoke-LegacyCrossingBefore }
$s2 = Screen { Invoke-LegacyCrossingAfter }
Has "the banner counts what is the user's own" "2 table(s) in 2 schema(s) of your own" $s2
Has "...and says the rest is the kit's" "The other 1 is the kit's own tpch sample" $s2
Has "...and that this install loads it itself" "which this install loads itself" $s2
Check "only the user's tables are copied out" 2 @((Calls "exapump") | Where-Object { $_ -like "export *" }).Count
# The export names its table as a quoted query, so that is what the log holds.
Check "the unchanged sample table is not" 0 @((Calls "exapump") | Where-Object { $_ -like "export *" -and $_ -like '*"TPCH"."REGION"*' }).Count
Check "a sample table the user changed is" 1 @((Calls "exapump") | Where-Object { $_ -like "export *" -and $_ -like '*"TPCH"."NATION"*' }).Count
Check "the row counts were asked for once, for the sample schema" 1 @((Calls "exapump") | Where-Object { $_ -like "*EXAKIT_LR*" -and $_ -like "*IN ('TPCH')*" }).Count
Check "the record names the dataset left out" "tpch" (MGet "legacy.sample_left_out")
Check "the crossing remembers the old database" "exasol-nano/fakeengine/127.0.0.1:8563/sys" ((MGet "legacy.container") + "/" + (MGet "legacy.engine") + "/" + (MGet "legacy.dsn") + "/" + (MGet "legacy.user"))
Check "...and its volume" "exasol-nano-data" (MGet "legacy.volume")
# The old kit's "runtime" tick was the container: kept, the deployment step was
# skipped as done and nothing recorded the new runtime (seen on a real machine).
Check "the old kit's step ticks are dropped" 0 @(Get-ExakitManifestValue "steps_completed").Count
Remember
Seed; $env:EXAKIT_LEGACY_DATA = "migrate"
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.tables") -Value "TPCH.REGION`nTPCH.NATION"
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.rows") -Value "TPCH.REGION|5`nTPCH.NATION|25"
$s = Screen { Invoke-LegacyCrossingBefore }
Check "only the kit's sample data: nothing said" "" $s.Trim()
Check "...settled as skip" "skip" (MGet "legacy.choice")
Check "...with the dataset named" "tpch" (MGet "legacy.sample_left_out")
Check "...nothing copied out" 0 @((Calls "exapump") | Where-Object { $_ -like "export *" }).Count
Check "...and the container stopped for the port" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
Remember

Write-Host ""
Write-Host "a sample table the dataset generates is the kit's too:"
# energy's ENERGY_READINGS is built by 02_load_data.sql - 108,000 rows and no
# CSV - so a catalog read from the CSV names alone never saw it. Every upgrade
# from a kit that had loaded the energy dataset was then told it held "1
# table(s) in 1 schema(s) of your own": the kit's own sample data, offered back
# to the user, copied out, restored, and replaced by the dataset load minutes
# later. dataset.conf declares it in markers=.
$cat = @(Get-LegacySampleCatalog)
$gen = @($cat | Where-Object { $_.Table -eq "ENERGY.ENERGY_READINGS" })
Check "the catalog carries the generated table" 1 $gen.Count
Check "...with no row count of its own" "" ("" + $gen[0].Rows)
Check "...while a CSV-backed one keeps its count" "50" ("" + @($cat | Where-Object { $_.Table -eq "ENERGY.ENERGY_METERS" })[0].Rows)
Check "the restore stands aside for it" "True" ("" + (Test-LegacySampleTable -Qualified "ENERGY.ENERGY_READINGS"))
Check "...but not for the user's own" "False" ("" + (Test-LegacySampleTable -Qualified "MYWORK.SALES"))
# The whole of the reported case: a kit that loaded the energy dataset and
# nothing else has nothing of the user's in it, so no offer is made at all.
Seed; $env:EXAKIT_LEGACY_DATA = "migrate"
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.tables") -Value "ENERGY.ENERGY_METERS`nENERGY.ENERGY_READINGS"
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.rows") -Value "ENERGY.ENERGY_METERS|50"
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a kit-only energy database says nothing" "" $s.Trim()
Lacks "...and never calls the sample the user's own" "of your own" $s
Check "...nothing copied out" 0 @((Calls "exapump") | Where-Object { $_ -like "export *" }).Count
Check "...settled as skip" "skip" (MGet "legacy.choice")
Check "...with energy named as the dataset left out" "energy" (MGet "legacy.sample_left_out")
Remember
Seed; $env:EXAKIT_LEGACY_DATA = "migrate"
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.tables") -Value "TPCH.REGION"
$s = Screen { Invoke-LegacyCrossingBefore }
Check "an unknown row count keeps the table in the copy" 1 @((Calls "exapump") | Where-Object { $_ -like "export *" -and $_ -like '*"TPCH"."REGION"*' }).Count
Lacks "...and nothing is called the kit's" "bundled sample data" $s
Remember
Seed; $env:EXAKIT_LEGACY_DATA = "skip"
[void](Screen { Invoke-LegacyCrossingBefore })
$s = Screen { Invoke-LegacyCrossingAfter }
Has "skip names the command that copies it later" "exakit migrate docker-nano" $s
Remember
Remove-Item Env:EXAKIT_LEGACY_DATA

Write-Host ""
Write-Host "after the install: exakit migrate docker-nano (Invoke-LegacyMigrateNow):"
# The Personal runtime is a stub too (tests\lib\legacy-fault-personal.ps1): the
# five functions the migrate road calls, driven by knob files and logging every
# stop, start and wait. Every scenario here is the state AFTER an install: the
# record says the runtime is Personal, and the old container is named through
# the EXAKIT_LEGACY_* variables the CLI would have set.
. (Join-Path $repo "tests/lib/legacy-fault-personal.ps1")
function SeedMig {
    param([switch]$NoPassword, [switch]$NoContainer)
    if ($NoPassword) { Seed -Type personal -NoPassword }
    elseif ($NoContainer) { Seed -Type personal -NoContainer }
    else { Seed -Type personal }
    $env:EXAKIT_LEGACY_CONTAINER = "exasol-nano"; $env:EXAKIT_LEGACY_ENGINE = "fakeengine"
    $env:EXAKIT_LEGACY_DSN = "127.0.0.1:8563"; $env:EXAKIT_LEGACY_VOLUME = "exasol-nano-data"
    $env:EXAKIT_LEGACY_PASSWORD_FILE = Join-Path $env:EXAKIT_HOME "credentials\nano_sys_password"
    Remove-Item Env:EXAKIT_LEGACY_READY_TIMEOUT -ErrorAction SilentlyContinue
}
function Migrate([bool]$Yes = $true) {
    $script:migRc = 1
    $s = Screen { $script:migOut = @(Invoke-LegacyMigrateNow -Yes $Yes) }
    foreach ($item in @($script:migOut)) { if ($item -is [int]) { $script:migRc = $item } }
    return $s
}
function PersonalCalls {
    $p = Join-Path $env:EXAKIT_FAULT_DIR "personal.calls"
    if (Test-Path $p) { return (@(Get-Content $p) -join " ") }
    return ""
}

# THE WHOLE ROAD, with the port clash: both databases on 8563, both running.
SeedMig
$s = Migrate
Check "it finishes" 0 $script:migRc
Check "...as done" "done" $script:LegacyMigrateStatus
Has "the clash is explained before anything happens" "the port your database uses" $s
Check "the database was stopped, started, waited for - in that order" "stop start wait" (PersonalCalls)
Check "the container was stopped after the copy (it holds the port)" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
Check "the engine saw inspect, inspect, stop" "container container stop" (Verbs)
Check "three copied out, three restored" "3/3" ((MGet "legacy.exported") + "/" + (MGet "legacy.restored"))
Check "the copy out came before the restore" $true ($s.IndexOf("Copied 3 table") -lt $s.IndexOf("Restored 3 table"))
Has "the restore report calls the copy expendable" "no longer needed" $s
Check "the record says migrate, done" "migrate/True" ((MGet "legacy.choice") + "/" + (MGet "legacy.crossing_done"))
Check "...and when" $true ((MGet "legacy.migrated_at") -ne "")
Check "every export used the legacy profile" 3 @((Calls "exapump") | Where-Object { $_ -like "export -p starter-kit-legacy *" }).Count
Check "every upload used the kit's profile" 3 @((Calls "exapump") | Where-Object { $_ -like "upload -p starter-kit *" }).Count
Remember

# NO CLASH: another port, so the deployment is never touched and a running
# container is left running.
SeedMig; $env:EXAKIT_LEGACY_DSN = "127.0.0.1:8564"
$s = Migrate
Check "no clash finishes too" 0 $script:migRc
Lacks "...and does not mention the port" "the port your database uses" $s
Check "the deployment is never stopped or started" "" (PersonalCalls)
Check "the running container is left running" 0 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
Has "...the profile points at the named port" "port = 8564" (Get-Content $cfg -Raw)
Remember
SeedMig; $env:EXAKIT_LEGACY_DSN = "127.0.0.1:8564"; Fault "engine.state" "stopped"
$s = Migrate
Check "a stopped container is started, copied, stopped" "container start container stop" (Verbs)
Has "...and the start is announced" "Starting the container" $s
Check "...with the deployment left alone" "" (PersonalCalls)
Remember

# DECLINED. Nothing has happened yet at the question, so nothing is undone.
SeedMig
function Confirm-ExakitPrompt { param([string]$Question, [bool]$DefaultYes = $true) return $false }
$s = Migrate $false
Check "declining returns 5" 5 $script:migRc
Check "...as declined" "declined" $script:LegacyMigrateStatus
Has "...saying nothing changed" "Nothing was changed" $s
Check "the deployment was not touched" "" (PersonalCalls)
Check "no exapump call at all" 0 @(Calls "exapump").Count
Remove-Item Function:Confirm-ExakitPrompt
Remember

# THE THINGS THAT CANNOT WORK, each named for what it is.
SeedMig; Fault "engine.state" "absent"
$s = Migrate
Check "a container that is not there" 1 $script:migRc
Has "...is named, with how to find the right one" "no container named 'exasol-nano' in fakeengine" $s
SeedMig; Fault "engine.state" "unknown"
$s = Migrate
Has "an engine that will not answer is asked about" "did not answer about the container" $s
SeedMig; $env:EXAKIT_LEGACY_ENGINE = "no-such-engine"
$s = Migrate
Check "an engine that is gone" 1 $script:migRc
Has "...is named" "engine 'no-such-engine' is not on this machine" $s
# No name anywhere: not on the command line, not in the record either.
SeedMig -NoContainer; $env:EXAKIT_LEGACY_CONTAINER = ""
$s = Migrate
Has "no container name at all asks for one" "--container <name>" $s
SeedMig
$realExapump = $env:EXAKIT_EXAPUMP_BIN; $env:EXAKIT_EXAPUMP_BIN = Join-Path $env:EXAKIT_HOME "no-such-exapump"
$s = Migrate
$env:EXAKIT_EXAPUMP_BIN = $realExapump
Has "no exapump names the repair" "exapump is not installed" $s
Check "...and returns 1" 1 $script:migRc
Remember

# NO PASSWORD, on the clash road: the deployment comes back before the failure.
SeedMig -NoPassword; Remove-Item Env:EXAKIT_LEGACY_PASSWORD_FILE
$s = Migrate
Check "no password fails" 1 $script:migRc
Has "...naming the two ways to give one" "--password-file" $s
Check "...but the deployment is back up" "stop start wait" (PersonalCalls)
Check "...and the container stopped for the port" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
Lacks "...and nothing was copied" "Copied" $s
Remember

# A DATABASE THAT NEVER ANSWERS, within the budget.
SeedMig; Fault "db.answer_after" "never"; Fault "engine.state" "stopped"; $env:EXAKIT_LEGACY_READY_TIMEOUT = "5"
$s = Migrate
Remove-Item Env:EXAKIT_LEGACY_READY_TIMEOUT
Check "a silent database fails" 1 $script:migRc
Has "...within the budget it names" "did not answer within 5s" $s
Check "...the container it started is stopped again" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
Remember

# A CONTAINER THAT WILL NOT START, and a DEPLOYMENT THAT WILL NOT STOP.
SeedMig; Fault "engine.state" "stopped"; Fault "engine.start_rc" "1"
$s = Migrate
Check "a container that will not start fails" 1 $script:migRc
Has "...pointing at its logs" "fakeengine logs exasol-nano" $s
Check "...and the deployment is started again" "stop start" (PersonalCalls)
# A PORT STILL HELD AFTER THE STOP: named for what it is, the deployment
# started again, the container never blamed.
SeedMig; Fault "personal.port_busy" "1"
$s = Migrate
Check "a port still held after the stop fails" 1 $script:migRc
Has "...naming the port" "port 8563 is still held" $s
Lacks "...and not the container" "would not start" $s
Check "...and the deployment is started again" "stop start" (PersonalCalls)
Check "...with the container never started" 0 @((Calls "engine") | Where-Object { $_ -like "start *" }).Count
Remember
SeedMig; Fault "personal.stop_rc" "1"
$s = Migrate
Check "a deployment that will not stop fails first" 1 $script:migRc
Has "...with the remedy" "exakit stop, then exakit migrate docker-nano" $s
Remember

# ONLY THE KIT'S SAMPLE DATA, and an EMPTY DATABASE: nothing to copy, not a failure.
SeedMig
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.tables") -Value "TPCH.REGION"
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.rows") -Value "TPCH.REGION|5"
$s = Migrate
Check "nothing of the user's is not a failure" 0 $script:migRc
Check "...its own status" "nothing" $script:LegacyMigrateStatus
Has "...and says what the container held" "all of them the kit's bundled sample data (tpch)" $s
Check "no export" 0 @((Calls "exapump") | Where-Object { $_ -like "export *" }).Count
Check "the deployment is back" "stop start wait" (PersonalCalls)
SeedMig; Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.tables") -Value ""
$s = Migrate
Has "an empty database: nothing to copy" "no tables in it" $s
Check "...status nothing" "nothing" $script:LegacyMigrateStatus
Remember

# A MIXED CONTAINER: the sample left out, the rest copied.
SeedMig
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.tables") -Value "S1.T1`nTPCH.REGION`nTPCH.NATION"
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.rows") -Value "TPCH.REGION|5`nTPCH.NATION|1"
$s = Migrate
Has "the count names the whole container" "The container holds 3 table(s)" $s
Has "...and the kit's share" "1 of them belong to the kit's bundled sample data (tpch)" $s
Check "two copied out" "2" (MGet "legacy.exported")
Remember

# EVERY EXPORT FAILS; a PARTIAL RESTORE; a DEPLOYMENT THAT DOES NOT COME BACK.
SeedMig; Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "export.fail") -Value "S1.T1`nS1.T2`nS2.T3"
$s = Migrate
Check "a copy that copies nothing fails" 1 $script:migRc
Has "...saying nothing is lost" "nothing is lost" $s
Check "...with the deployment back up" "stop start wait" (PersonalCalls)
Remember
SeedMig; Fault "upload.fail" "S2.T3"; Fault "import.exists" "S1.T2"
$s = Migrate
Check "a partial restore returns 1" 1 $script:migRc
Check "...as partial" "partial" $script:LegacyMigrateStatus
Has "one left alone, for the new database's reason" "Left alone (the new database already had them): S1.T2" $s
Lacks "...and the copy is not called expendable" "no longer needed" $s
Remember
SeedMig; Fault "personal.start_rc" "1"
$s = Migrate
Check "a deployment that does not come back fails" 1 $script:migRc
Has "...keeping the copy" "not restored yet" $s
Check "three copied out, none restored" "3/" ((MGet "legacy.exported") + "/" + (MGet "legacy.restored"))
# ...and the WAITING COPY from that run is restored first on the next.
Fault "personal.start_rc" "0"
$s = Migrate
Check "the waiting copy is restored" 0 $script:migRc
Has "...and said to be" "waiting at" $s
Check "three restored now" "3" (MGet "legacy.restored")
Check "no second export" 3 @((Calls "exapump") | Where-Object { $_ -like "export *" }).Count
Remember

# THE NEW DATABASE DOES NOT ANSWER at restore time: nothing is counted, the
# copy is kept, the record does not say restored.
SeedMig; Fault "newdb.answers" "no"
$s = Migrate
Check "an unreachable new database fails the restore" 1 $script:migRc
Has "...keeping the copy" "could not be restored. The copy is kept" $s
Lacks "...and nothing is called left alone" "Left alone" $s
Check "...no upload was attempted" 0 @((Calls "exapump") | Where-Object { $_ -like "upload *" }).Count
Check "...and the record does not say restored" "" (MGet "legacy.restored")
Remember

# A SECOND, FRESH COPY after a complete one clears the spent files first.
SeedMig
[void](Migrate)
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.tables") -Value "S1.T1"
$s = Migrate
Check "second run done" "done" $script:LegacyMigrateStatus
Check "...restoring the one table now there" "1" (MGet "legacy.restored")
Check "...with the earlier copy's tail gone" "t1.csv" ((Get-ChildItem $script:LegacyExportDir -Filter "t*.csv" | ForEach-Object { $_.Name }) -join " ")
Remember
foreach ($n in @("EXAKIT_LEGACY_CONTAINER", "EXAKIT_LEGACY_ENGINE", "EXAKIT_LEGACY_DSN", "EXAKIT_LEGACY_VOLUME", "EXAKIT_LEGACY_PASSWORD_FILE")) {
    Remove-Item "Env:$n" -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "invariants that held across every scenario above:"
Check "the engine was used" $true ($script:allEngine.Count -gt 0)
Check "exapump was used" $true ($script:allExapump.Count -gt 0)
Check "no engine call ever removed anything" 0 @($script:allEngine | Where-Object { $_ -match '^(rm|container rm|volume|destroy|kill|prune)' }).Count
# `version` is the one read of the engine itself rather than of the container:
# it is how a stopped daemon is told apart from a missing container.
Check "only inspect, version, start and stop were issued" "" (@($script:allEngine | ForEach-Object { ($_ -split " ")[0] } | Where-Object { $_ -notin @("container", "version", "start", "stop") } | Sort-Object -Unique) -join " ")
Check "the password never reached the screen" 0 @($script:screens | Where-Object { $_.Contains($PASSWORD) }).Count
Check "...nor any process the crossing ran" 0 @(($script:allEngine + $script:allExapump) | Where-Object { $_.Contains($PASSWORD) }).Count
Check "...and it did land in the sandboxed profile" $true ((Get-Content $cfg -Raw).Contains($PASSWORD))
# The one SELECT the kit's profile does carry is the probe of the NEW database
# before a restore (EXAKIT_NEW_OK) - a read of the new one, by design.
Check "no read of the old database used the kit's profile" 0 @($script:allExapump | Where-Object { $_ -match '^(export|sql) -p starter-kit ' -and $_ -notmatch 'CREATE|upload|EXAKIT_NEW_OK' }).Count
Check "no upload used the legacy profile" 0 @($script:allExapump | Where-Object { $_ -like "upload -p starter-kit-legacy *" }).Count

# --- coverage ------------------------------------------------------------------
foreach ($bp in $breakpoints) { Remove-PSBreakpoint $bp }
$hitGroups = @{}
foreach ($n in $script:covHits.Keys) { $hitGroups[$groupOf[[int]$n]] = 1 }
$total = @($executable.Keys).Count
$covered = @($executable.Keys | Where-Object { $hitGroups.ContainsKey($groupOf[$_]) }).Count
$pct = [int][math]::Floor($covered * 100 / [math]::Max($total, 1))
Write-Host ""
Write-Host "coverage of legacy-crossing.ps1: $covered of $total executable lines ($pct%), floor 85%"
$missed = @($executable.Keys | Where-Object { -not $hitGroups.ContainsKey($groupOf[$_]) } | Sort-Object)
if ($missed.Count -gt 0) {
    Write-Host "never reached:"
    foreach ($n in $missed) { Write-Host ("  {0,4}  {1}" -f $n, $lines[$n - 1].Trim()) }
}
Check "coverage floor held" $true ($pct -ge 85)

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "passed: $($script:PASS), failed: $($script:FAIL)"
if ($script:FAIL -gt 0) { exit 1 }
