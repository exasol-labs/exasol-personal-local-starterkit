# legacy-crossing.ps1 - moving an installation made by an OLDER kit onto this one.
#
# Twin of setup/lib/legacy-crossing.sh. Read that file's header for the whole
# rationale; the short version is that older kits (this one before the
# container runtime was removed, and the upstream
# exasol-labs/exasol-personal-local-starterkit) could deploy the database as a
# CONTAINER, and this kit deploys Exasol Personal and nothing else. An
# installation whose manifest records a container database therefore has a
# database that nothing in this tree can drive.
#
# This module is the ONE place that touches such an installation, through the
# manifest the old kit wrote and three engine verbs - inspect, start, stop. It
# does not reintroduce a runtime and it cannot deploy a container.
#
# THE ORDER IS FORCED BY THE PORT: the old container is listening on the port
# the new deployment wants, so it is stopped before the deploy on BOTH answers,
# and the data can only be read while it is still up. Hence two halves:
#
#   Invoke-LegacyCrossingBefore   ask, export, stop        (before step 1)
#   ... the install runs ...
#   Invoke-LegacyCrossingAfter    restore                  (after the kit steps)
#
# WHAT IS NEVER DONE: the old container and its data volume are not deleted, on
# either answer. The container is left stopped, named on screen, with the one
# command that removes it.
#
# AFTER THE INSTALL there is one more road, `exakit migrate docker-nano`
# (Invoke-LegacyMigrateNow, at the end of this file): the same copy in one
# sitting, for someone who answered "skip" and changed their mind, or whose
# container the installer never saw. On BOTH roads the kit's own bundled sample
# data is left out of the copy: the install loads it itself, and `exakit
# data-load` puts it back any time.

# Under the kit home rather than %TEMP%: it holds the user's data and has to
# survive a reboot between the two halves of a resumed install.
$script:LegacyExportDir = if ($env:EXAKIT_LEGACY_EXPORT_DIR) { $env:EXAKIT_LEGACY_EXPORT_DIR } else { Join-Path $script:ExakitHome "migration" }

# A SECOND exapump profile, not a rewrite of the kit's own: the kit's profile
# has to keep pointing at the new database throughout, and a password belongs
# in a 0600 config file rather than in argv where the process list can read it.
$script:LegacyProfile = if ($env:EXAKIT_LEGACY_PROFILE) { $env:EXAKIT_LEGACY_PROFILE } else { "starter-kit-legacy" }

# Exasol's own schemas. Everything else is the user's, including the kit's
# STARTER_KIT - a user who loaded their own tables into it means them when they
# say "my data".
$script:LegacySystemSchemas = "'SYS','EXA_STATISTICS'"

$script:LegacyChoice = ""
$script:LegacyRestored = 0
$script:LegacySkipped = 0
$script:LegacySkippedNames = ""
$script:LegacyRestoreFailed = 0
$script:LegacyExported = 0
$script:LegacyOwnTables = @()
$script:LegacySampleTables = @()
$script:LegacySampleIds = ""
# A password typed at the migrate command's prompt. A script variable, not an
# environment variable: nothing the kit starts inherits it.
$script:LegacyPassword = ""
$script:LegacyMigrateStatus = ""
$script:LegacyMigrateReason = ""
$script:LegacyMigrateRemedy = ""

# --- what the old install recorded, or what the command line names -----------
#
# Every accessor answers from an EXAKIT_LEGACY_* variable first and from the
# manifest second. The install-time crossing sets none of them and reads the
# record an older kit wrote under runtime.*. `exakit migrate docker-nano` runs
# AFTER an install, when runtime.* describes the new deployment and says nothing
# about the old container - so the CLI fills these from its options, or from the
# copy of the old record the crossing keeps under legacy.* (Save-LegacyRecord).

# Whether this machine has an installation whose database is a container. The
# predicate itself lives in exakit-common.ps1 so the CLI can ask the same
# question from the same place.
function Test-LegacyDbRecorded { return (Test-ExakitLegacyRuntimeRecorded) }

# Get-LegacyRecordValue <key> - the old container's container/volume/engine:
# the copy under legacy.* first, runtime.* only when none was kept.
#
# runtime.* describes the OLD database only until the new one is recorded:
# Set-PersonalManifest then drops these keys, so status stops calling a
# Podman-run Exasol Personal "personal (docker)". Save-LegacyRecord copies
# them under legacy.* before that, and the restore after the deployment reads
# them from there. Twin of legacy_record_value.
function Get-LegacyRecordValue {
    param([Parameter(Mandatory)][string]$Key)
    $v = "" + (Get-ExakitManifestValue "legacy.$Key")
    if ($v) { return $v }
    return "" + (Get-ExakitManifestValue "runtime.$Key")
}

function Get-LegacyContainer {
    if ($env:EXAKIT_LEGACY_CONTAINER) { return "" + $env:EXAKIT_LEGACY_CONTAINER }
    return (Get-LegacyRecordValue "container")
}
function Get-LegacyVolume {
    if ($env:EXAKIT_LEGACY_VOLUME) { return "" + $env:EXAKIT_LEGACY_VOLUME }
    return (Get-LegacyRecordValue "volume")
}
function Get-LegacyDsn {
    if ($env:EXAKIT_LEGACY_DSN) { return "" + $env:EXAKIT_LEGACY_DSN }
    return "" + (Get-ExakitManifestValue "runtime.dsn")
}

function Get-LegacyUser {
    $u = "" + $env:EXAKIT_LEGACY_USER
    if (-not $u) { $u = "" + (Get-ExakitManifestValue "runtime.user") }
    if (-not $u) { return "sys" }
    return $u
}

function Get-LegacyPasswordFile {
    if ($env:EXAKIT_LEGACY_PASSWORD_FILE) { return "" + $env:EXAKIT_LEGACY_PASSWORD_FILE }
    return "" + (Get-ExakitManifestValue "runtime.password_file")
}

# The engine's NAME (docker, podman), from the option or the record, never
# re-detected: this is about the engine holding this particular container, and
# a machine can have another one installed.
function Get-LegacyEngineName {
    if ($env:EXAKIT_LEGACY_ENGINE) { return "" + $env:EXAKIT_LEGACY_ENGINE }
    # The engine actually resolved, so the record and every message name the one
    # the container is really in. Only when nothing resolves does the recorded
    # name stand on its own, so a message can still say what is missing.
    $path = Get-LegacyEngine
    if ($path) { return [System.IO.Path]::GetFileNameWithoutExtension($path) }
    return (Get-LegacyRecordValue "engine")
}

# Get-LegacyEngine - the engine that can actually reach this database, as a
# runnable path, or "".
#
# THE RECORDED NAME IS A HINT, NOT THE ANSWER. The old kit ran the container
# under Docker when it was there and Podman otherwise, and it wrote whichever it
# used into runtime.engine. A machine where that key is missing (an older
# record), or where the user has since moved from one engine to the other, then
# had its container declared unreachable - "the container engine this database
# needs is not on this machine any more" - with the container sitting right
# there in the other engine, and the install went on to hit the port it holds.
# So: the recorded engine first, and if that cannot be run, whichever engine on
# this machine actually holds the recorded container. Docker before Podman, the
# order the old kit preferred. Probed once per run; each probe is a process
# start. Twin of legacy_engine.
$script:LegacyEnginePath = $null

# Reset-LegacyEngineCache - forget the resolved engine.
#
# The memo below is right for a real run: one process, one manifest, and each
# probe is a process start worth avoiding. It is wrong the moment the manifest
# it was resolved FROM is replaced underneath it, which is exactly what a test
# harness does - every scenario seeds a new record in the SAME PowerShell
# process. Without this, a scenario that removes the engine from the record was
# still answered by the engine the previous scenario had cached: the container
# read "running" through a launcher the test had just taken away, and every
# assertion after it fell over in turn.
#
# The shell twin needs no such call at the moment because each of its scenarios
# runs in its own subshell, where the memo cannot outlive the record. It has one
# anyway, so the two halves stay the same shape and a future in-process caller
# on either side has the same escape.
function Reset-LegacyEngineCache {
    $script:LegacyEnginePath = $null
}

function Get-LegacyEngine {
    if ($env:EXAKIT_LEGACY_ENGINE) {
        $cmd = Get-Command $env:EXAKIT_LEGACY_ENGINE -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        return ""
    }
    if ($null -ne $script:LegacyEnginePath) { return $script:LegacyEnginePath }
    $path = ""
    $recorded = Get-LegacyRecordValue "engine"
    if ($recorded) {
        $cmd = Get-Command $recorded -ErrorAction SilentlyContinue
        if ($cmd) { $path = $cmd.Source }
    }
    if (-not $path) {
        $container = Get-LegacyContainer
        if ($container) {
            $timeout = 20
            if ($env:EXAKIT_ENGINE_PROBE_TIMEOUT) { $timeout = [int]$env:EXAKIT_ENGINE_PROBE_TIMEOUT }
            foreach ($try in @("docker", "podman")) {
                $cmd = Get-Command $try -ErrorAction SilentlyContinue
                if (-not $cmd) { continue }
                # -f {{.Id}}: a container that is not there prints nothing on
                # stdout, which is the only stream this reads back.
                $out = Invoke-ExakitBounded -FilePath $cmd.Source -TimeoutSeconds $timeout `
                    -Arguments @("container", "inspect", "-f", "{{.Id}}", $container)
                if ($null -ne $out -and "$out".Trim()) { $path = $cmd.Source; break }
            }
        }
    }
    $script:LegacyEnginePath = $path
    return $path
}

# Clear-LegacyEngine - drop the cached answer, for the tests that change what is
# on PATH between scenarios. Twin of legacy_forget_engine.
function Clear-LegacyEngine {
    $script:LegacyEnginePath = $null
}

# Save-LegacyRecord - the old record, copied under legacy.* before the install
# overwrites runtime.* with the new deployment. `exakit migrate docker-nano`
# reads it back, so a "skip" answered today needs no options when it is
# reversed next month, and `exakit status` reads it to say the old database is
# still there. Twin of legacy_remember_record.
function Save-LegacyRecord {
    $v = Get-LegacyContainer;    if ($v) { Set-ExakitManifestValue "legacy.container" $v }
    $v = Get-LegacyEngineName;   if ($v) { Set-ExakitManifestValue "legacy.engine" $v }
    $v = Get-LegacyVolume;       if ($v) { Set-ExakitManifestValue "legacy.volume" $v }
    $v = Get-LegacyDsn;          if ($v) { Set-ExakitManifestValue "legacy.dsn" $v }
    $v = Get-LegacyPasswordFile; if ($v) { Set-ExakitManifestValue "legacy.password_file" $v }
    Set-ExakitManifestValue "legacy.user" (Get-LegacyUser)
}

# One bounded engine call. Bounded for the reason every engine probe here is:
# an engine that is still starting does not answer, and the crossing must not
# hang an install behind it.
function Invoke-LegacyEngine {
    param([string[]]$Arguments)
    $bin = Get-LegacyEngine
    if (-not $bin) { return $null }
    $timeout = 20
    if ($env:EXAKIT_ENGINE_PROBE_TIMEOUT) { $timeout = [int]$env:EXAKIT_ENGINE_PROBE_TIMEOUT }
    return (Invoke-ExakitBounded -FilePath $bin -Arguments $Arguments -TimeoutSeconds $timeout)
}

# Test-LegacyEngineAnswers - is the engine's daemon/machine up, not just its
# CLI? The server version is empty when Docker Desktop or the Podman machine is
# stopped. Twin of legacy_engine_answers.
function Test-LegacyEngineAnswers {
    $out = Invoke-LegacyEngine -Arguments @("version", "--format", "{{.Server.Version}}")
    return ($null -ne $out -and "$out".Trim() -ne "")
}

# running | stopped | absent | unknown. "unknown" is its own answer: an engine
# that will not talk is not evidence that the user's database is gone.
function Get-LegacyContainerState {
    $name = Get-LegacyContainer
    if (-not $name) { return "absent" }
    if (-not (Get-LegacyEngine)) { return "unknown" }
    $out = Invoke-LegacyEngine -Arguments @("container", "inspect", "-f", "{{.State.Running}}", $name)
    if ($null -eq $out -or "$out".Trim() -eq "") {
        $exists = Invoke-LegacyEngine -Arguments @("container", "inspect", $name)
        if ($null -eq $exists -or "$exists".Trim() -eq "") {
            # SILENCE IS NOT ABSENCE. With Docker Desktop stopped the CLI is
            # still on PATH and every inspect prints nothing - which read as
            # "the container is gone", so the install never offered the copy and
            # migrate said there was no such container, with it sitting in the
            # stopped engine. Only an engine that answers can say it is absent.
            if (-not (Test-LegacyEngineAnswers)) { return "unknown" }
            return "absent"
        }
        return "unknown"
    }
    if ("$out" -match "true")  { return "running" }
    if ("$out" -match "false") { return "stopped" }
    return "unknown"
}

function Start-LegacyContainer {
    $name = Get-LegacyContainer
    if (-not $name) { return $false }
    $out = Invoke-LegacyEngine -Arguments @("start", $name)
    # Started is not ready. The readiness probe is a real query, below.
    return ($null -ne $out)
}

# The one mutation the crossing makes to the old install, and it is reversible:
# the container is stopped, never removed, and its data volume is not touched.
#
# -Quiet is the twin of the sh side's `>/dev/null 2>&1` on the two calls that
# happen where NOTHING may reach the screen: a resumed attempt, and a gate that
# closed with no offer to make. Without it the Windows crossing said "Stopping
# the old database container ..." on exactly the re-runs that are supposed to
# pass in silence - the sh side never did, and the two had drifted.
function Stop-LegacyContainer {
    param([switch]$Quiet)
    $name = Get-LegacyContainer
    if (-not $name) { return $true }
    if ((Get-LegacyContainerState) -ne "running") { return $true }
    if (-not $Quiet) { Info "Stopping the old database container ($name) so the new deployment can take the port" }
    $out = Invoke-LegacyEngine -Arguments @("stop", $name)
    if ($null -eq $out) {
        if (-not $Quiet) { Warn2 "Could not stop the container $name - the new deployment may find its port busy" }
        return $false
    }
    Set-ExakitManifestValue "legacy.container_stopped" $true
    return $true
}

# The step ticks an older kit recorded, dropped, so this kit's steps all run.
# The launcher step is not among them: no older kit had one.
function Clear-LegacyOldSteps {
    if (-not (Get-Command Remove-ExakitStepDone -ErrorAction SilentlyContinue)) { return }
    foreach ($step in @("runtime", "exapump", "mcp", "pyexasol", "exakit_helper")) {
        try { Remove-ExakitStepDone $step } catch { }
    }
}

# The exact command that removes the old container and its data, printed for
# the user and never run by the kit.
function Get-LegacyRemoveCommand {
    $engine = Get-LegacyEngineName
    if (-not $engine) { $engine = "podman" }
    $c = Get-LegacyContainer
    $v = Get-LegacyVolume
    if (-not $c) { return "" }
    if ($v) { return "$engine rm -f $c; $engine volume rm $v" }
    return "$engine rm -f $c"
}

# --- talking to the old database --------------------------------------------

# The exapump profile for the OLD database, from what the old install recorded.
# $false when the password is not on file, which is the honest case for a
# deployment the old kit adopted rather than created.
function Write-LegacyProfile {
    $dsn = Get-LegacyDsn
    if (-not $dsn) { return $false }
    $parts = $dsn -split ":", 2
    if ($parts.Count -lt 2) { return $false }
    # The password: typed at the migrate command's prompt ($script:LegacyPassword),
    # given to a scripted run (EXAKIT_LEGACY_PASSWORD), or on file. Never on a
    # command line.
    $password = "" + $script:LegacyPassword
    if (-not $password) { $password = "" + $env:EXAKIT_LEGACY_PASSWORD }
    if (-not $password) {
        $pwFile = Get-LegacyPasswordFile
        if (-not $pwFile -or -not (Test-Path $pwFile)) { return $false }
        # "" + ..., because Get-Content -Raw on an EMPTY file returns $null, and
        # .TrimEnd() on $null is a terminating error - which, under the global
        # Stop preference, would have ended the install on a 0-byte password
        # file. The sh twin tests -s for the same case; here the empty string
        # falls to the test below and the profile is simply not written.
        $password = ("" + (Get-Content $pwFile -Raw)).TrimEnd("`r", "`n")
    }
    if (-not $password) { return $false }
    New-Item -ItemType Directory -Force -Path (Split-Path $script:ExapumpConfigPath -Parent) | Out-Null
    # The password goes straight into the 0600 config. It is never echoed,
    # logged, or passed on a command line.
    Set-ExapumpTomlSection -ConfigPath $script:ExapumpConfigPath -Profile $script:LegacyProfile `
        -Host_ $parts[0] -Port $parts[1] -User (Get-LegacyUser) -Password $password
    Protect-ExakitFile $script:ExapumpConfigPath
    return $true
}

# Invoke-LegacyQuery <sql> - one read from the OLD database, as text.
#
# INSIDE A CONTINUE WINDOW, and that is not a formality: every entry point sets
# $ErrorActionPreference = "Stop" globally, and under Stop a native command
# that writes to stderr becomes a TERMINATING error on Windows PowerShell 5.1 -
# before the exit code can be read. exapump writes progress to stderr while
# succeeding, so without this every one of these probes would throw instead of
# answering. Same guard Get-ExakitProbedVersion carries, for the same reason.
function Invoke-LegacyQuery {
    param([Parameter(Mandatory)][string]$Sql, [string]$Profile = "")
    if (-not $Profile) { $Profile = $script:LegacyProfile }
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = & (Get-ExapumpCli) sql -p $Profile $Sql 2>$null
        return ("" + ($out -join "`n"))
    } catch {
        return ""
    } finally {
        $ErrorActionPreference = $previous
    }
}

# A real query against the old database through its own profile. The readiness
# signal for everything below.
function Test-LegacyDbAnswers {
    return ((Invoke-LegacyQuery -Sql "SELECT 'EXAKIT_LEGACY_OK' AS P") -match "EXAKIT_LEGACY_OK")
}

# Poll the old database until it answers or the budget is spent, in five-second
# steps with the first ask immediate. Twin of legacy_wait_db_answers.
function Wait-LegacyDbAnswers {
    param([int]$Budget)
    $waited = 0
    while (-not (Test-LegacyDbAnswers) -and $waited -lt $Budget) {
        Start-Sleep -Seconds 5
        $waited += 5
    }
    return (Test-LegacyDbAnswers)
}

# SCHEMA.TABLE for every non-system table. The sentinel wrapper is the pattern
# Get-ExapumpCount uses, for the same reason: the echoed query literal must not
# be mistaken for a result row, and after "EXAKIT_LT[" the literal has a quote
# where a result has a name.
function Get-LegacyTables {
    $sql = "SELECT 'EXAKIT_LT[' || TABLE_SCHEMA || '.' || TABLE_NAME || ']' AS T FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA NOT IN ($($script:LegacySystemSchemas)) ORDER BY TABLE_SCHEMA, TABLE_NAME"
    $out = Invoke-LegacyQuery -Sql $sql
    $found = @()
    foreach ($m in [regex]::Matches($out, 'EXAKIT_LT\[([^\]]*)\]')) {
        $found += $m.Groups[1].Value
    }
    return $found
}

# CREATE TABLE for the target, built from the SOURCE column types.
#
# THIS IS WHY THE ROUND TRIP KEEPS ITS TYPES. `exapump upload` into a table that
# does not exist INFERS the schema from the CSV, and inference turns a
# DECIMAL(12,4) into whatever the sample looks like. Creating the table with the
# original types first means the upload only has to parse into them.
function Get-LegacyTableDdl {
    param([string]$Schema, [string]$Table)
    $sql = "SELECT 'EXAKIT_LC[' || COLUMN_NAME || '<<:>>' || COLUMN_TYPE || ']' AS C FROM EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA = '$Schema' AND COLUMN_TABLE = '$Table' ORDER BY COLUMN_ORDINAL_POSITION"
    $out = Invoke-LegacyQuery -Sql $sql
    $cols = @()
    foreach ($m in [regex]::Matches($out, 'EXAKIT_LC\[([^\]]*)\]')) {
        $spec = $m.Groups[1].Value
        # SPLIT ON THE MARKER, NOT ON WHITESPACE. A column name may contain a
        # space ("my col") and so may a type ("TIMESTAMP WITH LOCAL TIME
        # ZONE"), so neither end can be found from the first or the last space.
        $at = $spec.IndexOf("<<:>>")
        if ($at -lt 1) { continue }
        # Quoted identifiers: a column named ORDER or one with a lower-case
        # letter or a space is legal in Exasol and illegal unquoted.
        $cols += ('"' + $spec.Substring(0, $at) + '" ' + $spec.Substring($at + 5))
    }
    if ($cols.Count -eq 0) { return "" }
    return ('CREATE TABLE "' + $Schema + '"."' + $Table + '" (' + ($cols -join ", ") + ')')
}

# --- the kit's own sample data ----------------------------------------------
#
# The bundled datasets (data\datasets\<id>\) are the kit's, not the user's. The
# install that runs around the crossing loads them itself, and `exakit
# data-load` puts them back any time. Copying them out of the old database and
# into the new one would spend minutes on tables the new database already has -
# and the restore would then have to refuse each one as already there. So a
# table that IS a bundled sample table, unchanged, is left out of the copy and
# named as such. "Unchanged" means the same schema, the same table and the same
# number of rows as the CSV the kit ships; a sample table the user has changed
# is theirs and travels with the rest. Twin of the same section in the sh module.

# One entry per table the bundled datasets create, read from the kit's own
# files: Table (SCHEMA.TABLE), Id (the dataset), Rows (in the CSV). The schema
# comes from dataset.conf, the table from the CSV's name - the rule the loader
# applies - and the row count from the file itself.
#
# NOT EVERY SAMPLE TABLE HAS A CSV. A dataset may create a table and fill it
# from SQL - energy's ENERGY_READINGS is generated by 02_load_data.sql, 108,000
# rows and no file - and a catalog built from the CSV names alone does not know
# that table exists at all. It then reads as the user's own: the crossing
# offers to copy the kit's own sample data back to itself, and the restore,
# which asks this same catalog whether to stand aside, does not. So the markers
# dataset.conf already declares are read in as well, and a marker with no CSV
# behind it is listed with an EMPTY Rows - the name is known, the size is not.
# What that means for "unchanged" is Split-LegacyTables' business.
function Get-LegacySampleCatalog {
    $catalog = @()
    if (-not (Get-Command Get-ExakitBundledDatasets -ErrorAction SilentlyContinue)) { return $catalog }
    $root = Get-ExakitRepoRoot
    if (-not $root) { return $catalog }
    foreach ($ds in @(Get-ExakitBundledDatasets)) {
        $seen = @()
        $dir = Join-Path $root ("data\datasets\" + $ds.Id + "\data")
        foreach ($csv in (Get-ChildItem -Path (Join-Path $dir "*.csv") -File -ErrorAction SilentlyContinue)) {
            # The header is not a row, and a last line without a newline still is.
            $lines = 0
            $reader = New-Object System.IO.StreamReader($csv.FullName)
            try { while ($null -ne $reader.ReadLine()) { $lines++ } } finally { $reader.Close() }
            $rows = if ($lines -gt 0) { $lines - 1 } else { 0 }
            $name = $csv.BaseName.ToUpper()
            $seen += $name
            $catalog += @{ Table = ($ds.Schema + "." + $name); Id = $ds.Id; Rows = $rows }
        }
        # The declared tables no CSV already accounted for, row count unknown.
        foreach ($marker in @($ds.Markers)) {
            $name = ("" + $marker).Trim().ToUpper()
            if (-not $name) { continue }
            if ($seen -contains $name) { continue }
            $seen += $name
            $catalog += @{ Table = ($ds.Schema + "." + $name); Id = $ds.Id; Rows = "" }
        }
    }
    return $catalog
}

# SCHEMA.TABLE -> rows for every table of the old database in the given schemas,
# from the row count Exasol keeps in EXA_ALL_TABLES. One query for all of them;
# a table whose count is not known has no entry.
function Get-LegacyTableRows {
    param([string]$SchemaList)
    $rows = @{}
    $sql = "SELECT 'EXAKIT_LR[' || TABLE_SCHEMA || '.' || TABLE_NAME || '<<:>>' || CAST(TABLE_ROW_COUNT AS VARCHAR(40)) || ']' AS R FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA IN ($SchemaList)"
    $out = Invoke-LegacyQuery -Sql $sql
    foreach ($m in [regex]::Matches($out, 'EXAKIT_LR\[([^\]]*)\]')) {
        $spec = $m.Groups[1].Value
        $at = $spec.IndexOf("<<:>>")
        if ($at -lt 1) { continue }
        $rows[$spec.Substring(0, $at)] = $spec.Substring($at + 5)
    }
    return $rows
}

# The old database's tables split into the user's own ($script:LegacyOwnTables)
# and the kit's unchanged sample tables ($script:LegacySampleTables), with the
# datasets those belong to in $script:LegacySampleIds. Asks the old database for
# row counts only when a table sits in a sample schema at all, and then once.
# Twin of legacy_classify.
function Split-LegacyTables {
    param([string[]]$Tables)
    $script:LegacyOwnTables = @()
    $script:LegacySampleTables = @()
    $script:LegacySampleIds = ""
    $catalog = @{}
    foreach ($entry in @(Get-LegacySampleCatalog)) { $catalog[$entry.Table] = $entry }
    $schemas = @()
    foreach ($t in @($Tables)) {
        if (-not $t -or -not $catalog.ContainsKey($t)) { continue }
        $s = "'" + $t.Substring(0, $t.IndexOf(".")) + "'"
        if ($schemas -notcontains $s) { $schemas += $s }
    }
    $rows = @{}
    if ($schemas.Count -gt 0) { $rows = Get-LegacyTableRows -SchemaList ($schemas -join ",") }
    foreach ($t in @($Tables)) {
        if (-not $t) { continue }
        $entry = $null
        if ($catalog.ContainsKey($t)) { $entry = $catalog[$t] }
        # UNCHANGED, as far as it can be told. A table with a CSV behind it is
        # the kit's only while the old database still holds exactly the rows
        # the file ships; touch it and it becomes the user's and travels. A
        # table the dataset GENERATES has no file to count against, so
        # "changed" cannot be measured - and guessing the other way is the
        # expensive mistake: it offers the user their own sample data back,
        # copies 108,000 rows nobody asked for, and restores them minutes
        # before the dataset load replaces the table anyway.
        $same = $false
        if ($entry) {
            if (("" + $entry.Rows) -eq "") {
                $same = $true
            } elseif ($rows.ContainsKey($t) -and ("" + $rows[$t]) -eq ("" + $entry.Rows)) {
                $same = $true
            }
        }
        if ($same) {
            $script:LegacySampleTables += $t
            $ids = @($script:LegacySampleIds -split "," | Where-Object { $_ })
            if ($ids -notcontains $entry.Id) { $ids += $entry.Id }
            $script:LegacySampleIds = ($ids -join ",")
        } else {
            $script:LegacyOwnTables += $t
        }
    }
}

# The sentence that says what is left out. Twin of legacy_sample_note.
function Write-LegacySampleNote {
    param([int]$Own, [int]$Sample)
    Info "$Sample of them belong to the kit's bundled sample data ($($script:LegacySampleIds)), unchanged - the kit loads that itself, so they are not copied. Your own: $Own table(s)."
}

# --- the two halves ---------------------------------------------------------

# The question, asked once. Two answers, and they are exclusive: this is a fork
# in the road, not a set of features. EXAKIT_LEGACY_DATA pre-answers it, and an
# unattended run with no answer SKIPS - copying a database is not something to
# start on someone's behalf while they are not there, and skipping destroys
# nothing.
function Select-LegacyChoice {
    param([int]$TableCount, [bool]$CanMigrate, [string]$Why)

    switch ("" + $env:EXAKIT_LEGACY_DATA) {
        { $_ -in @("migrate", "yes", "1") } {
            if ($CanMigrate) { $script:LegacyChoice = "migrate" }
            else {
                Warn2 "EXAKIT_LEGACY_DATA asked for a migration, but $Why"
                $script:LegacyChoice = "skip"
            }
            return
        }
        { $_ -in @("skip", "no", "0") } { $script:LegacyChoice = "skip"; return }
    }

    if (-not $CanMigrate) {
        Warn2 "Your data cannot be copied automatically: $Why"
        $script:LegacyChoice = "skip"
        return
    }

    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Info "Nothing is asked in an unattended run, so the old database is left alone."
        Info "To copy it into the new one, re-run with EXAKIT_LEGACY_DATA=migrate - or afterwards: exakit migrate docker-nano"
        $script:LegacyChoice = "skip"
        return
    }

    # Row 2 is the exclusive one: picking "skip" clears "migrate" and the other
    # way round.
    $picked = Read-ExakitCheckboxMenu -Title "Your existing database" `
        -Options @(
            "Migrate my data - copy $TableCount table(s) into the new database",
            "Skip and continue - set up the new database empty, and leave the old one alone") `
        -Defaults @(1) -ExclusiveIndex 2
    if ($picked -contains 2) { $script:LegacyChoice = "skip" } else { $script:LegacyChoice = "migrate" }
}

# Every non-system table to CSV under $Dir, plus a plain index the second half
# reads back.
#
# CSV, not Parquet: `exapump export --format parquet` is broken in the versions
# this kit installs (it writes the rows as CSV and then fails re-parsing its own
# output), so asking for Parquet produces a 0-byte file and a confusing error.
# CSV round-trips faithfully INTO A TABLE THAT ALREADY EXISTS with the right
# types, which is what Get-LegacyTableDdl is for.
#
# THE ONE THING CSV CANNOT CARRY: an empty string and a NULL are the same three
# bytes in a CSV field, so a VARCHAR that held '' arrives as NULL. That is named
# on screen before the copy starts, not discovered afterwards.
function Export-LegacyTables {
    param([string]$Dir, [string[]]$Tables)
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $indexPath = Join-Path $Dir "index"
    Set-Content -Path $indexPath -Value @() -Encoding Ascii
    $ok = 0; $bad = 0; $n = 0; $badNames = ""
    # A BAR, NOT A SPINNER PER TABLE. Copying a database out is the one long
    # stretch of the crossing, and a spinner says only "still going"; the bar
    # says how much of it is left, in the same shape the deploy and the dataset
    # loads use. Start-ExakitProgress answers $false where it cannot draw (no
    # terminal, or a table already owns the line), and the labels below then
    # narrate nothing, exactly as before. Twin of legacy_export.
    $total = @($Tables).Count
    $live = $false
    if ($total -gt 0) { $live = Start-ExakitProgress -Pct 0 -Ceiling 0 -Secs 1 -Phase "Copying $total table(s) out of the old database" }
    foreach ($t in $Tables) {
        $n++
        if ($live) {
            Set-ExakitProgress -Pct ([int](($n - 1) * 100 / $total)) -Ceiling ([int]($n * 100 / $total)) `
                -Secs 4 -Phase "Copying out $t ($n of $total)"
        }
        $dot = $t.IndexOf(".")
        if ($dot -lt 1) { continue }
        $schema = $t.Substring(0, $dot)
        $table = $t.Substring($dot + 1)
        # The file name is positional, not derived from the table name: a
        # schema or table with a dot, a slash or a space in it is legal in
        # Exasol and would otherwise escape the directory.
        $file = "t$n.csv"
        $script:ExakitActiveLabel = "Copying out $t ($n/$($Tables.Count))"
        # THE TABLE IS NAMED AS A QUERY, WITH BOTH IDENTIFIERS QUOTED: a bare
        # `--table S.T` never resolved a schema or table that needs quotes, and
        # the export sat for its full timeout. The restore has always quoted its
        # target the same way. Twin of the same change in legacy_export.
        $query = 'SELECT * FROM "' + $schema + '"."' + $table + '"'
        if ((Invoke-ExakitLogged (Get-ExapumpCli) "export" "-p" $script:LegacyProfile `
                "--query" $query "--format" "csv" "-o" (Join-Path $Dir $file)) -eq 0) {
            $ddl = Get-LegacyTableDdl -Schema $schema -Table $table
            # The index is read back by the other half, so it carries
            # everything that half needs: where the rows are, where they go,
            # and how to build the table that receives them.
            Add-Content -Path $indexPath -Value ("$file`t$schema`t$table`t$ddl") -Encoding Ascii
            $ok++
        } else {
            # The partial file goes. exapump creates the output before it
            # knows the query works, so a failed export leaves a 0-byte file -
            # harmless (nothing indexes it) but alarming to find in a
            # directory whose whole job is holding someone's data.
            Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Dir $file)
            Warn2 "Could not copy $t out of the old database - it is left there, untouched"
            $bad++
            # The NAME, not just a tally - see the twin in legacy-crossing.sh.
            # This warning was the only place the table was ever mentioned.
            $badNames = "$badNames $t"
        }
    }
    if ($live) {
        Stop-ExakitProgress
        Ok "Copied $ok of $total table(s) out"
    }
    $script:ExakitActiveLabel = ""
    Set-ExakitManifestValue "legacy.exported" $ok
    if ($bad -gt 0) {
        Set-ExakitManifestValue "legacy.export_failed" $bad
        Set-ExakitManifestValue "legacy.export_failed_names" $badNames.Trim()
    }
    return ($ok -gt 0)
}

# The saved tables into the database that is now running.
#
# A table the fresh install has already created is SKIPPED, not appended to.
# The bundled sample data is loaded before this runs, so appending would double
# every row of every sample table a user also had.
# A real query against the NEW database through the kit's own profile: the gate
# in front of every restore. The same reader as every other probe, inside the
# same Continue window. Twin of legacy_new_db_answers.
function Test-LegacyNewDbAnswers {
    return ((Invoke-LegacyQuery -Sql "SELECT 'EXAKIT_NEW_OK' AS P" -Profile $script:ExapumpProfile) -match "EXAKIT_NEW_OK")
}

# Test-LegacySampleTable <SCHEMA.TABLE> - would a bundled dataset create this
# table? Then it is not restored.
#
# The unchanged sample tables never leave the old database at all (see
# Split-LegacyTables). A CHANGED one does come across, and it used to be
# restored after the sample load, where the "this table already exists" gate
# kept the copy on disk instead of overwriting the kit's own. Restoring before
# that load moves the collision: the dataset's CREATE OR REPLACE would land on
# top of the user's rows minutes later. So the answer is the same either way -
# the copy is kept, the table is not restored, and the message says where it is.
# Twin of legacy_is_sample_table.
function Test-LegacySampleTable {
    param([Parameter(Mandatory)][string]$Qualified)
    foreach ($row in @(Get-LegacySampleCatalog)) {
        if ($row.Table -eq $Qualified) { return $true }
    }
    return $false
}

function Import-LegacyTables {
    param([string]$Dir)
    $indexPath = Join-Path $Dir "index"
    if (-not (Test-Path $indexPath)) { return $false }
    # THE NEW DATABASE HAS TO ANSWER FIRST. A CREATE TABLE that fails is read
    # below as "already there" - and on a real machine every one of them failed
    # on authentication instead, so an unreachable database reported "Restored
    # 0, Left alone: <every table>" and recorded the restore as done.
    if (-not (Test-LegacyNewDbAnswers)) { return $false }
    $ok = 0; $skipped = 0; $bad = 0; $skippedNames = ""
    # The same bar on the way back in; the total is what the index holds, so a
    # copy that failed halfway still reports against what there is to restore.
    $inTotal = @(Get-Content $indexPath -ErrorAction SilentlyContinue | Where-Object { $_ }).Count
    $inN = 0
    $inLive = $false
    if ($inTotal -gt 0) { $inLive = Start-ExakitProgress -Pct 0 -Ceiling 0 -Secs 1 -Phase "Restoring $inTotal table(s) into the new database" }
    foreach ($line in (Get-Content $indexPath)) {
        if (-not $line) { continue }
        $parts = $line -split "`t", 4
        if ($parts.Count -lt 3) { continue }
        $file = $parts[0]; $schema = $parts[1]; $table = $parts[2]
        $ddl = ""
        if ($parts.Count -ge 4) { $ddl = $parts[3] }
        $path = Join-Path $Dir $file
        if (-not (Test-Path $path)) { continue }
        $target = '"' + $schema + '"."' + $table + '"'
        $inN++
        if ($inLive) {
            Set-ExakitProgress -Pct ([int](($inN - 1) * 100 / $inTotal)) -Ceiling ([int]($inN * 100 / $inTotal)) `
                -Secs 4 -Phase "Restoring $schema.$table ($inN of $inTotal)"
        }
        # A TABLE A BUNDLED DATASET WILL CREATE IS LEFT IN THE COPY - see
        # Test-LegacySampleTable. The restore runs before the sample load now,
        # so "it already exists" no longer catches this.
        if (Test-LegacySampleTable -Qualified "$schema.$table") {
            $skipped++
            $skippedNames = "$skippedNames $schema.$table"
            continue
        }
        $script:ExakitActiveLabel = "Restoring $schema.$table"
        # CREATE SCHEMA is unconditional and harmless; CREATE TABLE is the test
        # for "does this already exist", so its failure is not an error here.
        [void](Invoke-ExakitLogged (Get-ExapumpCli) "sql" "-p" $script:ExapumpProfile `
            ('CREATE SCHEMA IF NOT EXISTS "' + $schema + '"'))
        if ($ddl) {
            if ((Invoke-ExakitLogged (Get-ExapumpCli) "sql" "-p" $script:ExapumpProfile $ddl) -ne 0) {
                # Already there - the fresh install created it. Leave it alone.
                $skipped++
                $skippedNames = "$skippedNames $schema.$table"
                continue
            }
        }
        if ((Invoke-ExakitLogged (Get-ExapumpCli) "upload" "-p" $script:ExapumpProfile `
                "--table" $target $path) -eq 0) {
            $ok++
        } else {
            Warn2 "Could not restore $schema.$table - the copy is kept at $(Get-ExakitTilde $path)"
            $bad++
        }
    }
    if ($inLive) { Stop-ExakitProgress }
    $script:ExakitActiveLabel = ""
    Set-ExakitManifestValue "legacy.restored" $ok
    if ($skipped -gt 0) { Set-ExakitManifestValue "legacy.restore_skipped" $skipped }
    if ($bad -gt 0) { Set-ExakitManifestValue "legacy.restore_failed" $bad }
    $script:LegacyRestored = $ok
    $script:LegacySkipped = $skipped
    $script:LegacySkippedNames = $skippedNames
    $script:LegacyRestoreFailed = $bad
    return $true
}

# The first half: say what was found, ask, copy out, stop the container. Never
# fails the install - every arm that cannot continue falls back to leaving the
# old database exactly where it is.
function Invoke-LegacyCrossingBefore {
    # ASKED ONCE, AND ONLY WHERE THERE IS SOMETHING TO ASK ABOUT.
    #
    # Three gates, cheapest first, and all three are silent when they close.
    # An installer that announces "your database is in a container" to someone
    # whose container is long gone, or on every re-run after the crossing has
    # already happened, is a nag - and this code runs on EVERY install.
    #
    #   1. the record says this is not a legacy install       -> nothing
    #   2. the crossing already happened on this machine      -> nothing
    #   3. there is no readable database with tables in it     -> nothing
    #
    # Only past all three does anything reach the screen.
    if (-not (Test-LegacyDbRecorded)) { return }

    # THE OLD KIT'S STEP TICKS ARE NOT THIS KIT'S. Its manifest says "runtime"
    # is done - that was the container. Left in place, the deployment step was
    # skipped as already done, nothing ever recorded the new runtime, and every
    # later step talked to the new database with the old one's password. The
    # ticks go for as long as the record still names the container - BEFORE the
    # crossing-done gate, because an install that crossed and then died before
    # its deployment step arrives here with the gate closed and the ticks still
    # standing. Twin of legacy_forget_old_steps.
    Clear-LegacyOldSteps

    # DONE MEANS ASKED AND ANSWERED, NOT "LEAVE THE PORT ALONE". The container
    # publishes the port the new deployment needs, so a crossing that is over
    # must still take it out of the way - without this the install died on
    # "port 8563 is in use" on every later run, with no way forward but a
    # docker stop by hand. Twin of legacy_crossing_before.
    if ("" + (Get-ExakitManifestValue "legacy.crossing_done") -eq "True") {
        [void](Stop-LegacyContainer -Quiet)
        return
    }

    # An earlier attempt at THIS install already answered. Finish the leftover
    # work and say nothing: the question was asked, and asking again (or
    # narrating a resume) is the same nag from the other direction. The restore
    # half does the talking, because it has something to report.
    $already = "" + (Get-ExakitManifestValue "legacy.choice")
    if ($already) {
        $script:LegacyChoice = $already
        Write-ExakitLog "INFO" "legacy crossing: resuming with choice=$already"
        [void](Stop-LegacyContainer -Quiet)
        return
    }

    $type = "" + (Get-ExakitManifestValue "runtime.type")
    $container = Get-LegacyContainer
    $state = Get-LegacyContainerState
    # The record, kept: the deployment step is about to overwrite runtime.*, and
    # `exakit migrate docker-nano` has to find the old database afterwards.
    Save-LegacyRecord

    # THE PROBE COMES BEFORE THE BANNER. Whether there is a database worth
    # talking about is answerable without saying a word, and if the answer is
    # no this function has nothing to tell anyone.
    # $retry SEPARATES A CONDITION FROM A DECISION. "There is nothing to copy"
    # is settled forever; "this machine cannot read it right now" is not, and
    # marking the second one done cost a user their data permanently: one run
    # could not see the engine, wrote the crossing off as finished, and no
    # later run - with the engine right there - ever offered again.
    $can = $true; $why = ""; $retry = $false
    if (-not (Get-LegacyEngine)) {
        $can = $false; $retry = $true; $why = "the container engine this database needs is not on this machine any more"
    } elseif ($state -eq "absent") {
        $can = $false; $why = "the container is gone, so there is nothing left to copy"
    } elseif ($state -eq "unknown") {
        $can = $false; $retry = $true; $why = "$(Get-LegacyEngineName) is not answering (is Docker Desktop or the Podman machine running?)"
    } elseif (-not (Test-Path (Get-ExapumpCli))) {
        $can = $false; $retry = $true; $why = "exapump is not installed yet, and it is what reads the tables out"
    }

    # A stopped container still holds the data, so it is started - but quietly,
    # and only once the gates above have said there is a point.
    $started = $false
    if ($can -and $state -eq "stopped") {
        if (Start-LegacyContainer) { $started = $true }
        else { $can = $false; $retry = $true; $why = "the old container would not start" }
    }

    $tables = @()
    if ($can) {
        if (Write-LegacyProfile) {
            # Up to two minutes, and only for a container this run just
            # started: one that was already running answers on the first ask.
            $budget = 120
            if ($env:EXAKIT_LEGACY_READY_TIMEOUT) { $budget = [int]$env:EXAKIT_LEGACY_READY_TIMEOUT }
            if (-not $started) { $budget = 10 }
            if (Wait-LegacyDbAnswers -Budget $budget) {
                $tables = Get-LegacyTables
            } else {
                $can = $false; $retry = $true; $why = "the old database did not answer in time"
            }
        } else {
            $can = $false; $retry = $true; $why = "the password for the old database is not on file, so it cannot be read"
        }
    }

    # The kit's own sample data is not "my data": it is left out of the count
    # the user is asked about, and out of the copy.
    $total = @($tables).Count
    $sample = 0
    if ($can) {
        Split-LegacyTables -Tables @($tables)
        $sample = @($script:LegacySampleTables).Count
    } else {
        $script:LegacyOwnTables = @()
    }
    $count = @($script:LegacyOwnTables).Count
    if ($can -and $count -eq 0) {
        if ($sample -gt 0) {
            $can = $false; $why = "the old database holds only the kit's bundled sample data ($($script:LegacySampleIds)), unchanged, which this install loads itself"
        } else {
            $can = $false; $why = "the old database has no tables in it"
        }
    }

    # GATE 3. Nothing to offer, so nothing is said. The reason goes to the log,
    # where someone asking "why was I not offered a migration?" can find it,
    # and the crossing is marked done so this is never reconsidered.
    if (-not $can) {
        Write-ExakitLog "INFO" "legacy crossing: no offer made - $why"
        # Either way the container may be holding the port the new deployment
        # needs, whether or not its data could be read.
        [void](Stop-LegacyContainer -Quiet)
        if ($retry) {
            # A CONDITION, NOT A DECISION: nothing is recorded as chosen and the
            # crossing is not closed, so the next run - on a machine where the
            # obstacle is gone - asks the question this one could not.
            Set-ExakitManifestValue "legacy.offer_blocked" $why
            return
        }
        Set-ExakitManifestValue "legacy.choice" "skip"
        Set-ExakitManifestValue "legacy.crossed_from" $type
        if ($sample -gt 0) { Set-ExakitManifestValue "legacy.sample_left_out" $script:LegacySampleIds }
        Set-ExakitManifestValue "legacy.crossing_done" $true
        return
    }

    # Past all three gates: there is a real database with real tables in it,
    # and this is the one and only time the user is asked about it.
    Write-Host ""
    # ONE LINE, THEN THE QUESTION. This was six lines of explanation before a
    # yes/no - what the kit no longer manages, what it deploys instead, what the
    # copy costs, which tables are the kit's own, and a caveat about empty
    # strings - all of it ahead of a decision that needs the name, the size and
    # nothing else. What survives: the container, its state, and how much of the
    # user's own data is in it. The caveat moves to the copy itself, where it is
    # about to matter; the rest is in the docs. Twin of legacy_crossing_before.
    $schemas = @($script:LegacyOwnTables | ForEach-Object { ("" + $_).Split(".")[0] } | Sort-Object -Unique).Count
    $where = ""
    if ($container) { $where = " in the container '$container' ($state)" }
    $mine = "$count table(s)"
    if ($schemas -gt 0) { $mine = "$mine in $schemas schema(s)" }
    $rest = ""
    if ($sample -gt 0) { $rest = " The other $sample is the kit's own $($script:LegacySampleIds) sample, which this install loads itself." }
    # THE COPY IS MADE HERE, THE QUESTION IS ASKED LATER. This is the only
    # moment the old container can be read at all: it publishes the port, and
    # the deployment that is about to be installed needs that same port, so
    # from the next step onwards the container is stopped. Asking here meant
    # asking before the kit had installed a single thing - the first words of
    # the run, about a database the user may have forgotten they had.
    #
    # So the tables are read out now, into a directory under the kit's own
    # home, and nothing is said about it; the question goes where it belongs,
    # after exapump and before the sample data (Invoke-LegacyCrossingAfter),
    # and a "no" there deletes the copy. Nothing in the old container is
    # changed either way, and no data leaves this machine. Twin of
    # legacy_crossing_before.
    Set-ExakitManifestValue "legacy.crossed_from" $type
    Set-ExakitManifestValue "legacy.tables_total" $total
    Set-ExakitManifestValue "legacy.tables_own" $count
    Set-ExakitManifestValue "legacy.tables_sample" $sample
    Set-ExakitManifestValue "legacy.container_state" $state
    if ($sample -gt 0) { Set-ExakitManifestValue "legacy.sample_left_out" $script:LegacySampleIds }

    # A COPY THAT IS ALREADY THERE IS NOT MADE AGAIN. A run that died between
    # the two halves comes back through here, and re-reading a database that has
    # not changed only overwrites a good copy with a second one - and, on a
    # resume, the container may no longer be able to answer at all. The waiting
    # copy is what the second half asks about. Twin of legacy_crossing_before.
    $waiting = Join-Path $script:LegacyExportDir "index"
    if ((Test-Path $waiting) -and ((Get-Item $waiting).Length -gt 0) -and
        ("" + (Get-ExakitManifestValue "legacy.restored") -eq "")) {
        Write-ExakitLog "INFO" "legacy crossing: a copy is already waiting at $($script:LegacyExportDir)"
        Set-ExakitManifestValue "legacy.export_dir" $script:LegacyExportDir
        [void](Stop-LegacyContainer)
        Write-Host ""
        return
    }

    if (Export-LegacyTables -Dir $script:LegacyExportDir -Tables @($script:LegacyOwnTables)) {
        Set-ExakitManifestValue "legacy.export_dir" $script:LegacyExportDir
    } else {
        # Nothing could be read. There is nothing to offer later, and saying so
        # here would be the first line of the install, so it goes to the log;
        # the old container is left exactly as it was.
        # A CONDITION, NOT AN ANSWER. Recording "skip" here would put words in
        # the user's mouth and close the crossing for good; the reason is kept
        # and the question stays open, exactly as it does for an engine that
        # could not be found. Twin of legacy_crossing_before.
        Write-ExakitLog "WARN" "legacy crossing: nothing could be copied out of $container"
        Set-ExakitManifestValue "legacy.offer_blocked" "nothing could be copied out of the old database"
    }

    [void](Stop-LegacyContainer)
    Write-Host ""
}

# Invoke-LegacyCrossingAfter - THE QUESTION AND THE RESTORE, in the one place
# that can hold both: after exapump, before the sample data. The copy already
# exists (Invoke-LegacyCrossingBefore read it out while the container still had
# the port), so this asks about something real and a "no" deletes it. Twin of
# legacy_crossing_after.
function Invoke-LegacyCrossingAfter {
    $dir = "" + (Get-ExakitManifestValue "legacy.export_dir")
    if (-not $dir) { return }
    $indexPath = Join-Path $dir "index"
    if (-not (Test-Path $indexPath)) { return }
    if ("" + (Get-ExakitManifestValue "legacy.restored") -ne "") { return }

    # NO NEW DATABASE, NO QUESTION. When the deployment step failed there is
    # nothing to restore into: asking "Migrate my data?" and then reporting
    # "could not be restored" read as data loss, while the copy was safe on
    # disk all along. Nothing is asked or recorded, so the next run starts the
    # crossing fresh and asks once the database is up. The old container was
    # stopped to free the port - it is started again, so the user is not left
    # with no database at all; the next run stops it again before deploying.
    # Twin of the same gate in legacy_crossing_after.
    if (Test-ExakitSoftFailed -Component "runtime") {
        Write-Host ""
        $container = Get-LegacyContainer
        if ($container -and (Start-LegacyContainer)) {
            Info "Your previous database ($container) is running again, with all its data, while the new one is not installed."
        }
        Info "Your data is safe: the copy is kept at $(Get-ExakitTilde $dir), and nothing in the old database was changed."
        Info "Re-run the installer to finish - it offers to copy your data in once the new database is up: $(Get-ExakitInstallCommand)"
        return
    }

    $choice = "" + (Get-ExakitManifestValue "legacy.choice")
    if (-not $choice) {
        $own = "" + (Get-ExakitManifestValue "legacy.tables_own")
        $sample = "" + (Get-ExakitManifestValue "legacy.tables_sample")
        $container = Get-LegacyContainer
        # NOT the state it had when it was read: by the time this asks, the
        # container has been stopped so the deployment could take the port, and
        # printing "(running)" here said the opposite of what was true.
        # The schemas of the copy itself: column 2 of the index, which is what
        # was actually read out, not what the old database happened to hold.
        $schemas = @(Get-Content $indexPath -ErrorAction SilentlyContinue |
            Where-Object { $_ } |
            ForEach-Object { ("" + $_).Split("`t")[1] } |
            Sort-Object -Unique).Count
        $where = ""
        if ($container) { $where = " in the container '$container' (stopped for this install)" }
        $mine = "$own table(s)"
        if ($schemas -gt 0) { $mine = "$mine in $schemas schema(s)" }
        $rest = ""
        if ([int]("0" + $sample) -gt 0) {
            $ids = "" + (Get-ExakitManifestValue "legacy.sample_left_out")
            $rest = " The other $sample is the kit's own $ids sample, which this install loads itself."
        }
        Write-Host ""
        Info "Found your previous starter kit's database${where}: $mine of your own.$rest"
        Select-LegacyChoice -TableCount ([int]("0" + $own)) -CanMigrate $true -Why ""
        Set-ExakitManifestValue "legacy.choice" $script:LegacyChoice
        if ($script:LegacyChoice -ne "migrate") {
            # A NO DELETES THE COPY. It was made without asking, so it does not
            # outlive the answer - and the old container still holds the
            # original, untouched.
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
            Set-ExakitManifestValue "legacy.export_dir" ""
            Set-ExakitManifestValue "legacy.crossing_done" $true
            Info "The old database is left exactly as it was, stopped, with its data."
            Info "To copy it into the new database later: exakit migrate docker-nano"
            $rm = Get-LegacyRemoveCommand
            if ($rm) { Info "When you no longer want it: $rm" }
            Write-Host ""
            return
        }
        Info "Nothing in the old database is changed. One thing to know: a text column that held an empty string arrives as NULL."
    } else {
        Write-Host ""
        Info "Restoring your data into the new database"
    }

    if (-not (Import-LegacyTables -Dir $dir)) {
        Warn2 "Your data could not be restored. The copy is kept at $(Get-ExakitTilde $dir)."
        return
    }
    [void](Write-LegacyRestoreReport -Dir $dir -Why "this install had already created them")
    Set-ExakitManifestValue "legacy.crossing_done" $true
    Write-Host ""
}

# What landed and what did not, after Import-LegacyTables. $false when something
# did not restore, so the copy is named as still needed. Twin of
# legacy_report_restore.
function Write-LegacyRestoreReport {
    param([string]$Dir, [string]$Why)
    Ok "Restored $($script:LegacyRestored) table(s) from your previous database"
    if ($script:LegacySkipped -gt 0) {
        Info "Left alone ($Why):$($script:LegacySkippedNames)"
    }
    if ($script:LegacyRestoreFailed -gt 0) {
        Warn2 "$($script:LegacyRestoreFailed) table(s) did not restore - the copies are still at $(Get-ExakitTilde $Dir)"
        return $false
    }
    # TABLES THAT NEVER LEFT THE OLD DATABASE COUNT TOO. This tallied only
    # RESTORED / SKIPPED / RESTORE_FAILED, so a table that failed at the EXPORT
    # step was mentioned once, inside a progress bar, during a long install -
    # and then never again. The screen called the copy no longer needed and
    # handed over the command to delete the container holding the only
    # surviving copy. legacy.export_failed was recorded and read by nothing.
    $exFail = Get-ExakitManifestValue "legacy.export_failed"
    if ($exFail -and ([int]$exFail) -gt 0) {
        $exNames = Get-ExakitManifestValue "legacy.export_failed_names"
        $suffix = ""
        if ($exNames) { $suffix = ": $exNames" }
        Warn2 "$exFail table(s) could NOT be copied out of the old database$suffix"
        Warn2 "Those tables exist ONLY in the old container. Do not remove it until you have them."
        Info "Try the copy again with: exakit migrate docker-nano"
        return $false
    }
    # The copy is only removed once every table is accounted for - which now
    # means exported AND restored - and the old container still has the
    # original either way.
    Info "The copy at $(Get-ExakitTilde $Dir) is no longer needed; remove it whenever you like."
    $rm = Get-LegacyRemoveCommand
    if ($rm) { Info "The old container still holds the original. To remove it: $rm" }
    return $true
}

# --- after the install: exakit migrate docker-nano --------------------------
#
# The crossing asks once, during an install. Someone who answered "skip" then
# and wants the data after all, or whose container the installer never saw (made
# by hand, or by the upstream kit on a machine this kit was installed fresh on),
# still has a database in a container - and this is the same copy, in one
# sitting: the old database is read, its tables restored into the deployment
# that is already running, the kit's own sample data left where it is.
#
# THE PORT IS THE COMPLICATION. Both databases want 8563. When the container
# publishes the deployment's port, the deployment is stopped for the copy out
# and started again before the copy in; when it does not, nothing is stopped.
# The container ends as it began - except one holding the deployment's port,
# which stays stopped because the deployment has to have it back.
#
# Configured through the EXAKIT_LEGACY_* variables the accessors read, which the
# CLI fills from its options and from the record the crossing kept. Returns 0
# when done (or when there was nothing of the user's to copy), 1 when it
# failed, 5 when it was declined; $script:LegacyMigrateStatus and -Reason carry
# the outcome for the CLI's --json. Nothing here calls Fail(): the CLI decides
# how a failure is shown. Twin of legacy_migrate_now.

$script:LegacyMigrateStarted = $false
$script:LegacyMigrateClash = $false
$script:LegacyMigrateDbStopped = $false

function Set-LegacyMigrateFailure {
    param([string]$Reason, [string]$Remedy = "")
    $script:LegacyMigrateStatus = "failed"
    $script:LegacyMigrateReason = $Reason
    $script:LegacyMigrateRemedy = $Remedy
    Write-ExakitError $Reason
    if ($Remedy) { Info "Then: $Remedy" }
    Write-ExakitLog "ERROR" "legacy migrate: $Reason"
}

# $true once nothing listens on the port. Twin of legacy_wait_port_free.
function Wait-LegacyPortFree {
    param([int]$Port, [int]$Seconds)
    for ($n = 0; $n -lt $Seconds; $n++) {
        if (-not (Test-ExakitPortInUse -Port $Port)) { return $true }
        Start-Sleep -Seconds 1
    }
    return (-not (Test-ExakitPortInUse -Port $Port))
}

# Everything back the way it was found, except a container on the deployment's
# port, which stays stopped so the deployment can have the port back. $false
# when the deployment did not come back. Twin of _legacy_migrate_settle.
function Restore-LegacyMigrateState {
    if ($script:LegacyMigrateStarted -or $script:LegacyMigrateClash) {
        [void](Stop-LegacyContainer -Quiet)
    }
    if ($script:LegacyMigrateDbStopped -or -not (Test-PersonalDeploymentRunning)) {
        $script:ExakitActiveLabel = "Starting your database again"
        try {
            Start-Personal
            Wait-PersonalReady
        } catch {
            return $false
        }
    }
    return $true
}

function Invoke-LegacyMigrateNow {
    param([bool]$Yes = $false)
    $script:LegacyMigrateStatus = ""; $script:LegacyMigrateReason = ""; $script:LegacyMigrateRemedy = ""
    $script:LegacyRestored = 0; $script:LegacySkipped = 0; $script:LegacyRestoreFailed = 0
    $script:LegacyExported = 0; $script:LegacySampleIds = ""
    $script:LegacyMigrateStarted = $false; $script:LegacyMigrateClash = $false; $script:LegacyMigrateDbStopped = $false
    $container = Get-LegacyContainer
    $engineName = Get-LegacyEngineName
    if (-not $container) {
        Set-LegacyMigrateFailure "No container is named. Say which one holds the old database: exakit migrate docker-nano --container <name>"
        return 1
    }
    if (-not (Get-LegacyEngine)) {
        $shown = if ($engineName) { $engineName } else { "?" }
        Set-LegacyMigrateFailure "The container engine '$shown' is not on this machine, so the container '$container' cannot be reached." "exakit migrate docker-nano --engine docker|podman"
        return 1
    }
    $state = Get-LegacyContainerState
    if ($state -eq "absent") {
        Set-LegacyMigrateFailure "There is no container named '$container' in $engineName. List them with '$engineName ps -a' and name the right one with --container."
        return 1
    }
    if ($state -eq "unknown") {
        Set-LegacyMigrateFailure "$engineName did not answer about the container '$container' - it looks stopped. Start it (Docker Desktop, or: podman machine start), then run: exakit migrate docker-nano"
        return 1
    }
    if (-not (Test-Path (Get-ExapumpCli))) {
        Set-LegacyMigrateFailure "exapump is not installed, and it is what reads the tables out." "exakit update"
        return 1
    }

    # A copy from an earlier run that never landed is finished first: it is
    # the user's data, waiting, and a fresh copy over it would destroy it.
    $dir = $script:LegacyExportDir
    $indexPath = Join-Path $dir "index"
    if ((Test-Path $indexPath) -and (Get-Item $indexPath).Length -gt 0 -and ("" + (Get-ExakitManifestValue "legacy.restored")) -eq "") {
        Info "A copy from an earlier run is waiting at $(Get-ExakitTilde $dir) - restoring it first"
        if (-not (Import-LegacyTables -Dir $dir)) {
            Set-LegacyMigrateFailure "The waiting copy could not be restored; it is kept at $(Get-ExakitTilde $dir)."
            return 1
        }
        [void](Write-LegacyRestoreReport -Dir $dir -Why "the new database already had them")
        Set-ExakitManifestValue "legacy.choice" "migrate"
        Set-ExakitManifestValue "legacy.crossing_done" $true
        Info "Run the command again for a fresh copy of what is in the container now."
        $script:LegacyMigrateStatus = "done"
        return 0
    }

    # THE PORT. The container's published port against the deployment's.
    $dsn = Get-LegacyDsn
    $port = $dsn.Substring($dsn.LastIndexOf(":") + 1)
    $dbPort = "" + (Get-PersonalDbPort)
    $script:LegacyMigrateClash = ($port -eq $dbPort)
    $dbRunning = Test-PersonalDeploymentRunning

    Write-Host ""
    Info "Copying the tables of the container '$container' ($engineName, $state) into your database."
    Info "The kit's bundled sample data is left out - the kit loads that itself. Nothing in the container is changed or removed."
    Info "One caveat worth knowing: a text column that held an empty string arrives as NULL."
    if ($script:LegacyMigrateClash -and $dbRunning) {
        Warn2 "The container publishes port $port, the port your database uses, so the two cannot run at once."
        Info "Your database is stopped while the tables are copied out, and started again before they are copied in."
    }
    if (-not $Yes) {
        if (-not (Confirm-ExakitPrompt "Go ahead?" $true)) {
            Info "Nothing was changed."
            $script:LegacyMigrateStatus = "declined"
            return 5
        }
    }

    if ($script:LegacyMigrateClash -and $dbRunning) {
        $script:ExakitActiveLabel = "Stopping your database for the copy"
        try { Stop-Personal } catch {
            Set-LegacyMigrateFailure "Your database could not be stopped, so the container cannot take the port." "exakit stop, then exakit migrate docker-nano"
            return 1
        }
        $script:LegacyMigrateDbStopped = $true
        # THE PORT MAY STILL BE HELD after the stop: the launcher can leave its
        # runner or its port forwarder alive. A moment's grace, and a port that
        # stays held is named for what it is, not blamed on the container.
        # Twin of the same check in legacy_migrate_now.
        if (-not (Wait-LegacyPortFree -Port ([int]$port) -Seconds 20)) {
            try { Start-Personal } catch { }
            Set-LegacyMigrateFailure "Your database was told to stop, but port $port is still held, so the old container cannot take it." "exakit stop, then check the port (netstat -ano | findstr :$port) before: exakit migrate docker-nano"
            return 1
        }
    }
    if ($state -ne "running") {
        Info "Starting the container '$container'"
        if (-not (Start-LegacyContainer)) {
            if ($script:LegacyMigrateDbStopped) { try { Start-Personal } catch { } }
            Set-LegacyMigrateFailure "The container '$container' would not start (see '$engineName logs $container')."
            return 1
        }
        $script:LegacyMigrateStarted = $true
    }

    $ready = $false
    $why = ""
    if (-not (Write-LegacyProfile)) {
        $why = "The password of the old database is not on file. Pass it with --password-file <path> (a file holding only the password), or answer the prompt on a console."
    } else {
        $budget = 120
        if ($env:EXAKIT_LEGACY_READY_TIMEOUT) { $budget = [int]$env:EXAKIT_LEGACY_READY_TIMEOUT }
        if (-not $script:LegacyMigrateStarted) { $budget = 10 }
        $script:ExakitActiveLabel = "Waiting for the old database to answer"
        if (Wait-LegacyDbAnswers -Budget $budget) { $ready = $true }
        else { $why = "The old database did not answer within ${budget}s. Is the password right, and is $dsn where the container listens ('$engineName port $container')?" }
    }
    if (-not $ready) {
        [void](Restore-LegacyMigrateState)
        Set-LegacyMigrateFailure $why
        return 1
    }

    $tables = @(Get-LegacyTables)
    $total = $tables.Count
    Split-LegacyTables -Tables $tables
    $sample = @($script:LegacySampleTables).Count
    $own = @($script:LegacyOwnTables).Count
    if ($sample -gt 0) { Set-ExakitManifestValue "legacy.sample_left_out" $script:LegacySampleIds }
    if ($own -eq 0) {
        if ($sample -gt 0) {
            Info "The container holds $total table(s), all of them the kit's bundled sample data ($($script:LegacySampleIds)), unchanged - nothing of yours to copy."
            Info "The kit loads that data itself: exakit data-load"
        } else {
            Info "The old database has no tables in it - nothing to copy."
        }
        [void](Restore-LegacyMigrateState)
        Set-ExakitManifestValue "legacy.choice" "migrate"
        Set-ExakitManifestValue "legacy.crossing_done" $true
        $script:LegacyMigrateStatus = "nothing"
        return 0
    }

    Info "The container holds $total table(s)."
    if ($sample -gt 0) { Write-LegacySampleNote -Own $own -Sample $sample }
    # A copy that was restored before is spent; its files go before the new one
    # lands, or a smaller export would leave the old one's tail beside it.
    if (Test-Path $indexPath) { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    foreach ($k in @("legacy.restored", "legacy.restore_skipped", "legacy.restore_failed")) {
        try { Remove-ExakitManifestValue $k } catch { }
    }
    Info "Copying $own table(s) out of the old database"
    $exported = Export-LegacyTables -Dir $dir -Tables @($script:LegacyOwnTables)
    $script:LegacyExported = [int]("0" + (Get-ExakitManifestValue "legacy.exported"))
    if (-not $exported) {
        [void](Restore-LegacyMigrateState)
        Set-LegacyMigrateFailure "Nothing could be copied out. The old database is untouched; nothing is lost."
        return 1
    }
    Set-ExakitManifestValue "legacy.export_dir" $dir
    Ok "Copied $($script:LegacyExported) table(s) out; they are saved at $(Get-ExakitTilde $dir)"

    if (-not (Restore-LegacyMigrateState)) {
        Set-LegacyMigrateFailure "Your database did not come back, so the copy is not restored yet. It is kept at $(Get-ExakitTilde $dir)." "exakit start, then exakit migrate docker-nano"
        return 1
    }
    Info "Restoring your data into the new database"
    if (-not (Import-LegacyTables -Dir $dir)) {
        Set-LegacyMigrateFailure "Your data could not be restored. The copy is kept at $(Get-ExakitTilde $dir)." "exakit migrate docker-nano"
        return 1
    }
    Set-ExakitManifestValue "legacy.choice" "migrate"
    Set-ExakitManifestValue "legacy.crossing_done" $true
    Set-ExakitManifestValue "legacy.migrated_at" (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    if (Write-LegacyRestoreReport -Dir $dir -Why "the new database already had them") {
        $script:LegacyMigrateStatus = "done"
        return 0
    }
    $script:LegacyMigrateStatus = "partial"
    $script:LegacyMigrateReason = "$($script:LegacyRestoreFailed) table(s) did not restore"
    $script:LegacyMigrateRemedy = "exakit migrate docker-nano"
    return 1
}
