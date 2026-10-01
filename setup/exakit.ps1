# exakit.ps1 - lifecycle helper for the Exasol Personal Local Starter Kit
# (Windows / PowerShell path). Mirrors setup/exakit function-for-function.
#
# usage: exakit <command> [args]
#
#   preflight            check this machine's requirements, install nothing
#   status                show what is installed and whether it is healthy
#   version               kit source, install date, and every component's
#                         installed version beside the advertised one
#   update [what] [-Yes]  apply the advertised versions without deleting database
#                         data. A runtime change stops the database, so on a
#                         console it is offered ("stop the database and update it
#                         now?") and applied on yes; without a console it is
#                         deferred unless -Yes (or EXAKIT_CONFIRM_RUNTIME_UPDATE=1)
#                         says otherwise
#   info [--json]         print the connection details panel; --json prints the
#                         install record (manifest.json) plus the state keys
#                         installed / status / remedy / skills, nothing else
#   guide                 friendly walkthrough: connect AI clients (MCP), SQL
#                         clients (DBeaver, DbVisualizer), and Python (pyexasol)
#   start                 start the local database and every add-on service
#   stop                  stop them again
#   autostart             whether everything comes back after a restart; shows
#                         the current state and asks whether to change it
#   data-load [-Force|<path>]
#                         open focused data loading options; a file path loads that
#                         file, a FOLDER path bulk-loads every CSV/Parquet file in
#                         it (one table each); -Force reloads bundled datasets
#   migrate docker-nano [--container NAME] [--engine docker|podman]
#                         [--dsn HOST:PORT] [--user USER] [--password-file PATH]
#                         [--yes] [--json]
#                         copy the tables of an older kit's container database
#                         (Exasol Nano in Docker or Podman) into this database;
#                         the kit's own sample data is left out and the
#                         container is never removed
#   sql '<statement>' [--file PATH] [--write] [--json]
#                         run one SQL statement and translate the error into a
#                         remedy; reads only unless --write. Uses the ADMIN
#                         connection (the read-only boundary is the MCP user)
#   repair-runtime [--yes] [--json]
#                         rebuild the database from empty when it will not
#                         start. DESTROYS every table in it; the bundled sample
#                         datasets are reloaded afterwards, anything you loaded
#                         is not. Declining exits 5 and changes nothing
#   mcp-setup             permanently configure MCP in supported AI clients
#   mcp-doctor [clients]  check MCP config, connectivity, and managed state
#   mcp-status [clients]  show managed MCP state for the supported AI clients
#   mcp-remove <client> [<client>...]
#                         take the kit's managed MCP entries out of the named
#                         clients and forget them, so mcp-doctor stops
#                         reporting a client that is no longer on this machine
#   skills [--json]       list the kit's AI skills and whether each one has
#                         reached the agents' discovery folders
#   skills-install        install the kit's AI skills for CLI agents
#                         (~\.claude\skills, ~\.agents\skills)
#   marketplace           browse optional add-ons (dash-server, ...) and install
#                         the ones you select; installed add-ons then update
#                         through `exakit update` like every other component
#   upgrade-kit2          add the Kit 2 trust assets (bash paths only for now)
#   rollback-kit2         remove what upgrade-kit2 added (bash paths only for now)
#   uninstall [<addon-id>] [-Yes] [-DryRun]
#                         with no add-on id: remove EVERYTHING the kit
#                         installed - database + all data, MCP client configs,
#                         skills, exapump, the kit home and the CLI binaries.
#                         Name a marketplace add-on to remove just that one
#                         (its service, binary and credential; user content
#                         such as dash-server dashboards is kept).
#                         -DryRun previews; -Yes skips the typed confirmation
#   whats-new [version]   what changed in this kit version
#   logs [target]         every log the kit can show; no target lists them
#                         (-f follows, --lines N, --path prints the path)
#   catalog [search]      browse/search every exakit, exapump & exasol command
#   help                  this text
#
# Installed to %USERPROFILE%\.local\bin by setup-windows.ps1; also
# runs straight from a repo checkout (setup\exakit.ps1).

param(
    [Parameter(Position = 0)][string]$Command = "help",
    [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$RestArgs = @()
)

$ErrorActionPreference = "Stop"

# Set by the machine-readable paths (`info --json`) so the update notice at the
# bottom of the dispatcher stays off stdout and the output remains parseable.
$script:JsonOutput = $false
# An exit code a command decided on but must not exit with yet - the update
# notice at the bottom of the dispatcher still has to print. 0 means "nothing
# pending"; see the `info` arm.
$script:PendingExitCode = 0

# --- locate the kit's lib directory -----------------------------------------
$scriptDir = Split-Path -Parent $PSCommandPath
if (Test-Path (Join-Path $scriptDir "lib\exakit-common.ps1")) {
    $libDir = Join-Path $scriptDir "lib"
} else {
    $fallbackHome = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME ".exasol-starter-kit" }
    $fallbackLib = Join-Path $fallbackHome "kit\setup\lib"
    if (Test-Path (Join-Path $fallbackLib "exakit-common.ps1")) {
        $libDir = $fallbackLib
    } else {
        Write-Host "exakit: cannot find the kit library (looked in $scriptDir\lib and $fallbackHome\kit)" -ForegroundColor Red
        exit 1
    }
}

. (Join-Path $libDir "exakit-common.ps1")
. (Join-Path $libDir "runtime-personal.ps1")
. (Join-Path $libDir "exapump.ps1")
# The crossing module: `exakit migrate docker-nano` is its after-the-install
# road, and `exakit status` reads what it remembered about the old database.
if (Test-Path (Join-Path $libDir "legacy-crossing.ps1")) { . (Join-Path $libDir "legacy-crossing.ps1") }
. (Join-Path $libDir "mcp.ps1")
# pyexasol is an update target of its own (and its own repair command), so the
# CLI needs the module even though it takes no part in the runtime commands.
. (Join-Path $libDir "pyexasol.ps1")
# Marketplace add-on modules: the CLI is where they are installed (exakit
# marketplace) and updated (exakit update <addon>). A missing file only makes
# the marketplace row unavailable - it must not break every other command.
if (Test-Path (Join-Path $libDir "dash-server.ps1")) { . (Join-Path $libDir "dash-server.ps1") }
if (Test-Path (Join-Path $libDir "dbt-exasol.ps1")) { . (Join-Path $libDir "dbt-exasol.ps1") }
if (Test-Path (Join-Path $libDir "exasol-vscode.ps1")) { . (Join-Path $libDir "exasol-vscode.ps1") }
if (Test-Path (Join-Path $libDir "json-tables.ps1")) { . (Join-Path $libDir "json-tables.ps1") }
if (Test-Path (Join-Path $libDir "exasol-scheduler.ps1")) { . (Join-Path $libDir "exasol-scheduler.ps1") }
if (Test-Path (Join-Path $libDir "help.ps1")) { . (Join-Path $libDir "help.ps1") }


# Assert-ExakitInstalled [-Json] - the install gate every command runs first.
# Twin of _require_install, INCLUDING THE EXIT CODES: 4 when there is no
# install record and 3 when there is one with no runtime yet, the same pair
# every state query answers with. A bare Fail exited 1, a code the contract
# does not document at all, and left stdout empty on the -Json path.
function Assert-ExakitInstalled {
    param([switch]$Json)
    if (-not (Test-Path $script:ManifestPath)) {
        if ($Json) {
            Write-Output ([pscustomobject]@{
                ok = $false; installed = $false; status = "not installed"
                error = "no installation found"; remedy = (Get-ExakitInstallCommand)
            } | ConvertTo-Json -Compress)
        } else {
            Write-Host "No installation found. Run the installer first: $(Get-ExakitInstallCommand)"
        }
        exit 4
    }
    if (-not (Get-RuntimeType)) {
        # `status --json` answers installed: true / "no database" / exit 3 for
        # this same machine state; two state queries may not disagree on it.
        if ($Json) {
            Write-Output ([pscustomobject]@{
                ok = $false; installed = $true; status = "no database"
                error = "no runtime recorded in the manifest yet"
                remedy = (Get-ExakitInstallCommand)
                remedy_hint = "the installer resumes at the unfinished step"
            } | ConvertTo-Json -Compress)
        } else {
            Write-Host "No runtime recorded in the manifest yet - re-run the installer, it resumes at the unfinished step: $(Get-ExakitInstallCommand)"
        }
        exit 3
    }
}

# Get-ExakitLoadedDatasets - the bundled datasets that are loaded. Twin of
# exakit_loaded_datasets.
#
# THE DATABASE IS ASKED FIRST. The manifest alone reported three loaded datasets
# against a database with zero schemas after a destroy+redeploy - the worst
# possible answer for an agent rebuilding its bearings after a context reset,
# because it sends it straight into "object not found" with the real cause
# recorded nowhere. Get-ExakitVerifiedDatasets checks the marker tables and heals
# the flags; it lives in exapump.ps1, which the CLI loads conditionally, and it
# returns $null when the database is unreachable. Either way the manifest read
# below is the fallback, never the first answer.
function Get-ExakitLoadedDatasets {
    # Which source answered: "database" when the marker tables were checked,
    # "manifest" when the database could not be reached and the record stood in.
    # status --json carries it as datasets_source, so a list answered off the
    # manifest while the database is down is not mistaken for a verified one.
    $script:ExakitDatasetsSource = "manifest"
    if (Get-Command Get-ExakitVerifiedDatasets -ErrorAction SilentlyContinue) {
        $verified = Get-ExakitVerifiedDatasets
        if ($null -ne $verified) { $script:ExakitDatasetsSource = "database"; return @($verified) }
    }
    $datasets = Get-ExakitManifestValue "data.datasets"
    if (-not $datasets) { return @() }
    $loaded = @()
    foreach ($property in $datasets.PSObject.Properties) {
        if ($property.Value -and $property.Value.loaded) { $loaded += $property.Name }
    }
    return ($loaded | Sort-Object)
}

# Invoke-CmdStatus [-Json] - what is installed and whether it is up. Twin of
# cmd_status, including THE EXIT CODE CONTRACT (agents branch on it, not on
# prose): 0 running, 3 installed but not running, 4 not installed.

# Write-ExakitNotInstalledAnswer [-Json] - the not-installed answer for a STATE
# QUERY, and it exits 4. Twin of _not_installed_answer. A bare Fail here fails
# an agent twice over: it exits 1 where the documented contract says 4, and it
# leaves stdout empty, so a caller piping -Json into a parser gets a decode
# error on precisely the path where structured signal decides the next action.
function Write-ExakitNotInstalledAnswer {
    param([switch]$Json)
    if ($Json) {
        Write-Output ([pscustomobject]@{
            installed = $false
            status    = "not installed"
            manifest  = $script:ManifestPath
            reason    = "no install record"
            # A RUNNABLE COMMAND, never a sentence: AGENTS.md tells the agent to
            # run whatever `remedy` holds, and "run the installer" is not
            # something a shell can execute. Twin of the same key in
            # _not_installed_answer.
            remedy    = (Get-ExakitInstallCommand)
        } | ConvertTo-Json -Compress)
    } else {
        Write-Host "Not installed (no manifest at $script:ManifestPath). Run the installer first: $(Get-ExakitInstallCommand)"
    }
    exit 4
}

function Invoke-CmdStatus {
    param([switch]$Json)
    if (-not (Test-Path $script:ManifestPath)) {
        Write-ExakitNotInstalledAnswer -Json:$Json
    }
    # Each phase names what it is waiting on. The database round trip is the
    # slow one, and "Checking the database" is a different experience from a
    # blank line for two seconds.
    $type = Get-RuntimeType
    $status = Invoke-ExakitWithSpinner -Quiet:$Json -Label "Checking the database" -Body {
        # NO RUNTIME RECORDED is a state the kit knows exactly, not an unknown:
        # the installer has not reached its runtime step, so no database is
        # deployed. "unknown" is in no documented status vocabulary and matched
        # none of the arms downstream, so the screen fell through to "Start it:
        # exakit start" - a command that in this state can only fail. Twin of
        # the same case in cmd_status.
        switch ($type) { "personal" { Get-PersonalStatus } default { "not installed" } }
    }
    $running = "$status".StartsWith("running")
    $steps = @(Get-ExakitManifestValue "steps_completed")
    # An install in progress is its own state: Begin-ExakitStep records the step
    # and the setup script clears it when done. Twin of the same read in cmd_status.
    $installStep = "$(Get-ExakitManifestValue 'install.current_step')"
    # Both have to agree - the step in the manifest AND a live pid in the lock -
    # or a crashed install reads as "installing" forever, with the re-run remedy
    # suppressed. Twin of cmd_status.
    $installing = ($installStep -ne "" -and -not ($steps -contains "exakit_helper") -and (Test-ExakitInstallRunning))
    # A step recorded with no live installer behind it: the install stopped there.
    $installStopped = ($installStep -ne "" -and -not $installing -and -not ($steps -contains "exakit_helper"))
    # Steps the installer recorded as not finished (a failed data load, a skipped
    # client wiring), each with the command that finishes it.
    $softRecords = Get-ExakitManifestValue "install.soft_failures"
    $datasets = @(Invoke-ExakitWithSpinner -Quiet:$Json -Label "Checking which datasets are loaded" -Body {
        ,@(Get-ExakitLoadedDatasets)
    })
    $pyexasol = Get-ExakitComponentCurrent "pyexasol"
    # Why the last run stopped, read off disk rather than out of this process:
    # the install that failed was a different process, and its reason is the one
    # an agent needs here. Twin of the .last-failure read in cmd_status.
    $failureNote = Read-ExakitFailureNote
    # What the crossing remembered about an older kit's container database, if
    # anything: where it is, what was answered, whether its tables landed.
    $legacyContainer = "" + (Get-ExakitManifestValue "legacy.container")
    $legacyEngine = "" + (Get-ExakitManifestValue "legacy.engine")
    $legacyChoice = "" + (Get-ExakitManifestValue "legacy.choice")
    $legacyRestored = "" + (Get-ExakitManifestValue "legacy.restored")
    $legacySample = "" + (Get-ExakitManifestValue "legacy.sample_left_out")
    $services = @{}
    # A service that knows its address says so through the registry's UrlFn, and
    # the JSON carries it - an agent could not get dash-server's URL from any
    # machine-readable surface before this. Twin of the `urls` map in cmd_status.
    $serviceUrls = @{}
    Invoke-ExakitWithSpinner -Quiet:$Json -Label "Checking the add-on services" -Body {
        foreach ($svcId in (Get-ExakitServiceIds)) {
            if ($svcId -eq "database") { continue }
            $services[$svcId] = (Get-ExakitServiceStatus -Id $svcId)
            $svcUrl = Get-ExakitServiceUrl -Id $svcId
            if ($svcUrl) { $serviceUrls[$svcId] = $svcUrl }
        }
    } | Out-Null

    if ($Json) {
        $installCmd = Get-ExakitInstallCommand
        # "installed: true" beside "status: not installed" was one object
        # contradicting itself: `installed` answers for the KIT, the runtime
        # string answers for the DATABASE. The kit-level word is "no database";
        # the verbatim runtime string stays under runtime.status. Twin of
        # top_status in cmd_status.
        $statusWord = $status
        if ($installing) { $statusWord = "installing" }
        elseif ("$status".StartsWith("not installed")) { $statusWord = "no database" }
        # Remedies are additive, one per component that needs one. Twin of the
        # map in cmd_status: a step the installer never finished names its
        # repair here, so a session that picks the machine up after a crashed
        # install sees more than "running".
        #
        # EVERY REMEDY IS A RUNNABLE COMMAND. AGENTS.md says "when remedy is not
        # null, run it", so an English sentence at that key breaks the contract
        # the same document promises. The prose moves to remedy_hints, same keys.
        $remedies = [ordered]@{}
        $remedyHints = [ordered]@{}
        if (-not $pyexasol) { $remedies["pyexasol"] = "exakit update" }
        if (-not $running) {
            # With NO runtime deployed, "exakit start" has nothing to start and
            # fails identically every time - only the installer creates one.
            if ("$status".StartsWith("interrupted")) {
                $remedies["database"] = "exakit repair-runtime"
                $remedyHints["database"] = "this DESTROYS the database and its data - ask the user, then pass --yes"
            } elseif ("$status".StartsWith("not installed")) {
                $remedies["database"] = $installCmd
                $remedyHints["database"] = "no database is deployed; the installer resumes at the unfinished step"
            } else {
                $remedies["database"] = "exakit start"
            }
        }
        if ($installing) {
            $remedies["install"] = "exakit status --json"
            $remedyHints["install"] = "the installer is still running (step: $installStep) - poll the remedy until status is running"
        } elseif ($installStopped) {
            $remedies["install"] = $installCmd
            $remedyHints["install"] = "the installer died at step '$installStep' - re-running resumes there"
        }
        if ($softRecords) {
            foreach ($property in @($softRecords.PSObject.Properties)) {
                $repair = "$($property.Value.repair)"
                if ($repair -and -not $remedies.Contains($property.Name)) { $remedies[$property.Name] = $repair }
            }
        }
        $stepsMissing = @()
        if (-not $installing) {
            # $null means "the installer's own command", resolved below, with the
            # resume note as the HINT rather than inside the remedy.
            $stepRemedies = @(
                @("launcher", $null),
                @("runtime", $null),
                @("exapump", $null),
                @("mcp", "exakit mcp-setup"),
                @("pyexasol", "exakit update"),
                @("exakit_helper", $null)
            )
            foreach ($pair in $stepRemedies) {
                if (-not ($steps -contains $pair[0])) {
                    $stepsMissing += $pair[0]
                    if (-not $remedies.Contains($pair[0])) {
                        if ($null -eq $pair[1]) {
                            $remedies[$pair[0]] = $installCmd
                            $remedyHints[$pair[0]] = "this install step never finished; the installer resumes at it"
                        } else {
                            $remedies[$pair[0]] = $pair[1]
                        }
                    }
                }
            }
        }
        $topRemedy = $null
        if ($remedies.Contains("install")) { $topRemedy = $remedies["install"] }
        elseif ($remedies.Contains("database")) { $topRemedy = $remedies["database"] }
        elseif ($stepsMissing.Count -gt 0) { $topRemedy = $remedies[$stepsMissing[0]] }
        elseif ($softRecords) {
            foreach ($property in @($softRecords.PSObject.Properties)) {
                if (-not $topRemedy -and $property.Value.repair) { $topRemedy = "$($property.Value.repair)" }
            }
        }
        $payload = [ordered]@{
            installed       = $true
            status          = $statusWord
            installing      = $installing
            install_step    = $(if ($installing -or $installStopped) { $installStep } else { $null })
            remedy          = $topRemedy
            kit_level       = "$(Get-ExakitManifestValue 'kit_level')"
            runtime         = [ordered]@{ type = $type; status = $status }
            running         = $running
            services        = $services
            # Per-service addresses, from each module's own UrlFn hook: the JSON
            # key an agent reads for "where is dash-server?" instead of scraping
            # the human screen. Twin of `urls` in cmd_status.
            urls            = $serviceUrls
            # REALITY, NOT THE RECORDED INTENT - see Test-ExakitAutostartAll.
            autostart       = (Test-ExakitAutostartAll)
            datasets_loaded = $datasets
            datasets_source = $script:ExakitDatasetsSource
            steps_completed = $steps
            steps_missing   = $stepsMissing
            pyexasol        = $(if ($pyexasol) { "$pyexasol" } else { $null })
            remedies        = $remedies
            # Prose that EXPLAINS a remedy, same keys: the remedy itself stays a
            # runnable command, per the AGENTS.md contract. Twin of remedy_hints.
            remedy_hints    = $remedyHints
            # Both keys, always. A reason with no date cannot be told from a
            # current one, and an undated note that outlived its cause is exactly
            # how a healthy machine comes to look broken - which is why the note
            # carries the timestamp on its second line.
            last_failure    = $(if ($failureNote.reason) { $failureNote.reason } else { $null })
            last_failure_at = $(if ($failureNote.at) { $failureNote.at } else { $null })
            manifest        = $script:ManifestPath
        }
        # An older kit's container database, as the crossing recorded it. Only
        # present when there is one: `copied` says whether its tables are in this
        # database, and `command` is the runnable way to bring them across while
        # they are not. Not a remedy - nothing is broken - so it lives here rather
        # than in `remedies`. Twin of legacy_database in cmd_status.
        if ($legacyContainer) {
            # `copied` is what has LANDED, not what was chosen: a migrate answered
            # mid-install has its tables copied out but not restored until the
            # run's end. The command is the one that finishes it - the installer's
            # own re-run for a copy the install still owes, migrate for a skip.
            $legacyCopied = [bool]$legacyRestored
            $legacyCommand = $null
            if (-not $legacyCopied -and $legacyChoice -eq "skip") { $legacyCommand = "exakit migrate docker-nano" }
            elseif (-not $legacyCopied -and $legacyChoice -eq "migrate") { $legacyCommand = $installCmd }
            $payload["legacy_database"] = [ordered]@{
                container       = $legacyContainer
                engine          = $(if ($legacyEngine) { $legacyEngine } else { $null })
                choice          = $(if ($legacyChoice) { $legacyChoice } else { $null })
                copied          = $legacyCopied
                restored_tables = $(if ("$legacyRestored" -match '^[0-9]+$') { [int]$legacyRestored } else { $null })
                sample_left_out = @($legacySample -split "," | Where-Object { $_ })
                command         = $legacyCommand
            }
        }
        $payload | ConvertTo-Json -Depth 4
        # 0 means healthy AND complete: while the installer runs, a poller that
        # reads the exit code must not see success off a half-built kit.
        if ($installing) { exit 3 }
        if ($running) { exit 0 } else { exit 3 }
    }

    # One label column for the whole screen. The pad was a hardcoded 11, but
    # "dash-server:" is 12, so every service row sat a column out of line - and
    # the registry can add longer ids than that. Measure instead of guessing.
    $lw = 12
    foreach ($svcId in $services.Keys) {
        if ($svcId -eq "database") { continue }
        if (($svcId.Length + 1) -gt $lw) { $lw = $svcId.Length + 1 }
    }
    function Write-StatusRow([string]$Label, [string]$Value) {
        Write-Host ($Label.PadRight($script:statusLabelWidth) + " " + $Value)
    }
    $script:statusLabelWidth = $lw

    # FOUR PANELS, NOT ONE LIST OF LABELS. Twin of cmd_status in setup/exakit.
    #
    # status answers "what is true right now". It used to answer that for the
    # runtime and nothing else: which add-ons are installed, which AI clients
    # are actually wired to the database, and how much data is in it were all
    # invisible, even though the manifest records every one of them.
    #
    # NOTHING HERE QUERIES THE DATABASE. Every value is read from the manifest
    # or from the service probes status already ran - process launches are what
    # made this screen slow, so the landscape got wider without getting slower.
    #
    # Versions are NOT here and paths are NOT here: `exakit version` owns the
    # first, `exakit info` owns the second.
    #
    # 17 fits the widest label printed, "Claude Code (CLI)".
    function Write-StatusPanelRow([string]$Label, [string]$Value) {
        Write-ExakitPanelLine ($Label.PadRight(17) + " " + $Value)
    }

    Start-ExakitPanel "Kit"
    $engine = Get-ExakitManifestValue "runtime.engine"
    $runtimeText = $(if ($type) { $type } else { "none" })
    if ($engine) { $runtimeText = "$runtimeText ($engine)" }
    # A runtime this kit does not have is not the same as a missing one, and
    # "nano - not installed" reads like a broken install rather than an
    # installation that predates the removal of the container runtime.
    if (Test-ExakitLegacyRuntimeRecorded) {
        Write-StatusPanelRow "Runtime" "$runtimeText - from an older kit, not managed here"
    } else {
        Write-StatusPanelRow "Runtime" "$runtimeText - $status"
    }
    # An older kit's container database that was copied out but not restored.
    # One that was skipped is NOT named: it is the user's answer, not an
    # unfinished job, and status is no place to keep re-asking it. `exakit
    # migrate docker-nano` still copies it when wanted. Twin of cmd_status.
    if ($legacyContainer -and -not $legacyRestored) {
        if ($legacyChoice -eq "migrate") {
            # Copied out, not yet restored: the install's second half does that,
            # so a re-run of the installer is what finishes it.
            Write-StatusPanelRow "Old database" "container '$legacyContainer' ($legacyEngine) - copied out, not yet restored; finish with: $(Get-ExakitInstallCommand)"
        }
    }
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    if (-not $dsn) { $dsn = "unknown" }
    if ($running) { $reach = "reachable" } else { $reach = "not reachable" }
    Write-StatusPanelRow "Database" "$dsn - $reach"
    # The install state, which the JSON has carried since the poll contract was
    # written and this screen never showed: it said "Start it: exakit start"
    # under a live installer.
    if ($installing) {
        Write-StatusPanelRow "Install" "in progress - step: $installStep (poll: exakit status --json)"
    } elseif ($installStopped) {
        Write-StatusPanelRow "Install" "did not finish at step: $installStep - re-run the installer"
    }
    if ($failureNote.reason) {
        $noteText = "$($failureNote.reason)"
        if ($noteText.Length -gt 60) { $noteText = $noteText.Substring(0, 57) + "..." }
        Write-StatusPanelRow "Last failure" "$noteText ($($failureNote.at))"
    }
    # "enabled"/"disabled", not "on"/"off": this row reports a STATE, and on/off
    # reads as the switch you flip rather than the position it is in. The
    # The command itself takes no verb: it shows this state and asks.
    if (Test-ExakitAutostartAll) {
        Write-StatusPanelRow "Autostart" "enabled"
    } else {
        Write-StatusPanelRow "Autostart" "disabled - change it with: exakit autostart"
    }
    # "Kit level" is an internal schema number. It means nothing to the person
    # reading this screen, and `exakit version` carries what they do want.
    # NOT the install date: `exakit version` already prints it.
    Complete-ExakitPanel
    Write-Host ""

    # --- add-ons ------------------------------------------------------------
    Start-ExakitPanel "Add-ons"
    $installedAddons = @()
    $absentAddons = @()
    foreach ($entry in (Get-ExakitMarketplaceAddons)) {
        # The PowerShell registry yields HASHTABLES with an Id field - it is NOT
        # the "id|label" string its bash twin returns. Stringifying one and
        # splitting on "|" produced the whole hashtable as the id, which matched
        # no add-on, so a kit with three installed reported none and printed the
        # entire registry as "available".
        $addonId = "$($entry.Id)"
        if (-not $addonId) { continue }
        if (Test-ExakitMarketplaceAddonInstalled $addonId) {
            $state = "installed"
            # A service add-on reports the state it is really in.
            foreach ($svcId in $services.Keys) {
                if ($svcId -ne $addonId) { continue }
                $state = $services[$svcId]
                $port = Get-ExakitManifestValue ("components." + ($addonId -replace '-', '_') + ".port")
                if ($port) { $state = "$state - http://127.0.0.1:$port" }
            }
            $installedAddons += @{ Id = $addonId; State = $state }
        } else {
            $absentAddons += $addonId
        }
    }
    if ($installedAddons.Count -gt 0) {
        foreach ($a in $installedAddons) { Write-StatusPanelRow $a.Id $a.State }
    } else {
        Write-StatusPanelRow "none" "add one with: exakit marketplace"
    }
    # What you could add is half of "what is my kit".
    if ($absentAddons.Count -gt 0) {
        Write-StatusPanelRow "available" ($absentAddons -join ", ")
    }
    Complete-ExakitPanel
    Write-Host ""

    # --- AI clients ---------------------------------------------------------
    # The whole point of the kit is an AI client that can query the database,
    # and status never said whether one was connected.
    Start-ExakitPanel "AI clients (MCP)"
    $labels = @(
        @("claude_desktop", "Claude"), @("claude_code", "Claude Code (CLI)"),
        @("cursor", "Cursor"), @("codex", "Codex"),
        @("vscode_copilot", "GitHub Copilot"), @("gemini_cli", "Gemini CLI"),
        @("opencode", "OpenCode"), @("continue", "Continue")
    )
    $configured = @(Get-ExakitManifestValue "components.mcp_server.client_setup.configured_clients")
    if ($configured.Count -gt 0 -and $configured[0]) {
        # Only the clients that ARE connected. Eight rows of which five said
        # "not installed" answered a question nobody asked of a status screen -
        # what this machine does not have - and buried the three that matter.
        # `exakit mcp-setup` is where the full roster belongs, because there the
        # list IS the choice.
        $anyClient = $false
        foreach ($pair in $labels) {
            if ($configured -contains $pair[0]) {
                Write-StatusPanelRow $pair[1] "configured"
                $anyClient = $true
            }
        }
        # A record of configured clients that yields no configured ROW means
        # every one of them was skipped: say so rather than draw an empty panel.
        if (-not $anyClient) {
            Write-StatusPanelRow "none" "connect one with: exakit mcp-setup"
        }
    } else {
        Write-StatusPanelRow "none" "connect one with: exakit mcp-setup"
    }
    Complete-ExakitPanel
    Write-Host ""

    # --- data ---------------------------------------------------------------
    # Table and row counts come from the manifest, written when the dataset was
    # LOADED (the loader computes them anyway). Counting live would put two more
    # exapump launches on every status, and launches are what made it slow.
    Start-ExakitPanel "Data"
    if ($datasets.Count -gt 0) {
        foreach ($ds in $datasets) {
            $dsSchema = Get-ExakitManifestValue "data.datasets.$ds.schema"
            if (-not $dsSchema) { $dsSchema = $ds.ToUpper() }
            $dsTables = Get-ExakitManifestValue "data.datasets.$ds.tables"
            $dsRows = Get-ExakitManifestValue "data.datasets.$ds.rows"
            $detail = "loaded"
            if ($dsTables) {
                if ("$dsTables" -eq "1") { $unit = "table" } else { $unit = "tables" }
                $detail = "$dsTables $unit"
                if ($dsRows) { $detail = "$detail, $(Get-ExakitGroupedDigits $dsRows) rows" }
            }
            Write-ExakitPanelLine ("$ds".PadRight(11) + " " + "$dsSchema".PadRight(11) + " " + $detail)
        }
        # No "last load" row: the rows above already say what is in the
        # database, which is the question. Which of them arrived most recently
        # is not something anyone acts on.
    } else {
        Write-ExakitPanelLine "none loaded - load some with: exakit data-load"
    }
    Complete-ExakitPanel
    Write-Host ""

    # Every SOFT component, not just one. exapump, the MCP server and pyexasol
    # all install through the soft-step path, so ANY of them can be missing from
    # an install that finished, and the install-time report is long gone by the
    # time anyone types `exakit status`. This screen used to give pyexasol a
    # dedicated line and say nothing about the other two.
    #
    # steps_completed is gone from the human screen: raw data that reported
    # trouble only by omission. `status --json` still carries it untouched.
    # Mirrors cmd_status in setup/exakit.
    $softRows = @()
    foreach ($soft in @(
        @{ Id = "exapump";  Key = "components.exapump.validated";    Fix = "exakit update" },
        @{ Id = "mcp";      Key = "components.mcp_server.validated"; Fix = "exakit update" },
        @{ Id = "pyexasol"; Key = "components.pyexasol.validated";   Fix = "exakit update" }
    )) {
        # A manifest record is what says "this install attempted the component".
        if ($null -eq (Get-ExakitManifestValue $soft.Key)) { continue }
        if (Get-ExakitComponentCurrent $soft.Id) { continue }
        $softRows += ($soft.Id.PadRight(9) + " repair: " + $soft.Fix)
    }
    $softLabel = "Missing:"
    foreach ($row in $softRows) {
        Write-StatusRow $softLabel $row
        $softLabel = ""
    }
    if ($softRecords) {
        $softLabel = "Unfinished:"
        foreach ($property in @($softRecords.PSObject.Properties)) {
            Write-StatusRow $softLabel ("$($property.Name)".PadRight(11) + " retry: " + "$($property.Value.repair)")
            $softLabel = ""
        }
    }
    if ($installing) {
        Write-Host "Installing: step $installStep - poll: exakit status --json"
        exit 3
    }
    if ($installStopped) {
        Write-Host "Finish it:  $(Get-ExakitInstallCommand)   (it stopped at step: $installStep; completed steps are skipped)"
        # No "Start it" underneath: with no runtime recorded yet, `exakit start`
        # can only answer "No runtime recorded in the manifest yet" - the
        # installer is the one command that finishes this.
        if (-not $type) { exit 3 }
    }
    # No "Manifest:" row: an internal file path, on the last line of the screen,
    # that nothing on this screen asks the reader to open.
    if (-not $running) {
        # THE SCREEN NAMES THE SAME COMMAND THE JSON HOISTS INTO `remedy`. An
        # interrupted deployment cannot be started and a runtime that was never
        # deployed has nothing to start, so prescribing `exakit start` for
        # either is the loop the reader is already in. Twin of the case arms at
        # the end of cmd_status.
        if ("$status".StartsWith("interrupted")) {
            Write-Host "Repair it:  exakit repair-runtime   (replaces the database; its data is not recoverable)"
        } elseif ("$status".StartsWith("conflict")) {
            Write-Host "Free the port: another process is listening on the database port - stop it, then: exakit start"
        } elseif ("$status".StartsWith("not installed")) {
            Write-Host "Deploy it:  $(Get-ExakitInstallCommand)   (it resumes at the unfinished step)"
        } else {
            Write-Host "Start it:   exakit start"
        }
        exit 3
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Services and autostart (twin of the exakit_service_* set in common.sh)
# ---------------------------------------------------------------------------
# Every service answers the same three questions - running, start, stop - and
# add-ons opt in through the registry (StatusFn/StartFn/StopFn/AutostartFn), so
# `exakit start|stop|status` and the boot entry pick a new one up with no
# wiring here. Windows registers a Startup-folder entry per service.
function Get-ExakitServiceIds {
    $ids = @()
    if (Get-ExakitManifestValue "runtime.type") { $ids += "database" }
    foreach ($addonId in (Get-ExakitMarketplaceInstalledAddons)) {
        $addon = Get-ExakitMarketplaceAddon $addonId
        if ($addon -and $addon.PSObject.Properties["StatusFn"] -and
            (Get-Command $addon.StatusFn -ErrorAction SilentlyContinue)) { $ids += $addonId }
    }
    return $ids
}

function Get-ExakitServiceStatus {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -eq "database") {
        switch (Get-RuntimeType) {
            "personal" { return (Get-PersonalStatus) }
        }
        return "unknown"
    }
    $addon = Get-ExakitMarketplaceAddon $Id
    if ($addon -and (Get-Command $addon.StatusFn -ErrorAction SilentlyContinue)) { return (& $addon.StatusFn) }
    return "unknown"
}

# Get-ExakitServiceUrl - the address a service is reachable at, or "" when it
# has none. Optional registry hook (UrlFn), resolved the same generic way as
# StatusFn/StartFn, so a future add-on gets a `urls` row with no wiring here.
# Twin of the `url` convention hook that cmd_status resolves via _exakit_addon_fn.
function Get-ExakitServiceUrl {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -eq "database") { return "" }
    $addon = Get-ExakitMarketplaceAddon $Id
    if ($addon -and $addon.PSObject.Properties["UrlFn"] -and
        (Get-Command $addon.UrlFn -ErrorAction SilentlyContinue)) {
        try { return "$(& $addon.UrlFn)" } catch { return "" }
    }
    return ""
}

function Start-ExakitService {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -eq "database") { Confirm-ExakitRuntimeRunning -Deploy; return }
    $addon = Get-ExakitMarketplaceAddon $Id
    if ($addon -and $addon.PSObject.Properties["StartFn"] -and
        (Get-Command $addon.StartFn -ErrorAction SilentlyContinue)) { [void](& $addon.StartFn) }
}

function Stop-ExakitService {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -eq "database") {
        switch (Get-RuntimeType) {
            "personal" { Stop-Personal }
        }
        return
    }
    $addon = Get-ExakitMarketplaceAddon $Id
    if ($addon -and $addon.PSObject.Properties["StopFn"] -and
        (Get-Command $addon.StopFn -ErrorAction SilentlyContinue)) { [void](& $addon.StopFn) }
}


function Unregister-ExakitAutostart {
    param([Parameter(Mandatory)][string]$Id)
    $entry = Get-ExakitAutostartEntryPath -Id $Id
    if (Test-Path $entry) {
        Remove-Item -Force -ErrorAction SilentlyContinue $entry
        Ok "$Id`: no longer starts at login"
    }
}

# Test-ExakitAutostartAll - will this machine bring the kit back after a
# reboot? REALITY, NOT THE RECORDED INTENT.
#
# `status --json` and the status panel read the manifest's autostart.enabled,
# which is what the user last ASKED for. A machine whose boot entry had since
# gone therefore reported "autostart: true" for a database nothing would
# restart. On the container path that is routine rather than exotic:
# recreating the container drops its restart policy, so a stop/start cycle was
# enough to turn autostart off with the manifest still saying it was on.
#
# Same rule as Invoke-CmdAutostart: on means EVERY service is registered,
# because a partly-registered set will not bring the kit back. Twin of the
# loop in cmd_status (setup/exakit).
function Test-ExakitAutostartAll {
    $ids = @(Get-ExakitServiceIds)
    if ($ids.Count -eq 0) { return $false }
    foreach ($id in $ids) {
        if (-not (Test-ExakitAutostartRegistered -Id $id)) { return $false }
    }
    return $true
}

function Test-ExakitAutostartRegistered {
    param([Parameter(Mandatory)][string]$Id)
    if (Test-Path (Get-ExakitAutostartEntryPath -Id $Id)) { return $true }
    return $false
}

function Enable-ExakitAutostart {
    $any = $false
    foreach ($id in (Get-ExakitServiceIds)) {
        if (Register-ExakitAutostart -Id $id) { $any = $true }
    }
    Set-ExakitManifestValue "autostart.enabled" $any
    # One line, whatever the service count - the twin of the sentence
    # Disable-ExakitAutostart has always printed, and of the one in
    # exakit_autostart_enable.
    if ($any) { Ok "Automatic start after a restart is on." }
}

function Disable-ExakitAutostart {
    foreach ($id in (Get-ExakitServiceIds)) { Unregister-ExakitAutostart -Id $id }
    Set-ExakitManifestValue "autostart.enabled" $false
    Ok "Automatic start after a restart is off."
}

function Show-ExakitAutostart {
    # The same panel every other table in the kit uses, so the screens read as
    # one family. Box glyphs come from the ui palette - never spelled here,
    # because every .ps1 but ui.ps1 must stay pure ASCII.
    Write-Host ""
    # The name column is MEASURED, not assumed: service ids come from the
    # registry and an add-on may be added with a longer one. Twin of the _ap_w
    # walk in exakit_autostart_print.
    $w = 7
    foreach ($id in (Get-ExakitServiceIds)) { if ($id.Length -gt $w) { $w = $id.Length } }
    Start-ExakitPanel "Automatic start after a restart"
    Write-ExakitPanelLine (("{0,-$w}  {1}") -f "Service", "Status")
    foreach ($id in (Get-ExakitServiceIds)) {
        $state = if (Test-ExakitAutostartRegistered -Id $id) { "enabled" } else { "disabled" }
        Write-ExakitPanelLine (("{0,-$w}  {1}") -f $id, $state)
    }
    Complete-ExakitPanel
    Write-Host ""
    # No "turn it on with ..." line: the question that follows this panel IS the
    # way to change it, and naming two commands that no longer exist was how
    # this screen used to end.
}

# Invoke-CmdAutostart - one command: show where it stands, then offer to flip it.
#
# It was three ("on", "off", and a bare form that only reported), which made the
# reader pick the verb before being told what the current state even was - and
# the bare form then closed by explaining the other two. Now the answer comes
# first and the only decision left is yes or no.
#
# EXAKIT_AUTOSTART_CHANGE pre-answers it for automation, the same contract every
# other prompt in the kit uses; without a console the default is NO CHANGE, so a
# scripted run can never silently flip a boot setting.
# Twin of cmd_autostart in setup/exakit.
function Invoke-CmdAutostart {
    param([string]$Action = "")
    # Bad input first, before the install check. Twin of cmd_autostart.
    if ($Action) {
        # Deny, not Fail: this is bad input, and the shell twin answers it with
        # reject() - exit 2. Through Fail it exited 1, which AGENTS.md reserves
        # for a command that failed rather than a command that was misused, so
        # an agent scripting `exakit autostart off` from a document could not
        # even classify the refusal. Fail also recorded a .last-failure note,
        # which `exakit status --json` then reported as an unfinished install
        # step on a machine where nothing was wrong.
        Deny-ExakitInput "autostart takes no arguments - run 'exakit autostart' and answer the question."
    }
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    Show-ExakitAutostart

    $ids = @(Get-ExakitServiceIds)
    if ($ids.Count -eq 0) { return }
    $on = @($ids | Where-Object { Test-ExakitAutostartRegistered -Id $_ }).Count

    # "Everything is on" is the only state that offers to turn things off;
    # anything else - none of it, or some of it - offers to turn it all on,
    # because a partly-registered set is the one a reader wants made whole.
    if ($on -eq $ids.Count) {
        if (Confirm-ExakitEnvPrompt "EXAKIT_AUTOSTART_CHANGE" "Turn it off?" $false) {
            Disable-ExakitAutostart
        }
    } else {
        if (Confirm-ExakitEnvPrompt "EXAKIT_AUTOSTART_CHANGE" "Turn it on?" $false) {
            Enable-ExakitAutostart
        }
    }
}

function Invoke-CmdStart {
    Assert-ExakitInstalled
    # Logging first: launcher output belongs in the logfile, not interleaved
    # with the [ok] lines on stdout. Twin of the same fix in cmd_start.
    Initialize-ExakitLogging
    # Everything the kit runs, database first: self-heal semantics for the
    # runtime (a stopped one is started, a missing one created - `exakit start`
    # promises a running database), then every add-on service.
    if ((Get-RuntimeType) -eq "personal" -and (Test-PersonalDeploymentRunning)) {
        Ok "Database is already running"
    } elseif ((Get-RuntimeType) -eq "personal" -and (Get-PersonalStatus) -eq "conflict") {
        # Port open is not database up: with another program on the port this
        # said "already running" and exited 0 while status said stopped. Twin
        # of the same arm in cmd_start (setup/exakit).
        Fail "Port $(Get-PersonalDbPort) is held by another process, not by Exasol, so the database cannot start. Stop that process, then: exakit start"
    } else {
        Confirm-ExakitRuntimeRunning -Deploy
    }
    foreach ($id in (Get-ExakitServiceIds)) {
        if ($id -eq "database") { continue }
        Start-ExakitService -Id $id
    }
    # The database is up, so a note left by an earlier start that could not is
    # no longer true. Only a runtime note goes; an install-step note stays.
    try { if ((Get-ExakitRuntimeStatus) -like "running*") { Clear-ExakitRuntimeFailureNote } } catch { }
}

function Invoke-CmdStop {
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    # Add-on services first: they talk to the database, so they should be down
    # before it goes.
    foreach ($id in (Get-ExakitServiceIds)) {
        if ($id -eq "database") { continue }
        Stop-ExakitService -Id $id
    }
    switch (Get-RuntimeType) { "personal" { Stop-Personal } }
}

# Invoke-CmdRepairRuntime [-Yes] - rebuild a database that cannot be started.
#
# THE ESCAPE FROM A WEDGE. When a runtime is deployed but refuses to start, the
# installer used to skip its step as already done, fail at start, and close by
# advising a re-run that behaved the same way - a loop with no exit, and
# EXAKIT_REUSE_DB=0 never got a say because the skip happened first. Re-running
# the platform setup script IS the repair: the deployment step already knows how
# to try a start, watch it fail, and replace the deployment. Dropping the
# `runtime` tick first is what lets it be reached.
#
# DESTRUCTIVE: the deployment is replaced and its data is gone. Interactive runs
# are asked; -Yes and EXAKIT_CONFIRM_RUNTIME_REPAIR=1 pre-answer it.
# twin: cmd_repair_runtime in setup/exakit.
#
# EXIT 5 MEANS "NOT CONFIRMED, NOTHING WAS TOUCHED". Declining used to exit 0,
# so an agent handed remedies.database "exakit repair-runtime" ran it with no
# terminal, read a success code off a command that had deliberately done
# nothing, and re-polled status to find `interrupted` again - the loop AGENTS.md
# warns about, one command over. Twin of the same code in cmd_repair_runtime.
# Every bundled dataset's "loaded" record set to false, both keys, before a
# rebuild empties the database. Twin of exakit_reset_dataset_flags.
function Reset-ExakitDatasetFlags {
    if (-not (Get-Command Get-ExakitBundledDatasets -ErrorAction SilentlyContinue)) { return }
    foreach ($ds in @(Get-ExakitBundledDatasets)) {
        try {
            Set-ExakitManifestValue $ds.Flag $false
            Set-ExakitManifestValue "data.datasets.$($ds.Id).loaded" $false
        } catch { }
    }
}

function Invoke-CmdRepairRuntime {
    param([switch]$Yes, [switch]$Json)
    Assert-ExakitInstalled -Json:$Json
    $confirmed = [bool]$Yes
    if ($env:EXAKIT_CONFIRM_RUNTIME_REPAIR -eq "1") { $confirmed = $true }

    $kit = Get-ExakitRepoRoot
    if (-not $kit) { Fail "Could not find the kit copy to re-run setup from. Re-run the installer instead." }
    $setup = Join-Path $kit "setup\setup-windows.ps1"
    if (-not (Test-Path $setup)) { Fail "The kit copy at $kit has no setup\setup-windows.ps1. Re-run the installer instead." }

    # Narration never shares stdout with the JSON object.
    if ($Json) {
        [Console]::Error.WriteLine("  ! This rebuilds your database from empty. Every table in it is deleted and cannot be recovered.")
    } else {
        Warn2 "This rebuilds your database from empty. Every table in it is deleted and cannot be recovered."
        Info "The bundled sample datasets are reloaded afterwards. Anything you loaded yourself is not."
        # A format the kit can load back - see the note on the shell twin.
        # `exakit sql --json` emits an {"ok","rows","row_count"} envelope that
        # nothing here ingests, so the one rescue instruction printed before a
        # command that destroys the database produced a file its owner could
        # not restore from.
        Info "If the database still answers, copy out anything you want to keep first, one table at a time:"
        Info "  exapump sql -p $($script:ExapumpProfile) -f csv 'SELECT * FROM <SCHEMA>.<TABLE>' > <TABLE>.csv"
        Info "  ...and load it back afterwards with: exakit data-load <TABLE>.csv  (the file name becomes the table name, so keep it)"
    }
    if (-not $confirmed) {
        if (-not (Confirm-ExakitPrompt "Delete everything in the database and rebuild it empty?" $false)) {
            # DECLINING A DESTRUCTIVE PROMPT IS THE SAFE ANSWER, not an error.
            # Fail() rendered it as a red error card and exited 1 - and it
            # records the reason as the last failure, so `exakit status --json`
            # then reported one on a machine where nothing had gone wrong.
            # Nothing is recorded here either - but the code is 5, not 0: "you
            # did not confirm" is not "it is repaired". Twin of the same branch
            # in cmd_repair_runtime (setup/exakit).
            if ($Json) {
                [ordered]@{
                    ok = $false; status = "declined"; reason = "not confirmed"; changed = $false
                    remedy = "exakit repair-runtime --yes"
                    remedy_hint = "this DESTROYS the database and its data - ask the user before running it"
                } | ConvertTo-Json -Compress | Write-Output
            } else {
                Info "Repair cancelled - nothing was changed."
                Info "When you are ready: exakit repair-runtime --yes (or set EXAKIT_CONFIRM_RUNTIME_REPAIR=1)"
            }
            exit 5
        }
    }

    Initialize-ExakitLogging
    # Drop the tick so the deployment step runs even on a runtime whose wedged
    # state the kit cannot yet recognise on its own.
    Remove-ExakitStepDone "runtime"
    # AND THE DATASET FLAGS: the rebuilt database is empty, and the data step
    # trusts the record whenever the database cannot be asked - which a database
    # that came up seconds ago sometimes cannot. Twin of exakit_reset_dataset_flags.
    Reset-ExakitDatasetFlags
    Info "Re-running setup\setup-windows.ps1 to rebuild the database"
    $env:EXAKIT_BANNER_SHOWN = "1"
    # The deployment step must NOT offer to reuse what is there: its reuse
    # question defaults to YES, so a repair the user had just confirmed as
    # destructive answered itself with "keep the existing database".
    # Twin of the same export in cmd_repair_runtime (setup/exakit).
    $env:EXAKIT_REUSE_DB = "0"
    if ($Json) {
        # One object on stdout and nothing else: the rebuild's own narration is
        # routed to stderr. Twin of the --json branch in cmd_repair_runtime.
        # The rebuild narrates to stderr by design, and under
        # $ErrorActionPreference = "Stop" a native command's stderr is a
        # TERMINATING error before $LASTEXITCODE can be read - so a repair that
        # printed one warning and then succeeded would have surfaced as an
        # unhandled crash, on the one command whose whole job is answering
        # ok/changed as JSON. Same window as Invoke-ExakitLogged.
        $repairCode = 1
        $prevRepairEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $setup 2>&1 | ForEach-Object { [Console]::Error.WriteLine("$_") }
            $repairCode = $LASTEXITCODE
        } catch {
            [Console]::Error.WriteLine("$_")
            $repairCode = 1
        } finally {
            $ErrorActionPreference = $prevRepairEap
        }
        if ($repairCode -eq 0) {
            [ordered]@{ ok = $true; status = "repaired"; changed = $true; remedy = $null } |
                ConvertTo-Json -Compress | Write-Output
            exit 0
        }
        [ordered]@{
            ok = $false; status = "failed"; changed = $true
            reason = "the rebuild did not finish (see exakit logs)"
            remedy = (Get-ExakitInstallCommand)
        } | ConvertTo-Json -Compress | Write-Output
        exit 3
    }
    # Same window as the --json branch above: the rebuild narrates, some of it
    # to stderr, and under "Stop" that ends the CLI with "Unexpected error"
    # instead of the setup script's own exit code.
    $prevRepairEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $setup
        $repairCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevRepairEap
    }
    exit $repairCode
}

# Invoke-CmdMigrate docker-nano [options] - the after-the-install road of the
# legacy crossing (setup\lib\legacy-crossing.ps1, Invoke-LegacyMigrateNow).
#
# Twin of cmd_migrate in setup/exakit; its header carries the whole rationale.
# The short version: the installer asks about an older kit's container database
# once, and this is for the machine that answered "skip" and wants the data
# after all, or whose container the installer never saw. What is not named on
# the command line comes from the record the crossing kept (legacy.*), then the
# old install's own record, then the machine, then an older kit's defaults.
#
# THE PASSWORD NEVER TRAVELS ON A COMMAND LINE: a file (--password-file, or the
# one an older kit recorded), EXAKIT_LEGACY_PASSWORD for a scripted run, or a
# prompt on a console. Exit codes: 0 done, 1 the copy did not finish, 2 bad
# input, 3 no deployment or no exapump, 4 not installed, 5 not confirmed.
function Invoke-CmdMigrate {
    param([string[]]$Arguments = @())
    $argv = @($Arguments)
    $json = ($argv -contains "--json" -or $argv -contains "-j")
    $usage = "exakit migrate docker-nano [--container NAME] [--engine docker|podman] [--dsn HOST:PORT] [--user USER] [--password-file PATH] [--yes] [--json]"
    # A refusal in JSON is an object with rejected: true and exit 2, the shape
    # `exakit sql` already answers with, so one parser reads both.
    function Deny-MigrateInput([string]$Msg) {
        if ($json) {
            [ordered]@{ ok = $false; error = $Msg; remedy = $null; rejected = $true } | ConvertTo-Json -Compress | Write-Output
            exit 2
        }
        Write-Host ""; Write-Host "  [x] $Msg"; exit 2
    }
    $source = ""
    if ($argv.Count -gt 0) { $source = "" + $argv[0] }
    $rest = @()
    if ($source -eq "docker-nano") { $rest = @($argv | Select-Object -Skip 1) }
    elseif (-not $source -or $source.StartsWith("-")) { Deny-MigrateInput "migrate needs a source. The one there is: $usage" }
    else { Deny-MigrateInput "Unknown migration source '$source' (known: docker-nano)." }

    $yes = $false; $container = ""; $engine = ""; $dsn = ""; $user = ""; $pwFile = ""
    for ($i = 0; $i -lt $rest.Count; $i++) {
        $a = "" + $rest[$i]
        $name = $a; $value = $null
        if ($a -match '^(--[a-z-]+)=(.*)$') { $name = $Matches[1]; $value = $Matches[2] }
        # A value flag takes the next token when it was not written as --flag=value.
        $takesValue = ($name -in @("--container", "--engine", "--dsn", "--user", "--password-file"))
        if ($takesValue -and $null -eq $value) { $i++; if ($i -lt $rest.Count) { $value = "" + $rest[$i] } else { $value = "" } }
        switch ($name) {
            "--container"     { if (-not $value) { Deny-MigrateInput "--container needs the container's name." }; $container = $value }
            "--engine"        { if (-not $value) { Deny-MigrateInput "--engine needs docker or podman." }; $engine = $value }
            "--dsn"           { if (-not $value) { Deny-MigrateInput "--dsn needs HOST:PORT." }; $dsn = $value }
            "--user"          { if (-not $value) { Deny-MigrateInput "--user needs a database user." }; $user = $value }
            "--password-file" { if (-not $value) { Deny-MigrateInput "--password-file needs a path." }; $pwFile = $value }
            "--password"      { Deny-MigrateInput "A password does not go on the command line, where every process can read it. Put it in a file and pass --password-file <path>, set EXAKIT_LEGACY_PASSWORD, or answer the prompt." }
            "--yes"           { $yes = $true }
            "-y"              { $yes = $true }
            "-Yes"            { $yes = $true }
            "--json"          { }
            "-j"              { }
            default           { Deny-MigrateInput "Unknown option '$a' for migrate (supported: --container, --engine, --dsn, --user, --password-file, --yes, --json)." }
        }
    }
    if ($engine -and $engine -notin @("docker", "podman")) { Deny-MigrateInput "--engine must be docker or podman, not '$engine'." }
    if ($dsn -and $dsn -notmatch ':[0-9]+$') { Deny-MigrateInput "--dsn must be HOST:PORT, e.g. 127.0.0.1:8563." }
    function Test-NonEmptyFile([string]$Path) { return ($Path -and (Test-Path $Path) -and (Get-Item $Path).Length -gt 0) }
    if ($pwFile -and -not (Test-NonEmptyFile $pwFile)) { Deny-MigrateInput "--password-file: $pwFile is missing or empty." }

    Assert-ExakitInstalled -Json:$json
    # One answer for a failure BEFORE the copy: the same three keys every state
    # query carries, exit 3 - the code for "installed, but not usable for this".
    function Deny-MigrateState([string]$Status, [string]$Msg, [string]$Remedy) {
        if ($json) {
            [ordered]@{ ok = $false; installed = $true; status = $Status; error = $Msg; remedy = $Remedy } | ConvertTo-Json -Compress | Write-Output
            exit 3
        }
        Write-ExakitError $Msg
        Info "Then: $Remedy"
        exit 3
    }
    if ((Get-RuntimeType) -ne "personal") {
        Deny-MigrateState "no database" "This install has no Exasol Personal deployment to copy into yet." (Get-ExakitInstallCommand)
    }
    if (-not (Get-Command Invoke-LegacyMigrateNow -ErrorAction SilentlyContinue)) {
        Fail "This kit copy has no setup\lib\legacy-crossing.ps1, which migrate runs. Re-run the installer to repair the copy."
    }

    # What was named, then what the crossing remembered (legacy.*), then the old
    # install's own record - runtime.* is only the OLD database's when the
    # record still says the runtime is a container - then the machine.
    $legacyRt = Test-ExakitLegacyRuntimeRecorded
    function Get-Remembered([string]$Key) { return "" + (Get-ExakitManifestValue "legacy.$Key") }
    function Get-OldRecord([string]$Key) { if ($legacyRt) { return "" + (Get-ExakitManifestValue "runtime.$Key") }; return "" }
    if (-not $container) { $container = Get-Remembered "container" }
    if (-not $container) { $container = Get-OldRecord "container" }
    if (-not $container) { $container = "exasol-nano" }
    $volume = Get-Remembered "volume"
    if (-not $volume) { $volume = Get-OldRecord "volume" }
    if (-not $user) { $user = Get-Remembered "user" }
    if (-not $user) { $user = Get-OldRecord "user" }
    if (-not $user) { $user = "sys" }
    $probeTimeout = 20
    if ($env:EXAKIT_ENGINE_PROBE_TIMEOUT) { $probeTimeout = [int]$env:EXAKIT_ENGINE_PROBE_TIMEOUT }
    if (-not $engine) { $engine = Get-Remembered "engine" }
    if (-not $engine) { $engine = Get-OldRecord "engine" }
    if (-not $engine) {
        # Whichever engine on this machine knows a container by that name.
        foreach ($candidate in @("docker", "podman")) {
            $bin = Get-Command $candidate -ErrorAction SilentlyContinue
            if (-not $bin) { continue }
            $probe = Invoke-ExakitBounded -FilePath $bin.Source -Arguments @("container", "inspect", $container) -TimeoutSeconds $probeTimeout
            if ($null -ne $probe -and "$probe".Trim() -ne "") { $engine = $candidate; break }
        }
        if (-not $engine) {
            Deny-MigrateState "no container" "Neither docker nor podman on this machine has a container named '$container'." "exakit migrate docker-nano --engine docker --container <name>   (list them with: docker ps -a, or podman ps -a)"
        }
    }
    if (-not $dsn) { $dsn = Get-Remembered "dsn" }
    if (-not $dsn) { $dsn = Get-OldRecord "dsn" }
    if (-not $dsn) {
        # The port the container publishes for 8563, as the engine reports it
        # ("127.0.0.1:8563", or "0.0.0.0:8563" - either way the host is local).
        $port = "8563"
        $engineBin = Get-Command $engine -ErrorAction SilentlyContinue
        if ($engineBin) {
            $portOut = "" + (Invoke-ExakitBounded -FilePath $engineBin.Source -Arguments @("port", $container, "8563/tcp") -TimeoutSeconds $probeTimeout)
            foreach ($line in ($portOut -split "`n")) {
                $line = $line.Trim()
                if ($line -and -not $line.StartsWith("[")) { $port = $line.Substring($line.LastIndexOf(":") + 1); break }
            }
        }
        if ($port -notmatch '^[0-9]+$') { $port = "8563" }
        $dsn = "127.0.0.1:$port"
    }
    # The password: a named file, the environment, the recorded file, the
    # credential an older kit kept, and last a prompt - on a console only.
    $script:LegacyPassword = ""
    $passwordFile = ""
    if ($pwFile) {
        $passwordFile = $pwFile
    } elseif (-not $env:EXAKIT_LEGACY_PASSWORD) {
        $pf = Get-Remembered "password_file"
        if (-not (Test-NonEmptyFile $pf)) { $pf = Get-OldRecord "password_file" }
        if (-not (Test-NonEmptyFile $pf)) { $pf = Join-Path $script:CredsDir "nano_sys_password" }
        if (Test-NonEmptyFile $pf) {
            $passwordFile = $pf
        } elseif ((-not $json) -and (Test-ExakitInteractive)) {
            Write-Host ("    ? Password of the {0} user in the old database (not shown): " -f $user) -NoNewline
            $secure = Read-Host -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { $script:LegacyPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if (-not $script:LegacyPassword) { Deny-MigrateInput "No password was given." }
        } else {
            Deny-MigrateState "no password" "The old database's password is not on file, and there is no console to ask on." "exakit migrate docker-nano --password-file <path>   (a file holding only the password; or set EXAKIT_LEGACY_PASSWORD)"
        }
    }
    # The module reads these; names and paths only, never the password itself.
    $env:EXAKIT_LEGACY_CONTAINER = $container
    $env:EXAKIT_LEGACY_ENGINE = $engine
    $env:EXAKIT_LEGACY_DSN = $dsn
    $env:EXAKIT_LEGACY_USER = $user
    if ($volume) { $env:EXAKIT_LEGACY_VOLUME = $volume }
    if ($passwordFile) { $env:EXAKIT_LEGACY_PASSWORD_FILE = $passwordFile }

    Initialize-ExakitLogging
    # The module returns its code on the success stream and narrates through the
    # host; the last integer is the code. Under --json the narration is routed
    # to stderr so stdout carries one object and nothing else.
    $prevEap = $ErrorActionPreference
    $rc = 1
    try {
        $ErrorActionPreference = "Continue"
        if ($json) {
            $items = @(Invoke-LegacyMigrateNow -Yes:$yes 6>&1)
            foreach ($item in $items) {
                if ($item -is [int]) { $rc = $item } else { [Console]::Error.WriteLine("$item") }
            }
        } else {
            foreach ($item in @(Invoke-LegacyMigrateNow -Yes:$yes)) { if ($item -is [int]) { $rc = $item } }
        }
    } finally {
        $ErrorActionPreference = $prevEap
        $script:LegacyPassword = ""
    }
    if ($json) {
        $st = $script:LegacyMigrateStatus
        if (-not $st) { $st = "failed" }
        $remedy = $null
        if ($script:LegacyMigrateRemedy) { $remedy = $script:LegacyMigrateRemedy }
        if ($st -eq "declined") { $remedy = "exakit migrate docker-nano --yes" }
        [ordered]@{
            ok              = ($st -in @("done", "nothing"))
            installed       = $true
            status          = $st
            container       = $container
            engine          = $engine
            dsn             = $dsn
            copied_out      = [int]$script:LegacyExported
            restored        = [int]$script:LegacyRestored
            left_alone      = [int]$script:LegacySkipped
            failed          = [int]$script:LegacyRestoreFailed
            sample_left_out = @($script:LegacySampleIds -split "," | Where-Object { $_ })
            reason          = $(if ($script:LegacyMigrateReason) { $script:LegacyMigrateReason } else { $null })
            remedy          = $remedy
        } | ConvertTo-Json -Compress | Write-Output
    }
    exit $rc
}

# Get-ExakitExapumpProfileDirs - every directory an exapump profile store could
# be sitting in on this machine, newest convention first.
#
# THE WRITER AND THE REMOVER USED TO DISAGREE. exapump.ps1 resolves its config
# from Get-ExakitProfileHome (%USERPROFILE%), because that is where exapump.exe
# itself looks; uninstall deleted $HOME\.exapump, because PowerShell's $HOME is
# what it had always used. On an ordinary machine the two are the same path and
# nothing showed. On a domain-joined machine with a redirected home they are
# not, and `exakit uninstall` reported success while leaving config.toml -- a
# file holding an ADMIN connection string -- on disk.
#
# Both are returned, deduplicated: the current location, and the legacy one an
# older kit on this same machine may have written. Twin note: the sh side has no
# equivalent, because $HOME is the only home a POSIX shell has.
function Get-ExakitExapumpProfileDirs {
    $dirs = @()
    foreach ($base in @((Get-ExakitProfileHome), $HOME)) {
        if (-not $base) { continue }
        $candidate = Join-Path $base ".exapump"
        if ($dirs -notcontains $candidate) { $dirs += $candidate }
    }
    return $dirs
}

# Invoke-ExakitUninstallRun -DryRun - remove every artifact the kit installs, in
# dependency order: the local database and ALL its data, the managed MCP client
# configs, the installed AI skills, the exapump profile, the kit home, and the
# CLI binaries. With -DryRun it prints the plan and changes nothing. Mirrors
# exakit_uninstall_run in setup/lib/common.sh. uv/uvx (a shared tool) and the
# PATH entry are intentionally left in place and only reported.
# Test-ExakitSafeUninstallTarget <path> - is this a path the uninstall may
# delete? Twin of _un_safe_target in common.sh.
#
# EXAKIT_HOME IS TAKEN FROM THE ENVIRONMENT, and this side handed it straight
# to Remove-Item -Recurse -Force with no check at all. The kit's own OneDrive
# notice tells people to "set EXAKIT_HOME to a folder on a local drive", so
# EXAKIT_HOME=D:\ or EXAKIT_HOME=D:\work is one literal reading away, and
# -Yes skips the only prompt. The same questions as the shell side: fully
# qualified (not "C:x" or "\x", which depend on the current drive or
# directory), not a drive or share root, not the user's home, and
# recognisable as a directory this kit built - or empty.
function Test-ExakitSafeUninstallTarget([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        if ($Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)') { return $false }
    } elseif (-not $Path.StartsWith('/')) {
        # pwsh on macOS/Linux (the CI legs and the tests): rooted means "/...".
        return $false
    }
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') } catch { return $false }
    $root = [System.IO.Path]::GetPathRoot($full)
    if ((-not $root) -or ($full -ieq $root.TrimEnd('\', '/'))) { return $false }
    foreach ($homeDir in @($HOME, $env:USERPROFILE, $script:ExakitHomeBase)) {
        if (-not $homeDir) { continue }
        try { $homeFull = [System.IO.Path]::GetFullPath($homeDir).TrimEnd('\', '/') } catch { continue }
        if ($full -ieq $homeFull) { return $false }
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return $false }
    foreach ($marker in @("manifest.json", "logs", "cache", "credentials", "kit", "mcp", "backups",
                          "libexec", "workflows", "migration", ".last-failure", ".install.lock")) {
        if (Test-Path -LiteralPath (Join-Path $full $marker)) { return $true }
    }
    # Nothing of ours in it. Empty is still fine; anything else is not.
    $anyEntry = Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    return ($null -eq $anyEntry)
}

function Invoke-ExakitUninstallRun {
    param([switch]$DryRun)

    # THE GUARD RUNS BEFORE ANYTHING IS REMOVED, so "Nothing was removed" is
    # true when it fires. Twin of the check at the top of exakit_uninstall_run.
    if ((Test-Path -LiteralPath $script:ExakitHome) -and -not (Test-ExakitSafeUninstallTarget $script:ExakitHome)) {
        Info "EXAKIT_HOME must be a full path (for example C:\exasol-starter-kit) holding the kit's manifest.json. It cannot be a drive root or your home folder."
        Info "Nothing was removed. Check EXAKIT_HOME, or clear it to use the default $(Join-Path $script:ExakitHomeBase '.exasol-starter-kit')."
        Fail "Refusing to remove $($script:ExakitHome): it is not a full path to a kit home the kit created (unsafe EXAKIT_HOME)."
    }

    # A real run narrates itself on ONE line. Every path it touches was printed
    # as its own bullet, around twenty lines for a command whose whole result is
    # "it is gone". The paths go to the LOGFILE, which is the right place for an
    # account of what a destructive command touched.
    #
    # THE OUTCOMES DO NOT GO WITH THEM. Quieting the paths through
    # ExakitQuietDetail also quieted every Info() that named WHAT was gone, so a
    # run that removed a database, a container, a volume, three add-ons, five
    # AI-client configs, two virtual environments and the launcher printed six
    # lines and named none of them. And step 5 below deletes the logfile the
    # detail was routed into, so afterwards there was no record anywhere, on
    # screen or on disk. Each area therefore promotes ONE durable line through
    # RecordRemoved (OkStep, which survives the quiet bracket), naming
    # what it removed; the closing line says that those lines are the whole
    # record, because by then they are.
    #
    # NOT in a dry run: there, listing every path IS the output. Twin of
    # exakit_uninstall_run in common.sh.
    $unPrevQuiet = $script:ExakitQuietDetail
    if (-not $DryRun -and $script:UiFancy) {
        $script:ExakitQuietDetail = $true
        Start-ExakitSpinner "Removing the kit"
    }
    # Real runs only: a dry run removed nothing, so a line in the past tense
    # would be a lie, and the plan lines above already say what it would do.
    #
    # No Verb-Noun hyphen, and not by accident: this helper is nested inside the
    # function that uses it, and tests/lib/ps-uninstall-calls.sh resolves every
    # Verb-Noun call in here against the file's TOP-LEVEL definitions - a nested
    # one is invisible to it, so a hyphenated name would read as a call to a
    # helper that does not exist. OkStep and Warn2 are spelled the same way.
    function RecordRemoved([string]$Message) {
        if (-not $DryRun) { OkStep $Message }
    }
    try {

    # 0a) Boot entries first: a Startup entry left behind would try to start
    #     something that no longer exists at the next login.
    foreach ($svcId in (Get-ExakitServiceIds)) {
        if (Test-ExakitAutostartRegistered -Id $svcId) {
            if ($DryRun) { Info "  will remove: the automatic-start entry for $svcId" }
            else { Unregister-ExakitAutostart -Id $svcId }
        }
    }

    # 0b) Kit-managed marketplace add-ons that live OUTSIDE the kit home (the
    #    VS Code extension). Registry-driven: a new add-on ships its own
    #    UninstallFn and appears here with no edits. A system-installed copy
    #    the kit never managed is not touched (each hook enforces that).
    $addonsGone = @()
    # Tells an add-on hook that the kit home goes next, so it does not promise
    # to keep something step 5 is about to delete (dash-server's instance).
    $script:ExakitUninstallFull = $true
    foreach ($addonId in (Get-ExakitMarketplaceInstalledAddons)) {
        $addonEntry = Get-ExakitMarketplaceAddon $addonId
        if ($addonEntry -and $addonEntry.PSObject.Properties["UninstallFn"] -and
            (Get-Command $addonEntry.UninstallFn -ErrorAction SilentlyContinue)) {
            try { [void](& $addonEntry.UninstallFn -DryRun:$DryRun); $addonsGone += $addonId }
            catch { Warn2 "Removing the $addonId add-on reported issues (continuing uninstall)" }
        }
    }
    $script:ExakitUninstallFull = $false
    if ($addonsGone.Count -gt 0) { RecordRemoved "Add-ons removed: $($addonsGone -join ', ')" }

    # 1) Database + all data.
    $type = Get-RuntimeType
    if ($type) {
        if ($DryRun) {
            Info "  will remove: local Exasol $type deployment and ALL its data"
        } else {
            Info "Removing the local Exasol $type deployment and all data"
            switch ($type) {
                "personal" { try { Remove-Personal } catch { Warn2 "Database removal reported errors (continuing uninstall)" } }
                default { Warn2 "Unknown runtime type '$type'; skipping database removal" }
            }
            RecordRemoved "Database removed: the local Exasol Personal deployment and all its data"
        }
    }

    # 2) Managed MCP configuration in the AI clients. Best-effort.
    if (Get-Command Invoke-McpOperation -ErrorAction SilentlyContinue) {
        # The client list comes from the table that owns it (mcp.ps1) rather than
        # being spelled out here: the dry-run line named three clients while the
        # operation covered eight, so five configs were edited that nothing on
        # screen ever mentioned. Twin of the exakit_mcp_clients_from_args call in
        # exakit_uninstall_run.
        $mcpClientList = "all managed clients"
        if ($script:McpClientLabels) { $mcpClientList = (@($script:McpClientLabels.Keys) | Sort-Object) -join ' ' }
        if ($DryRun) {
            Info "  will remove: managed MCP configuration in the AI clients ($mcpClientList)"
        } else {
            Info "Removing managed MCP configuration from AI clients"
            try { [void](Invoke-McpOperation -Operation "uninstall" -InputArgs @()) }
            catch { Warn2 "Removing the managed AI client config reported issues (continuing uninstall)" }
        }
        RecordRemoved "MCP entry removed from the AI clients the kit manages: $mcpClientList"
    }

    # 3) Installed AI skills: the live kit list, or what the install recorded
    #    once the checkout is gone. One helper, shared with the selectable
    #    uninstall below, so the two paths can never disagree about which
    #    skills belong to the kit.
    # One line per FOLDER, not per skill: nine skills across two discovery
    # folders printed eighteen near-identical lines in the middle of an
    # uninstall. The individual paths go to the log, where a reader looks when
    # they want them. Mirrors _exakit_remove_installed_skills in common.sh.
    $skillNames = @(Get-ExakitKitSkillNames)
    foreach ($root in (Get-ExakitSkillRoots)) {
        $found = 0
        foreach ($name in $skillNames) {
            $p = Join-Path $root $name
            if (-not (Test-Path $p)) { continue }
            $found += 1
            Write-ExakitLog "INFO" "AI skill $p"
            if (-not $DryRun) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $p }
        }
        if ($found -eq 0) { continue }
        $word = if ($found -eq 1) { "skill" } else { "skills" }
        if ($DryRun) { Info "  will remove: $found AI $word from $root" }
        else { Info "$found AI $word from $root" }
    }
    # The permission rules skills-install merged into ~\.claude\settings.json go
    # with the skills; only the kit's own entries. Twin of the same step in
    # _exakit_remove_installed_skills.
    if ($DryRun) { Info "  will remove: the exakit permission rules from ~\.claude\settings.json" }
    else {
        $removedRules = Remove-ExakitReadonlyAllowlist
        if ("$removedRules" -match '^REMOVED ([1-9]\d*)$') { Info "exakit permission rules removed from ~\.claude\settings.json" }
    }

    # 4) exapump profile store (the kit created it; the binary goes in step 6).
    # Every candidate home, not just $HOME: see Get-ExakitExapumpProfileDirs.
    foreach ($exapumpDir in (Get-ExakitExapumpProfileDirs)) {
        if (-not (Test-Path $exapumpDir)) { continue }
        if ($DryRun) { Info "  will remove: exapump profiles at $exapumpDir" }
        else { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $exapumpDir }
    }

    # 5) Kit home: credentials, logs, manifest, cached kit copy, MCP snapshots.
    if (Test-Path $script:ExakitHome) {
        # The MCP snapshots taken in step 2 are the only copy of each client
        # config as it was BEFORE this uninstall edited it. Keep them beside the
        # home, not inside it. Twin of the same move in exakit_uninstall_run.
        $backupsDir = Join-Path $script:ExakitHome "backups"
        if (-not $DryRun -and (Test-Path $backupsDir) -and @(Get-ChildItem -Path $backupsDir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            $keep = "$($script:ExakitHome)-backups-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            try {
                Move-Item -Path $backupsDir -Destination $keep -ErrorAction Stop
                Info "AI client config snapshots kept at $keep (delete it when you are sure)"
            } catch { }
        }
        if ($DryRun) { Info "  will remove: kit home $script:ExakitHome (credentials, logs, manifest, snapshots)" }
        else { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $script:ExakitHome }
        RecordRemoved "Kit home removed: $script:ExakitHome (credentials, logs, manifest, snapshots, pyexasol venv, add-on state)"
    }

    # 6) CLI binaries. Removed last so earlier steps can still call them.
    #    exakit.cmd is the wrapper cmd.exe is still executing right now; deleting
    #    it in-process makes cmd.exe print "The batch file cannot be found." when
    #    it re-reads the file after we exit. So collect the binaries and hand
    #    their removal to a detached process that waits for us to exit first.
    $binPaths = @()
    # Marketplace add-on launchers are swept by registry id - a new add-on
    # needs no edit here.
    $binNames = @("exakit.cmd", "exapump.exe", "exasol.exe", "exakit.ps1")
    if (Get-Command Get-ExakitMarketplaceAddons -ErrorAction SilentlyContinue) {
        foreach ($addon in Get-ExakitMarketplaceAddons) { $binNames += "$($addon.Id).cmd" }
    }
    foreach ($bin in $binNames) {
        $p = Join-Path $script:BinDir $bin
        if (Test-Path $p) {
            if ($DryRun) { Info "  will remove: CLI binary $p" }
            else { $binPaths += $p }
        }
    }
    if (-not $DryRun -and $binPaths.Count -gt 0) {
        Remove-ExakitBinariesDeferred -Paths $binPaths
        $binNamesGone = @($binPaths | ForEach-Object { Split-Path -Leaf $_ })
        RecordRemoved "Commands removed from $($script:BinDir): $($binNamesGone -join ', ')"
    }
    } finally {
        Stop-ExakitSpinner
        $script:ExakitQuietDetail = $unPrevQuiet
    }
    # Said last, and said plainly, because it is the one thing the reader cannot
    # find out afterwards: the logfile that held the per-path detail lived inside
    # the kit home this run has just deleted, so the lines above are the only
    # account of what was removed that still exists anywhere.
    if (-not $DryRun) {
        InfoStep "The lines above are the whole record of this uninstall - the install log lived in the kit home and went with it."
    }
}

# Delete the CLI binaries from a short-lived detached PowerShell that first
# waits for this process (and the cmd.exe running exakit.cmd) to exit. Deleting
# exakit.cmd while cmd.exe is still executing it is what makes the shell print
# "The batch file cannot be found."; deferring avoids that entirely.
function Remove-ExakitBinariesDeferred {
    param([string[]]$Paths)
    $waitPids = @($PID)
    try {
        $me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        # The parent is the cmd.exe running exakit.cmd - the one that re-reads
        # the batch file after we return. Wait for it too, but not its parent
        # (the user's interactive shell, which never exits).
        if ($me.ParentProcessId) { $waitPids += [int]$me.ParentProcessId }
    } catch { }
    $waitPids = @($waitPids | Sort-Object -Unique)
    $pidList = $waitPids -join ','
    $quoted  = ($Paths | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $deferred = @"
foreach (`$id in @($pidList)) { try { Wait-Process -Id `$id -Timeout 60 -ErrorAction SilentlyContinue } catch {} }
Start-Sleep -Milliseconds 250
foreach (`$f in @($quoted)) { try { Remove-Item -Force -ErrorAction SilentlyContinue `$f } catch {} }
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($deferred))
    try {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-EncodedCommand", $encoded) `
            -WindowStyle Hidden | Out-Null
    } catch {
        # If we cannot spawn the detached cleaner, fall back to deleting inline.
        # The batch-file message may reappear, but the binaries are still gone.
        foreach ($f in $Paths) { Remove-Item -Force -ErrorAction SilentlyContinue $f }
    }
}

function Invoke-CmdUninstall {
    param([switch]$AssumeYes, [switch]$DryRun, [string]$Addon = "")
    Initialize-ExakitLogging

    if (-not (Test-Path $script:ManifestPath) -and
        -not (Test-Path (Join-Path $script:BinDir "exakit.cmd")) -and
        -not (Test-Path $script:ExakitHome)) {
        Info "Nothing to uninstall - no manifest, kit home, or installed binaries were found."
        return
    }

    # A marketplace add-on by name: selective removal an agent or a script can
    # call, instead of the TTY-only menu being the sole route to removing one
    # piece. Twin of the same branch in cmd_uninstall (setup/exakit).
    if ($Addon) {
        $known = @(Get-ExakitMarketplaceAddons | ForEach-Object { $_.Id })
        if ($known -notcontains $Addon) {
            Write-Host ""
            Write-Host "  [x] Unknown uninstall target '$Addon' (known add-ons: $($known -join ' '); bare 'exakit uninstall' removes the kit)."
            exit 2
        }
        if (-not (Test-ExakitMarketplaceAddonInstalled $Addon)) {
            Info "$Addon is not installed - nothing to remove."
            return
        }
        if ($DryRun) {
            # The add-on's own hook narrates its plan. Twin of cmd_uninstall.
            Info "Dry run - removing the $Addon add-on would:"
            $addonEntry = Get-ExakitMarketplaceAddon $Addon
            if ($addonEntry -and $addonEntry.PSObject.Properties["UninstallFn"] -and
                (Get-Command $addonEntry.UninstallFn -ErrorAction SilentlyContinue)) {
                [void](& $addonEntry.UninstallFn -DryRun)
            }
            return
        }
        if (-not $AssumeYes) {
            if (-not (Confirm-ExakitPrompt "Remove the $Addon add-on?" -DefaultYes:$false)) {
                Info "Nothing was removed."
                return
            }
        }
        Invoke-ExakitUninstallComponent -Key $Addon
        Ok "$Addon removed. Reinstall any time with: exakit marketplace $Addon"
        return
    }

    # -DryRun previews the FULL plan; -Yes is the scripted full uninstall.
    # Everything else goes through the selectable menu: pick what goes, see
    # what that means, type the word. Twin of cmd_uninstall in setup/exakit.
    if ($DryRun) {
        Write-Host ""
        Warn2 "exakit uninstall PERMANENTLY removes the Exasol Personal Local Starter Kit."
        Info "A full uninstall (the EVERYTHING row, or -Yes) removes:"
        Invoke-ExakitUninstallRun -DryRun
        Write-Host ""
        Info "Not touched: uv/uvx (shared tool), any PATH entry in your profile, and anything the kit did not install."
        Info "Dry run only - nothing was removed. Pick individual pieces interactively with: exakit uninstall"
        return
    }

    if ($AssumeYes) {
        Write-Host ""
        Warn2 "exakit uninstall -Yes removes the FULL kit (all local database data included)."
        Invoke-ExakitUninstallRun
        Write-Host ""
        Ok "Uninstall complete - the Exasol Personal Local Starter Kit has been removed."
        return
    }

    Show-ExakitUninstallMenu
}

# The interactive `exakit uninstall`: pick exactly what goes, see exactly what
# that means, then type the word. Registry-driven for add-ons - a new add-on
# ships its own UninstallFn and appears here with no edits. Twin of
# exakit_uninstall_menu in setup/lib/common.sh.
function Show-ExakitUninstallMenu {
    $tee = $script:UiTee; $corner = $script:UiCorner
    $labels = New-Object System.Collections.Generic.List[string]
    $keys = New-Object System.Collections.Generic.List[string]
    [void]$labels.Add("Skip - uninstall nothing")
    [void]$keys.Add("__skip__")

    # The BUILT-IN components are deliberately NOT rows here. Twin of the
    # comment in exakit_uninstall_menu: the database, its MCP configs, exapump's
    # profile and the pyexasol venv are one working installation, so removing
    # one of them leaves a kit that looks installed and does not work. The two
    # honest choices for the core are keep it (Skip) or remove it (EVERYTHING).
    # Add-ons are optional by construction and nothing depends on them, so they
    # are the only individually selectable rows. There is no by-name form: this
    # menu is the whole interface. The hint that used to sit under it named a
    # syntax neither side accepts -- and where the shell at least answered
    # "Unknown option", this dispatch tests only for flags, so a component name
    # was silently ignored and the menu opened as if nothing had been typed.

    # Kit-managed add-ons, each removable on its own (registry-driven).
    $addons = @(Get-ExakitMarketplaceInstalledAddons)
    if ($addons.Count -gt 0) {
        # The scope row, and the caption at the same time. A separate
        # "Add-ons (kit-managed)" caption said the word twice and left the sweep
        # floating above the tree it acts on. Both scope rows say what SURVIVES.
        # Mirrors exakit_uninstall_menu in common.sh.
        [void]$labels.Add("Add-ons only - keeps: starter-kit")
        [void]$keys.Add("__all_addons__")
        for ($i = 0; $i -lt $addons.Count; $i++) {
            $conn = if ($i -eq $addons.Count - 1) { $corner } else { $tee }
            # Indented a level further than the scope row above them.
            [void]$labels.Add("  $conn $($addons[$i])")
            [void]$keys.Add($addons[$i])
        }
    }

    [void]$labels.Add("EVERYTHING - keeps: nothing")
    [void]$keys.Add("everything")
    $everyIdx = $labels.Count

    Write-Host ""

    # EVERYTHING is a MASTER toggle over every row above it: picking it ticks
    # them all, and unticking any single row releases it - so the screen can
    # never claim "everything" while something sits unticked. Skip stays the
    # exclusive opt-out.
    if ($everyIdx -gt 2) {
        # "Add-ons only" is itself a master over the add-ons drawn under it, so
        # the row and its tree agree: ticking it ticks them, and ticking the last
        # of them ticks it. Listed in -Groups because it nests INSIDE EVERYTHING,
        # and an inner group must settle before the outer one reads its parent.
        $innerGroups = @()
        if ($everyIdx -gt 3) { $innerGroups = @("2:3:$($everyIdx - 1):all") }
        # EVERYTHING is "master", not "all": it removes the database, which no
        # row above it represents, so ticking every add-on must never come to
        # mean "remove the kit". It still ticks them all when picked, and still
        # releases the moment one is unticked.
        $selection = Read-ExakitCheckboxMenu -Title "Select what to uninstall" `
            -Options $labels.ToArray() -Defaults @(1) -ExclusiveIndex 1 `
            -Groups $innerGroups `
            -GroupParent $everyIdx -GroupFirst 2 -GroupLast ($everyIdx - 1) -GroupMode "master"
    } else {
        $selection = Read-ExakitCheckboxMenu -Title "Select what to uninstall" `
            -Options $labels.ToArray() -Defaults @(1) -ExclusiveIndex 1
    }
    if ($selection -contains 1) { Info "Nothing was uninstalled."; return }

    $picked = @()
    $pickedLabels = @()
    foreach ($idx in $selection) {
        if ($idx -lt 2) { continue }
        $key = $keys[$idx - 1]
        # BEFORE the "__" skip: the sweep key is spelled like the placeholder
        # keys that skip exists to drop, so checking it afterwards silently
        # discarded the pick and the menu answered "Nothing selected" with the
        # row plainly ticked.
        if ($key -eq "__all_addons__") {
            foreach ($a in $addons) {
                if ($picked -contains $a) { continue }
                $picked += $a
                $pickedLabels += $a
            }
            continue
        }
        if ($key.StartsWith("__")) { continue }
        if ($key -eq "everything") {
            # EVERYTHING swallows any other pick - the full run covers it all.
            $picked = @("everything")
            $pickedLabels = @("EVERYTHING - the full kit (database + data, MCP configs, skills, exapump, pyexasol, add-ons, kit home, exakit)")
            break
        }
        $picked += $key
        $pickedLabels += ($labels[$idx - 1].TrimStart() -replace ("^" + [regex]::Escape($tee) + " "), "" -replace ("^" + [regex]::Escape($corner) + " "), "")
    }
    if ($picked.Count -eq 0) { Info "Nothing selected - nothing was uninstalled."; return }

    # The informed consent: exactly what was picked, then the typed gate.
    Write-Host ""
    Start-ExakitPanel "This will PERMANENTLY remove"
    foreach ($line in $pickedLabels) { Write-ExakitPanelLine $line }
    Complete-ExakitPanel
    Write-Host ""
    Warn2 "This is IRREVERSIBLE. Removed data cannot be recovered."
    if ($picked -contains "database" -or $picked -contains "everything") {
        Warn2 "The database selection deletes ALL local database data."
    }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Fail "uninstall needs an interactive terminal to confirm; use -Yes for the scripted full uninstall."
    }
    $answer = Read-Host "  ! Type UNINSTALL to remove the items above (anything else cancels)"
    if ($answer -cne "UNINSTALL") { Info "Uninstall cancelled - nothing was removed."; return }

    Write-Host ""
    foreach ($key in $picked) { Invoke-ExakitUninstallComponent -Key $key }
    Write-Host ""
    # A full uninstall has just deleted the exakit command, so pointing at
    # `exakit info` ends the run with an instruction that cannot be followed.
    # Anything short of EVERYTHING leaves the CLI in place.
    if ($picked -contains "everything") {
        Ok "Done. The kit is gone."
        Info "Install it again any time: $(Get-ExakitInstallCommand)"
    } else {
        Ok "Done. See where you stand with: exakit info"
    }
}

# One selectable piece of the kit, removed on its own. Twin of
# _exakit_uninstall_component in setup/lib/common.sh.
function Invoke-ExakitUninstallComponent {
    param([Parameter(Mandatory)][string]$Key)
    switch ($Key) {
        "database" {
            # NO shared-engine warning here any more: by this line the user has
            # typed UNINSTALL and the removal is under way. The hazard is stated
            # before the gate instead (Show-ExakitSharedEngineDbWarning, called
            # from Show-ExakitUninstallMenu), which is the only place saying it
            # can still change the answer. Twin of the same move in
            # _exakit_uninstall_component.
            Info "Removing the local Exasol Personal deployment and all data"
            try { Remove-Personal } catch { Warn2 "Database removal reported errors" }
            Remove-ExakitStepDone "runtime"
        }
        "mcp_configs" {
            Info "Removing the managed MCP configuration from the AI clients"
            try { [void](Invoke-McpOperation -Operation "uninstall" -InputArgs @()) }
            catch { Warn2 "Removing the managed AI client config reported issues" }
        }
        "skills" {
            foreach ($root in (Get-ExakitSkillRoots)) {
                foreach ($name in (Get-ExakitKitSkillNames)) {
                    $p = Join-Path $root $name
                    if (Test-Path $p) {
                        Info "AI skill $p"
                        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $p
                    }
                }
            }
        }
        "exapump" {
            Info "Removing exapump and its profiles"
            Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $script:BinDir "exapump.exe")
            foreach ($exapumpDir in (Get-ExakitExapumpProfileDirs)) {
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $exapumpDir
            }
            Remove-ExakitManifestValue "components.exapump"
            Remove-ExakitStepDone "exapump"
        }
        "pyexasol" {
            Info "Removing the pyexasol venv"
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $script:ExakitHome "pyexasol-venv")
            Remove-ExakitManifestValue "components.pyexasol"
            Remove-ExakitStepDone "pyexasol"
        }
        "everything" {
            Invoke-ExakitUninstallRun
            Info "If a PATH entry for $script:BinDir remains in your profile, remove it manually if you no longer need it."
        }
        default {
            # A marketplace add-on: its module owns the removal.
            $addonEntry = Get-ExakitMarketplaceAddon $Key
            if ($addonEntry -and $addonEntry.PSObject.Properties["UninstallFn"] -and
                (Get-Command $addonEntry.UninstallFn -ErrorAction SilentlyContinue)) {
                try { [void](& $addonEntry.UninstallFn) }
                catch { Warn2 "Removing the $Key add-on reported issues" }
                # ...and the skills it owns go with it. Here rather than in the
                # module, so every add-on gets it without writing a line.
                try { Remove-ExakitAddonSkills $Key } catch { }
                # ...and so does its BOOT ENTRY - left behind, it kept firing a
                # launcher that no longer exists on every login, forever.
                try { Unregister-ExakitAutostart -Id $Key } catch { }
            } else {
                Warn2 "The $Key module carries no uninstall - update the kit: exakit update"
            }
        }
    }
}

# Invoke-CmdVersion - one screen for "what have I got, and is any of it out of
# date?"
#
# This used to be two commands. `exakit version` listed what was installed and
# `exakit update-check` compared it against the advertised set, so answering the
# only question either was ever asked meant running both and reading one screen
# against the other. The Kit panel is the part with no component/version/status
# shape; everything under it is the table.
#
# Three columns, because the third answers the question the other two raise:
#   Component  what to name in `exakit update <component>`
#   Version    what is on this machine right now
#   Status     current, or the advertised version
# The tagged version, the maintainer's severity and the action all live in
# Status: each is only ever interesting for a row that is behind, and four
# mostly-empty columns pushed the card past 80 columns to say nothing.
#
# Someone who asks explicitly gets fresh data: the TTL exists for the readers
# that run behind other commands, not for this one.
# Twin of cmd_version in setup/exakit and exakit_print_version_table in
# setup/lib/common.sh.
function Invoke-CmdVersion {
    param([switch]$Json)
    if (-not (Test-Path $script:ManifestPath)) {
        if ($Json) { Write-ExakitNotInstalledAnswer -Json }
        Write-Host "Not installed (no manifest at $script:ManifestPath)"; exit 4
    }

    if (-not $Json) {
        Start-ExakitPanel "Kit"
        Write-ExakitPanelLine ("{0,-14} {1}" -f "Version",   "$(Get-ExakitComponentCurrent 'exakit')")
        # No "Level" row: an internal schema number, meaningless to the reader.
        # No "Source" row either: an absolute path to the kit's own copy of itself,
        # which answers a question nobody asks of a version screen.
        Write-ExakitPanelLine ("{0,-14} {1}" -f "Installed", "$(Format-ExakitLocalTime (Get-ExakitManifestValue 'installed_at'))")
        Complete-ExakitPanel
        Write-Host ""
    }

    if ($script:VersionPolicy -eq "manifest") {
        # The one phase that can reach the network, so the one most worth
        # narrating: on a network that cannot reach the manifest it is also the
        # longest wait in the command.
        Invoke-ExakitWithSpinner -Label "Checking for newer versions" -Body {
            Update-ExakitVersionsCache -Force | Out-Null
            Resolve-ExakitVersionsDoc | Out-Null
        } | Out-Null
    }

    # Rows are collected before anything is drawn, so every column is measured
    # from what it actually holds. A fixed width fits the built-in component
    # names and nothing else: dash-server (11), json-tables (11) and
    # exasol-vscode (13) each overflow it, and an overflowing cell pushes every
    # column after it right ON THAT ROW ONLY - so the table lost its alignment
    # exactly when a user had add-ons installed, and only for their rows.
    $rows = New-Object System.Collections.Generic.List[object]
    $compWidth = 9
    $verWidth = 7
    # One counter, not three. The table used to sort what was waiting into quick,
    # heavy and staged so it could print a different closing line for each, and
    # the three lines said the same thing three ways. `exakit update` already
    # knows a runtime change needs the database stopped and asks at the moment it
    # matters; this screen only has to say that something is waiting.
    $pending = 0

    # Each component is probed on disk, and several of those probes start a
    # process. Narrated per component so the reader can see it advancing
    # rather than guessing whether it has stalled.
    # Get-ExakitVersionTableTargets decides which rows exist, and deciding that
    # probes each add-on for whether it is present at all - which for the VS
    # Code extension means asking VS Code. It runs BEFORE the per-component
    # spinners below, so without this the screen sat silent right after the Kit
    # box, which is exactly where it was reported.
    $versionTargets = Invoke-ExakitWithSpinner -Label "Working out which components to check" -Body {
        ,@(Get-ExakitVersionTableTargets)
    }
    foreach ($component in $versionTargets) {
        $actual = Get-ExakitActualTarget $component
        $installed = Invoke-ExakitWithSpinner -Label "Checking $actual" -Body {
            Get-ExakitComponentCurrent $actual
        }
        if (-not $installed) { $installed = "not installed" }
        $available = Get-ExakitComponentAvailable $actual
        if (-not $available) { $available = "unknown" }
        # Spelled the way every other row spells it - see Get-ExakitVersionPlain.
        $installed = Get-ExakitVersionPlain $installed
        $available = Get-ExakitVersionPlain $available
        $rowNote = ""
        $severity = Get-ExakitComponentSeverity $actual
        $status = "current"

        if (-not (Test-ExakitComponentSupported $actual)) {
            # Nothing to offer and nothing wrong: there is simply no build for
            # this machine, and an update command that cannot succeed must not be
            # printed.
            $installed = "not available"
            $status = "-"
            $severity = ""
            $rowNote = "no $actual build exists for this platform"
        } elseif ($installed -eq "not installed" -and (Get-ExakitMarketplaceAddon $actual)) {
            # An add-on nobody has installed is not behind on anything: it is an
            # offer. The marketplace is the only path that installs one, so that
            # is the whole status - naming a version here would read as a pending
            # update to something that is not on the machine.
            $status = "exakit marketplace"
            $severity = ""
        } elseif ($available -eq "unknown" -or $installed -eq "unknown") {
            $status = "unknown - check: exakit status"
        } elseif ($installed -eq "not installed" -and (Test-ExakitComponentHeavy $actual)) {
            # A runtime that is not installed is not a runtime this machine
            # wants: offering to deploy a database onto a machine that never
            # had one is actively wrong. (A missing light component, by
            # contrast, is exactly the repair case below.)
            $status = "not installed - re-run the installer"
        } elseif ($installed -ne "not installed" -and (Test-ExakitVersionNewer -Latest $installed -Current $available)) {
            # Installed is ahead of the published set. The kit never moves a
            # component backwards, so there is nothing to offer: lowering a
            # version in versions.json is not a rollback lever, and a user who
            # upgraded a component themselves keeps what they chose.
            #
            # The row says only "none". Not "yours is newer than tested", which
            # apologised for the install and made the tested set sound abandoned;
            # not the tagged number either, which invites the reader to go looking
            # for a way back to it. There is nothing to do, so the row says so and
            # stops. The severity goes with it - a severity rates the advertised
            # version, and there is nothing to recommend to someone already past it.
            $status = "none"
            $severity = ""
        } elseif ($installed -ne $available) {
            $minKit = Get-ExakitComponentMinKit $actual
            if ($minKit -and -not (Test-ExakitMinKitSatisfied -Required $minKit)) {
                # Waiting, but not on this reader: `exakit update` cannot apply it
                # until the kit itself moves, so it must not be counted into the
                # closing line that promises it can.
                $status = "update exakit first (needs kit >= $minKit)"
            } elseif ($installed -eq "not installed") {
                # Not an upgrade: the component the manifest says belongs here is
                # missing, and `exakit update` puts it back.
                $status = "$available available (repair)"
                $pending += 1
            } else {
                # No "(heavy)" or "(major)" suffix: what applying a component
                # involves is `exakit update`'s to explain, at the point where it
                # asks. Saying it here warned about a cost on a screen that cannot
                # charge it, and left the Status column reading like a set of
                # caveats rather than a set of versions.
                $status = "$available available"
                $pending += 1
            }
        }

        if ($actual.Length -gt $compWidth) { $compWidth = $actual.Length }
        if ($installed.Length -gt $verWidth) { $verWidth = $installed.Length }
        $rows.Add(@{
            C = $actual
            V = $installed
            S = (Get-ExakitStatusCell -Status $status -Severity $severity)
            N = $rowNote
            M = "$(Get-ExakitComponentNote $actual)"
            A = $available
            R = $status
            Sev = $(if ($severity) { $severity } else { "normal" })
        })
    }

    if ($Json) {
        # The same rows as one object - twin of the --json form of
        # exakit_print_version_table. `exakit version --json` used to print the
        # decorated table and exit 0.
        $components = @()
        # WHICH ROWS ARE OPTIONAL. Nothing in a component object said whether it
        # is part of the kit or an add-on someone chose, so an agent reading
        # `status: "available"` could not tell "you have not installed this
        # optional tool" from "a piece of your kit is missing". The registry is
        # the source, never a hand-written set. Twin of addon_ids in
        # exakit_print_version_table --json.
        $addonIds = @(Get-ExakitMarketplaceAddons | ForEach-Object { $_.Id })
        foreach ($r in $rows) {
            # The raw cell doubles as the HUMAN Action column, so it carried
            # whatever a person should do next - "exakit marketplace",
            # "2.2.0 available (repair)" - which is a command or a sentence, not
            # a status. An agent branching on `status` (current vs everything
            # else) saw neither, and one that copied the field into a message
            # told the user their scheduler's status was "exakit marketplace".
            # The JSON key gets the fixed vocabulary a parser can switch on, and
            # the action moves to a per-row remedy that is runnable as-is.
            # Twin of the same mapping in exakit_print_version_table --json.
            $rowStatus = "$($r.R)"
            $rowRemedy = $null
            if ($rowStatus -eq "current") { $rowStatus = "current" }
            elseif ($rowStatus -eq "none") { $rowStatus = "ahead" }
            elseif ($rowStatus -eq "-") { $rowStatus = "unsupported" }
            elseif ($rowStatus -eq "exakit marketplace") { $rowStatus = "available"; $rowRemedy = "exakit marketplace $($r.C)" }
            elseif ($rowStatus.StartsWith("unknown")) { $rowStatus = "unknown" }
            elseif ($rowStatus.StartsWith("not installed")) { $rowStatus = "unknown" }
            elseif ($rowStatus.StartsWith("update exakit first")) { $rowStatus = "blocked_on_kit"; $rowRemedy = "exakit update exakit" }
            elseif ($rowStatus.EndsWith("available (repair)")) { $rowStatus = "missing"; $rowRemedy = "exakit update $($r.C)" }
            elseif ($rowStatus.EndsWith("available")) { $rowStatus = "update_available"; $rowRemedy = "exakit update $($r.C)" }
            $components += [ordered]@{
                component       = $r.C
                addon           = ($addonIds -contains $r.C)
                installed       = $(if ($r.V -in @("not installed", "not available", "")) { $null } else { $r.V })
                installed_label = $r.V
                advertised      = $(if ($r.A -in @("unknown", "")) { $null } else { $r.A })
                status          = $rowStatus
                remedy          = $rowRemedy
                severity        = $r.Sev
                note            = $(if ($r.M) { $r.M } else { $null })
                platform_note   = $(if ($r.N) { $r.N } else { $null })
            }
        }
        $statusWord = "current"
        $remedy = $null
        if ($pending -gt 0) { $statusWord = "update_pending"; $remedy = "exakit update" }
        [ordered]@{
            installed       = $true
            status          = $statusWord
            remedy          = $remedy
            pending         = $pending
            kit             = [ordered]@{ version = "$(Get-ExakitComponentCurrent 'exakit')"; installed_at = "$(Get-ExakitManifestValue 'installed_at')" }
            versions_source = "$(Get-ExakitVersionsSource)"
            components      = $components
        } | ConvertTo-Json -Depth 5
        if ($script:NoticePlanPath -and (Test-Path $script:NoticePlanPath)) {
            Remove-Item -Force $script:NoticePlanPath -ErrorAction SilentlyContinue
        }
        return
    }

    # A card, like every other framed answer the kit gives. Complete-ExakitPanel
    # measures with Get-ExakitVisibleLength, so the coloured severity suffix does
    # not throw the border off the way a byte count would.
    Start-ExakitPanel "Components"
    Write-ExakitPanelLine ("{0} {1} {2}" -f "Component".PadRight($compWidth), "Version".PadRight($verWidth), "Status")
    foreach ($r in $rows) {
        Write-ExakitPanelLine ("{0} {1} {2}" -f $r.C.PadRight($compWidth), $r.V.PadRight($verWidth), $r.S)
        Write-ExakitVersionNote $r.N
        Write-ExakitVersionNote $r.M
    }
    Complete-ExakitPanel
    Write-Host ""

    # This screen just worked out the truth the long way. Retire the cached plan
    # so the next notice cannot repeat something the table above has just
    # contradicted.
    if ($script:NoticePlanPath -and (Test-Path $script:NoticePlanPath)) {
        Remove-Item -Force $script:NoticePlanPath -ErrorAction SilentlyContinue
    }
    Write-ExakitVersionsSourceLine
    # One command is promoted, and it is the one that handles everything:
    # `exakit update`. Per-component commands still work and the rows name the
    # components, so anyone who wants one has it - but a screen that listed a
    # command per row taught the long way round to the reader who least needed it.
    # The add-on rows carry their own `exakit marketplace`, so the discovery line
    # that used to repeat it here is gone too.
    $unfinishedStep = "$(Get-ExakitManifestValue 'install.current_step')"
    if ($unfinishedStep -ne "") {
        # A half-finished install is repaired by the installer, not by update:
        # update assumes a runtime to update.
        Info "The install did not finish (step: $unfinishedStep) - re-run the installer; it resumes there."
    } elseif ($pending -gt 0) { Info "Bring everything up to date with: exakit update" }
}

# Get-ExakitVersionTableTargets - every row the table shows.
#
# The update set (what `exakit update` would act on) plus the add-ons this
# machine COULD install: a row saying "not installed" is only worth printing when
# `exakit marketplace` can actually fix it, so an add-on that cannot run here is
# left out entirely rather than dangling an install that would be refused. Same
# filter, and so the same list, as the marketplace screen itself.
# Twin of exakit_version_table_targets in setup/lib/common.sh.
function Get-ExakitVersionTableTargets {
    $targets = @(Get-ExakitUpdateTargets -Target "all")
    foreach ($addon in (Get-ExakitMarketplaceAddons)) {
        if (-not (Test-ExakitAddonOfferable $addon.Id)) { continue }
        # PRESENT, not kit-installed: a tool the user installed themselves is
        # already on the machine, and the kit refuses to manage that copy - so a
        # row telling them to run `exakit marketplace` for it advertises an
        # install that would be declined.
        if (Test-ExakitMarketplaceAddonPresent $addon.Id) { continue }
        $targets += $addon.Id
    }
    return $targets
}

# Get-ExakitStatusCell - the Status cell, with the maintainer's severity appended
# when it is not the normal one.
#
# Only a flagged row shows a severity, so it stays the one thing on the screen
# that draws the eye. Colour goes on last and only on the suffix:
# Complete-ExakitPanel measures with Get-ExakitVisibleLength, so the escapes cost
# the border nothing.
# Twin of _exakit_status_cell in setup/lib/common.sh.
function Get-ExakitStatusCell {
    param([string]$Status, [string]$Severity)
    if ($Severity -eq "critical") {
        $suffix = "(critical)"
        if ($script:UiFancy) { $suffix = "$($script:UiWarn)$suffix$($script:UiReset)" }
        return "$Status $suffix"
    }
    if ($Severity -eq "recommended") {
        $suffix = "(recommended)"
        if ($script:UiFancy) { $suffix = "$($script:UiOk)$suffix$($script:UiReset)" }
        return "$Status $suffix"
    }
    return $Status
}

# Write-ExakitVersionNote - one note, wrapped and indented inside the card. A
# maintainer note is free text, and one long enough to blow the card past 80
# columns would wrap in the terminal instead, taking the border with it. Silent
# on an empty note, so no caller has to test first.
# Twin of _exakit_version_note_lines in setup/lib/common.sh.
function Write-ExakitVersionNote {
    param([string]$Text)
    if (-not $Text) { return }
    $line = ""
    foreach ($word in ($Text -split '\s+')) {
        if (-not $word) { continue }
        if (-not $line) {
            $line = $word
        } elseif (($line.Length + 1 + $word.Length) -le 68) {
            $line = "$line $word"
        } else {
            Write-ExakitPanelLine "  $line"
            $line = $word
        }
    }
    if ($line) { Write-ExakitPanelLine "  $line" }
}


# The marketplace core (registry, menu, apply, offer) lives in
# setup/lib/exakit-common.ps1 so the installer's closing offer can use it too
# - mirroring the bash side, where it all lives in common.sh. This file only
# carries the command entry point.
# Invoke-CmdMarketplace [--list [--json]] [<addon-id>...] - bare, it browses
# (and without a terminal it installs NOTHING; the menu says how to ask
# explicitly). --list is the read-only surface an agent can always call;
# --json makes it machine-readable. Ids are a targeted install: `exakit
# marketplace dash-server` installs dash-server and nothing else - it used to
# silently DISCARD the id and install the other pending add-ons instead.
# Twin of cmd_marketplace in setup/exakit.
function Invoke-CmdMarketplace {
    param([string[]]$Arguments = @())
    if (-not (Test-Path $script:ManifestPath)) { Fail "No installation found. Run the installer first." }
    $list = $false
    $json = $false
    $ids = @()
    $known = @(Get-ExakitMarketplaceAddons | ForEach-Object { $_.Id })
    # Bad input is refused with the bad-input code, the same style
    # Assert-ExakitKnownOptions uses - exit 2, nothing runs, no failure note.
    foreach ($arg in $Arguments) {
        switch -Regex ($arg) {
            '^(--list|-List)$' { $list = $true; continue }
            '^(--json|-Json)$' { $json = $true; continue }
            '^-' {
                Write-Host ""
                Write-Host "  [x] Unknown option '$arg' for marketplace (supported: --list, --json, or add-on ids to install)."
                exit 2
            }
            default {
                if ($known -contains $arg) { $ids += $arg }
                else {
                    Write-Host ""
                    Write-Host "  [x] Unknown marketplace add-on '$arg' (known: $($known -join ' '))."
                    exit 2
                }
            }
        }
    }
    if ($list -or $json) {
        if ($ids.Count -gt 0) {
            Write-Host ""
            Write-Host "  [x] marketplace --list is read-only and cannot be combined with add-on ids to install."
            exit 2
        }
        Show-ExakitMarketplaceList -Json:$json
        return
    }
    Initialize-ExakitLogging
    if ($ids.Count -gt 0) {
        $previous = $env:EXAKIT_MARKETPLACE_ADDONS
        try {
            $env:EXAKIT_MARKETPLACE_ADDONS = ($ids -join ",")
            Show-ExakitMarketplaceMenu
        } finally {
            if ($null -ne $previous) { $env:EXAKIT_MARKETPLACE_ADDONS = $previous }
            else { Remove-Item Env:\EXAKIT_MARKETPLACE_ADDONS -ErrorAction SilentlyContinue }
        }
        return
    }
    Show-ExakitMarketplaceMenu
}


# The upstream lookup helpers (Get-ExakitLatestGithubRelease,
# Get-ExakitLatestPypiVersion) deliberately live ONLY in
# setup/lib/exakit-common.ps1. This file used to redefine them, and because it
# is dot-sourced afterwards its copies won - including one that was not
# architecture-aware, so an x86_64 host could be told an arm64 build was the
# newest one. One definition, in the library, for both entry points.


function Get-ExakitComponentNote {
    param([string]$Component)
    if (-not (Test-ExakitManifestMetadataApplies $Component)) { return "" }
    $block = Get-ExakitComponentBlock $Component
    if (-not $block) { return "" }
    return (Get-ExakitVersionsValue -Path "$block.note")
}

function Get-ExakitComponentMinKit {
    param([string]$Component)
    if (-not (Test-ExakitManifestMetadataApplies $Component)) { return "" }
    $block = Get-ExakitComponentBlock $Component
    if (-not $block) { return "" }
    return (Get-ExakitVersionsValue -Path "$block.min_kit_version")
}

# Test-ExakitComponentSupported - false when no build of it exists for THIS machine.
# The kit must never offer an update for something that cannot be installed here:
# exapump publishes no Windows ARM64 binary (Get-ExapumpAssetName returns $null, and
# the installer skips the step through its own $exapumpSupported gate).
# Twin of exakit_component_supported in setup/lib/common.sh.
function Test-ExakitComponentSupported {
    param([string]$Component)
    # PROCESSOR_ARCHITECTURE is a Windows variable. It is empty when this file runs
    # under PowerShell on macOS or Linux (tests, cross-platform checks), and an empty
    # value must not be read as "some other architecture".
    if ($Component -eq "exapump" -and $env:PROCESSOR_ARCHITECTURE `
            -and $env:PROCESSOR_ARCHITECTURE -ne "AMD64") { return $false }
    return $true
}


# Can this kit run the advertised Component? An unknown kit version never blocks.
function Test-ExakitMinKitSatisfied {
    param([string]$Required)
    $kit = Get-ExakitComponentCurrent "exakit"
    if (-not $kit -or $kit -eq "unknown") { return $true }
    if ($kit -eq $Required) { return $true }
    return (Test-ExakitVersionNewer -Latest $kit -Current $Required)
}

# Is the installed version newer than the one the manifest publishes?
#
# The kit never moves a component backwards: not on request, not with a
# confirmation, not behind an env override. A user who upgraded pyexasol or
# exapump themselves keeps what they chose, and a maintainer who lowers a version
# in versions.json does not drag anyone back with it - to withdraw a bad release,
# publish a higher version. Returns $true when installed is ahead, so the caller
# can leave the component alone.
function Test-ExakitComponentAhead {
    param([string]$Component)
    $current = Get-ExakitComponentCurrent $Component
    $available = Get-ExakitComponentAvailable $Component
    if (-not $current -or -not $available) { return $false }
    if ($current -eq "unknown" -or $current -eq "not installed") { return $false }
    return (Test-ExakitVersionNewer -Latest $current -Current $available)
}

# Where the Tagged column came from, so nobody has to guess whether a stale
# answer is being shown.
function Write-ExakitVersionsSourceLine {
    if ($script:VersionPolicy -eq "latest") {
        Info "Available versions come from live upstream lookups (EXAKIT_VERSION_POLICY=latest)"
        Write-ExakitOverrideLine
        return
    }
    if ($script:VersionPolicy -ne "manifest") {
        Info "Available versions come from this kit's built-in fallbacks (EXAKIT_VERSION_POLICY=$($script:VersionPolicy), no network)"
        Write-ExakitOverrideLine
        return
    }
    $source = Get-ExakitVersionsSource
    if ($source -ne "fetched" -and $source -ne "cache" -and $source -ne "baked") {
        # Nothing readable anywhere: the rows say "unknown" rather than inventing a
        # number, so say that plainly instead of crediting a source.
        Info "The versions manifest could not be read, so the available versions are unknown"
        Write-ExakitOverrideLine
        return
    }
    switch ($source) {
        "fetched" { $text = "the published versions manifest, fetched just now" }
        "cache"   { $text = "the cached copy of the versions manifest" }
        "baked"   { $text = "the versions manifest that shipped with this kit (no network)" }
    }
    $updated = Get-ExakitVersionsValue -Path "updated"
    if ($updated) { $text = "$text, updated $(Format-ExakitManifestDate $updated)" }
    Info "Available versions from $text"
    if (Test-ExakitVersionsSchemaAhead) {
        Info "This kit is older than the published manifest - update it first: exakit update"
    }
    Write-ExakitOverrideLine
}

# An env override outranks every source above, so say so rather than letting the
# line above take credit for a version the user picked.
function Write-ExakitOverrideLine {
    foreach ($component in @("exapump", "mcp", "pyexasol", "personal")) {
        if (Get-ExakitComponentEnvOverride $component) {
            Info "Some versions come from EXAKIT_* environment overrides and not from the manifest"
            return
        }
    }
}

# --- the heavy (runtime) update, offered inline instead of handed back --------
#
# `exakit update` used to refuse the heavy part outright: it printed "needs the
# database stopped, so it is not part of a routine update" and left the user to
# run `exakit update runtime` themselves, after stopping nothing and updating
# nothing. The work was never the problem - the second command was. On a console
# the offer is now made where the user already is, and one "y" runs the whole
# sequence: stop the database, update the runtime, bring it back up, say so.
#
# Both entry points run the SAME implementation:
# Invoke-ExakitRuntimeComponentUpdate below is what the update loop's runtime
# branch calls and what the inline offer calls.

# Invoke-ExakitRuntimeComponentUpdate - the runtime component updater itself, in
# one place. Twin of the runtime/personal arms of exakit_update_component in
# setup/lib/common.sh.
function Invoke-ExakitRuntimeComponentUpdate {
    param([Parameter(Mandatory)][string]$Component, [string]$Advertised)
    # Defence in depth, mirroring exakit_update_component. The updaters below
    # install whatever version they are handed, so the refusal lives here too and
    # not only in the caller: there is no downgrade in this kit, by any route.
    if (Test-ExakitComponentAhead $Component) {
        Ok "$Component is newer than the tested version - keeping yours"
        return
    }
    switch ($Component) {
        "runtime" {
            if ((Get-RuntimeType) -eq "personal" -and $Advertised) { Update-Personal -Advertised $Advertised }
        }
        "personal" {
            if ($Advertised) { Update-Personal -Advertised $Advertised }
        }
    }
}

# Get-ExakitRuntimeStatus / Start-ExakitRuntime - the runtime-agnostic pair the
# inline offer needs to keep its promise ("the database is running again
# afterwards"). Anything unrecognised answers "" for "cannot tell", which is
# not the same as "not running".
# Twins of exakit_runtime_status / exakit_runtime_start in setup/lib/common.sh.
function Get-ExakitRuntimeStatus {
    switch (Get-RuntimeType) {
        "personal" { try { return (Get-PersonalStatus) } catch { return "" } }
    }
    return ""
}

function Start-ExakitRuntime {
    switch (Get-RuntimeType) {
        # AND THEN WAIT FOR IT. The launcher's start exits 0 without acting in
        # more than one state, so `exakit start` reported success over a
        # database that never came up; Wait-PersonalReadyOrDeploy asks the
        # database instead of the record and runs the launcher's own deploy
        # when nothing answers. The wait lives here rather than inside
        # Start-Personal, which other callers run as a best-effort nudge.
        "personal" {
            Start-Personal
            [void](Wait-PersonalReadyOrDeploy)
        }
    }
}

# Test-ExakitRuntimeUpdateStaged - true for an Exasol Personal MAJOR upgrade: a
# data migration with its own backup-gated three-step flow (--plan, --backup,
# --apply), which a single y/N is not informed consent for.
# Twin of exakit_runtime_update_is_staged in setup/lib/common.sh.
function Test-ExakitRuntimeUpdateStaged {
    param([string]$Installed, [string]$Advertised)
    if ((Get-RuntimeType) -ne "personal") { return $false }
    $installedMajor = Get-ExakitMajorVersion $Installed
    $advertisedMajor = Get-ExakitMajorVersion $Advertised
    if (-not $installedMajor -or -not $advertisedMajor) { return $false }
    return ($installedMajor -ne $advertisedMajor)
}

# Get-ExakitMajorVersion - "2.1.0" -> "2", "v2026.2.0" -> "2026". Empty when
# the string does not start with a number.
# Twin of exakit_major_version in setup/lib/common.sh.
function Get-ExakitMajorVersion {
    param([string]$Version)
    if (-not $Version) { return "" }
    $match = [regex]::Match($Version.TrimStart("v"), '^\d+')
    if ($match.Success) { return $match.Value }
    return ""
}

# Get-ExakitRuntimeUpdatePreanswer - "yes", "no", or "" when nobody has answered
# yet. Two ways to answer without a prompt, and they are the ways this kit already
# uses: `exakit update -Yes` (the uninstall flag spelling, and -y/--yes too) and
# EXAKIT_CONFIRM_RUNTIME_UPDATE, the variable that already pre-answers
# `exakit update runtime`. One opt-in, both entry points.
# Twin of exakit_runtime_update_preanswer in setup/lib/common.sh.
function Get-ExakitRuntimeUpdatePreanswer {
    param([bool]$AssumeYes = $false)
    if ($AssumeYes) { return "yes" }
    $preset = [Environment]::GetEnvironmentVariable("EXAKIT_CONFIRM_RUNTIME_UPDATE")
    if ($preset) {
        if ($preset -cmatch '^(1|y|Y|yes|YES|Yes)$') { return "yes" }
        if ($preset -cmatch '^(0|n|N|no|NO|No)$') { return "no" }
    }
    return ""
}

# Write-ExakitRuntimeUpdateExplanation - what the user is about to agree to,
# before they agree to it: that the database goes down, roughly for how long, that
# it comes back up, and what happens to the data. Stopping a database is
# disruptive and outward-facing; a bare "[y/N]" is not enough to consent to it.
# Twin of exakit_runtime_update_explain in setup/lib/common.sh.
function Write-ExakitRuntimeUpdateExplanation {
    param([string]$Actual, [string]$Installed, [string]$Advertised)
    Warn2 "$Actual $Installed -> $Advertised needs the database stopped."
    switch ($Actual) {
        "personal" {
            Info "The launcher is replaced; the database is checked afterwards and started again if it ends up down - usually under a minute."
            Info "Your data is kept: this update neither deletes nor migrates the tables in your database."
        }
        default {
            Info "The database goes down for the update and is started again afterwards."
            Info "Your data is kept."
        }
    }
}

# Invoke-ExakitRuntimeUpdateApply - stop, update, start, report. Update-Personal
# owns the sequence itself, and it is called here exactly as
# `exakit update runtime` calls it. What this adds is the one thing the prompt
# promises: a database that was up before this command is up after it.
# Twin of exakit_apply_runtime_update in setup/lib/common.sh.
function Invoke-ExakitRuntimeUpdateApply {
    param([Parameter(Mandatory)][string]$Component, [string]$Advertised)
    $wasRunning = ((Get-ExakitRuntimeStatus) -eq "running")
    # The offer above IS the confirmation the runtime updater asks for. Asking one
    # question twice is not a safety feature, so the answer is passed down.
    $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = "1"
    Invoke-ExakitRuntimeComponentUpdate -Component $Component -Advertised $Advertised
    $status = Get-ExakitRuntimeStatus
    if ($wasRunning -and $status -and $status -ne "running" -and $status -ne "starting") {
        Info "Bringing the database back up"
        Start-ExakitRuntime
        $status = Get-ExakitRuntimeStatus
    }
    if ($status -eq "running") {
        Ok "Runtime updated and the database is running again."
    } elseif ($status -eq "starting") {
        Ok "Runtime updated; the database is still coming up - check it with: exakit status"
    } elseif (-not $status) {
        Ok "Runtime updated."
    } else {
        Warn2 "Runtime updated, but the database reports '$status' - start it with: exakit start"
    }
}

# Invoke-ExakitRuntimeUpdateOffer - the heavy part of a routine `exakit update`,
# decided here instead of being handed to the user as homework. Returns $true when
# it was applied, $false when it was deferred (and then prints the exact command
# that applies it later).
#
# On backups: the kit has no data-export facility, and a minor launcher update
# needs none - it replaces the launcher and leaves the deployment's data alone.
# The one runtime change that IS a data migration is the Exasol Personal major
# upgrade, which already has a real backup inside its own three-step flow -
# which is why this function refuses to start it from a y/N.
# Twin of exakit_offer_runtime_update in setup/lib/common.sh.
function Invoke-ExakitRuntimeUpdateOffer {
    param(
        [Parameter(Mandatory)][string]$Component,
        [string]$Actual,
        [string]$Installed,
        [string]$Advertised,
        [bool]$AssumeYes = $false
    )
    if (Test-ExakitRuntimeUpdateStaged -Installed $Installed -Advertised $Advertised) {
        Warn2 "$Actual $Installed -> $Advertised is a major upgrade: it needs a backup and a data migration, so a routine update does not start it."
        return $false
    }
    $preanswer = Get-ExakitRuntimeUpdatePreanswer -AssumeYes $AssumeYes
    if ($preanswer -eq "no") {
        Warn2 "$Actual $Installed -> $Advertised was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        Info "Apply it when convenient:  exakit update"
        return $false
    }
    if ($preanswer -eq "yes") {
        Write-ExakitRuntimeUpdateExplanation -Actual $Actual -Installed $Installed -Advertised $Advertised
    } else {
        # No console, no answer: a prompt nobody can answer must never turn into a
        # stopped database, so a redirected run, a CI job and a scheduled task all
        # get exactly today's safe deferral.
        if (-not (Test-ExakitInteractive)) {
            Warn2 "$Actual $Installed -> $Advertised needs the database stopped, so it is not part of a routine update."
            Info "Apply it when convenient:  exakit update"
            Info "Unattended runs can opt in:  exakit update -Yes  (or EXAKIT_CONFIRM_RUNTIME_UPDATE=1)"
            return $false
        }
        Write-ExakitRuntimeUpdateExplanation -Actual $Actual -Installed $Installed -Advertised $Advertised
        if (-not (Confirm-ExakitPrompt "Stop the database and update the runtime now?" $false)) {
            Info "Nothing was stopped. Apply it when convenient:  exakit update"
            return $false
        }
    }
    Invoke-ExakitRuntimeUpdateApply -Component $Component -Advertised $Advertised
    return $true
}

# Invoke-CmdUpdate - apply the advertised versions. Prints its work plan, not the
# full table. A pending runtime change stops the database, so it is applied only
# for an answer this run was given: the console is asked, -AssumeYes and
# EXAKIT_CONFIRM_RUNTIME_UPDATE answer without asking, and an unattended run with
# neither defers it with the exact command that applies it later.
# Twin of exakit_update in setup/lib/common.sh.
function Invoke-CmdUpdate {
    param([string]$Target = "all", [bool]$AssumeYes = $false)
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not $Target) { $Target = "all" }
    if ($AssumeYes) {
        # -Yes answers the only question this command asks: may it stop the
        # database. The runtime updater reads the same variable, so an
        # explicit `exakit update runtime -Yes` is unprompted for the same reason.
        $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = "1"
    }
    # An explicit update applies what is advertised RIGHT NOW.
    if ($script:VersionPolicy -eq "manifest") {
        # The one phase that can reach the network, so the one most worth
        # narrating: on a network that cannot reach the manifest it is also the
        # longest wait in the command.
        Invoke-ExakitWithSpinner -Label "Checking for newer versions" -Body {
            Update-ExakitVersionsCache -Force | Out-Null
            Resolve-ExakitVersionsDoc | Out-Null
        } | Out-Null
    }
    Write-ExakitVersionsSourceLine
    $deferred = 0
    $acted = 0
    foreach ($component in (Get-ExakitUpdateTargets -Target $Target)) {
        $actual = Get-ExakitActualTarget $component
        $current = Get-ExakitComponentCurrent $actual
        $available = Get-ExakitComponentAvailable $actual
        # No build for this machine: a routine update stays quiet about it (there is
        # nothing the user can do), and an explicit target says why rather than
        # failing deep inside the installer.
        if (-not (Test-ExakitComponentSupported $actual)) {
            if ($Target -eq "all") { continue }
            Fail "$actual has no build for this platform, so there is nothing to update."
        }
        # Nothing advertised for this component (unreadable manifest, or a
        # component this kit knows nothing about): a routine update says so and
        # moves on. An explicit single target still runs, so its updater can
        # report the real reason.
        if ($Target -eq "all" -and -not $available) {
            Warn2 "No advertised version for $actual - skipping it. Details: exakit version"
            continue
        }
        # Never backwards, and this has to be settled BEFORE the heavy branch.
        # That branch gates on $current -ne $available and then continues, so it
        # used to reach the runtime offer with the installed version AHEAD of the
        # tested one and ask to stop the database for a downgrade - while
        # `exakit version` rendered the same row as "none" and every light
        # component said "keeping yours". Different is not behind. Asked once
        # here, for every component, so no later branch can reach an update path
        # by skipping the question.
        if (Test-ExakitComponentAhead $actual) {
            $shown = $current
            if (-not $shown) { $shown = "unknown" }
            Ok "$actual $shown is newer than the tested $available - keeping yours"
            continue
        }
        # A blanket update stops the database only for an answer it was given: on a
        # console it asks, with -AssumeYes or the env var it was already told, and
        # with neither it defers exactly as it always did. See
        # Invoke-ExakitRuntimeUpdateOffer.
        if ($Target -eq "all" -and (Test-ExakitComponentHeavy $actual)) {
            if ($current -and $available -and $current -ne "unknown" -and $current -ne $available) {
                # [-1]: the verdict is the LAST thing the offer returns. The
                # updaters it calls can put objects on the pipeline of their own,
                # and an array is truthy no matter what it holds.
                $applied = @(Invoke-ExakitRuntimeUpdateOffer -Component $component -Actual $actual `
                    -Installed $current -Advertised $available -AssumeYes $AssumeYes)[-1]
                if ($applied -eq $true) { $acted += 1 } else { $deferred += 1 }
            }
            continue
        }
        # Only the components this run will actually touch are reported: the work
        # plan, not a status table. `exakit version` is where everything is
        # listed, including what is already current.
        if ($current -and $available -and $current -eq $available) { continue }
        # The table's "update exakit first" verdict has to hold here too, or the
        # manifest's only hard compatibility lever would be advice nobody applies.
        $minKit = Get-ExakitComponentMinKit $actual
        if ($minKit -and -not (Test-ExakitMinKitSatisfied -Required $minKit)) {
            Warn2 "$actual $available needs kit >= $minKit - update the kit first: exakit update"
            if ($Target -eq "all") { continue }
            Fail "Refusing to install $actual $available on kit $(Get-ExakitComponentCurrent 'exakit')."
        }
        if ($available) {
            $shown = $current
            if (-not $shown) { $shown = "not installed" }
            Info "$actual $shown -> $available"
        }
        switch ($component) {
            "exakit" {
                Update-ExakitSelf -Advertised $available -Installed $current
            }
            "runtime" { Invoke-ExakitRuntimeComponentUpdate -Component "runtime" -Advertised $available }
            "personal" { Invoke-ExakitRuntimeComponentUpdate -Component "personal" -Advertised $available }
            "skills" { Update-ExakitSkills -Advertised $available -Installed $current }
            "exapump" {
                if ($available) {
                    $script:ExapumpVersion = $available
                    Remove-Item -Force (Get-ExapumpCli) -ErrorAction SilentlyContinue
                    Install-Exapump
                    New-ExapumpProfile
                    Set-ExakitManifestValue "desired.exapump" $script:ExapumpVersion
                    # $current above came from Get-ExakitComponentCurrent, i.e. the
                    # version the binary on disk reports - never the manifest record.
                    # Install-Exapump writes that record from the version this run
                    # asked for, so it can name a version that is not what ended up
                    # on disk. Confirm from the binary; exapump_update in
                    # setup/lib/exapump.sh keeps the same order.
                    Confirm-ExapumpInstalledVersion | Out-Null
                }
            }
            "mcp" {
                if ($available) {
                    New-McpUpdateSnapshot | Out-Null
                    $script:McpVersion = $available
                    Install-Mcp
                    # $current above came from Get-ExakitComponentCurrent, i.e. the pin
                    # in the AI client configs - never the manifest record. Install-Mcp
                    # writes that record before the configs are refreshed (the renderer
                    # reads it to build the pin), so the record can say the update
                    # landed while every client still launches the old version. The
                    # refresh below is what actually moves them; mcp_update in
                    # setup/lib/mcp.sh keeps the same order.
                    Update-McpClientPins | Out-Null
                    Test-McpServer
                    Set-ExakitManifestValue "desired.mcp" $script:McpVersion
                }
            }
            "pyexasol" {
                if ($available) { Update-Pyexasol | Out-Null }
            }
            "kit2" { Write-ExakitKit2NotAvailable }
            default {
                # Marketplace add-ons dispatch to their module's update function.
                $addon = Get-ExakitMarketplaceAddon $component
                if ($addon -and $available) {
                    if (Get-Command $addon.UpdateFn -ErrorAction SilentlyContinue) { & $addon.UpdateFn | Out-Null }
                    else { Fail "The $component module is not available in this version." }
                }
            }
        }
        $acted += 1
    }
    if ($acted -eq 0 -and $deferred -eq 0) {
        Ok "Everything is already current."
    }
    if ($deferred -gt 0) {
        Info "See everything, including the deferred runtime change: exakit version"
    }
}

# Kit 2 is delivered by the bash upgrade scripts (upgrade/upgrade-kit2.sh), which
# apply SQL through exapump and stage the semantic assets. That pipeline has no
# Windows counterpart yet, so the commands exist here only to answer clearly
# rather than to fail with "unknown command" - the same treatment the Windows path
# gave kit self-update until it was implemented.
function Write-ExakitKit2NotAvailable {
    param([string]$Command = "")
    # The command is echoed back only when the reader named one that does not
    # exist here. The update path reaches this with nothing to echo: bare
    # `exakit update` IS available on Windows, and naming it in this sentence
    # would say the opposite.
    if ($Command) { Warn2 "Kit 2 is not available on the Windows path yet ($Command)." }
    else { Warn2 "Kit 2 is not available on the Windows path yet." }
    Info "The Kit 2 add-on ships with the macOS, Linux and WSL paths; it is planned for Windows."
}

# Defaults to the version actually installed rather than the newest section in the
# file: a user asking what is new wants their own release notes, not a preview of a
# release they do not have.
function Invoke-CmdWhatsNew {
    param([string]$Version = "")
    if (-not $Version) { $Version = Get-ExakitKitBundledVersion }
    if (-not $Version) { $Version = Get-ExakitManifestValue "kit.version" }
    if (-not $Version) {
        Fail "Could not tell which kit version this is. Name one: exakit whats-new 0.2.0"
    }
    if (-not (Write-ExakitWhatsNew -Version $Version -Heading "What's new in $Version")) {
        $root = Get-ExakitRepoRoot
        $file = Get-ExakitWhatsNewFile -KitRoot $root
        if ($file) {
            Info "No notes for $Version. Versions covered:"
            foreach ($v in (Get-ExakitWhatsNewVersions -KitRoot $root)) { Write-Host ("      " + $v) }
        } else {
            Info "This kit copy does not carry setup/whats-new.json."
        }
    }
}

# ---------------------------------------------------------------------------
# Logs (twin of the exakit_log_targets / exakit_logs_* set in common.sh)
# ---------------------------------------------------------------------------
# One command reaches every log the kit can show. Add-ons opt in with a LogFn
# in their registry entry, so a new one is viewable with no wiring here.
function Get-ExakitLogTargets {
    $targets = @()
    $setup = Get-ChildItem -Path $script:LogDir -Filter "install-*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($setup) {
        $targets += [pscustomobject]@{ Id = "setup"; Label = "Installer and setup runs"; Kind = "file"; Source = $setup.FullName }
    }
    foreach ($addonId in (Get-ExakitMarketplaceInstalledAddons)) {
        $addon = Get-ExakitMarketplaceAddon $addonId
        if (-not ($addon -and $addon.PSObject.Properties["LogFn"] -and
                  (Get-Command $addon.LogFn -ErrorAction SilentlyContinue))) { continue }
        $path = & $addon.LogFn
        if ($path) {
            $targets += [pscustomobject]@{ Id = $addonId; Label = "$addonId service"; Kind = "file"; Source = $path }
        }
    }
    return $targets
}

# Show-ExakitLogsOverviewJson - the same listing, machine-readable, so an agent
# can pick a target and its path without parsing a column-aligned table. Always
# an object, including when there are no logs at all, so a parser never gets
# empty stdout (the rule every other -Json surface follows).
# twin: exakit_logs_overview_json in setup/lib/common.sh.
function Show-ExakitLogsOverviewJson {
    $targets = Get-ExakitLogTargets
    $rows = @()
    foreach ($target in $targets) {
        $size = "-"; $updated = "-"
        if ($target.Kind -eq "cmd") {
            $size = "live"; $updated = "kept by the engine"
        } elseif (Test-Path $target.Source) {
            $item = Get-Item $target.Source
            $size = if ($item.Length -ge 1MB) { "$([int]($item.Length / 1MB))M" }
                    elseif ($item.Length -ge 1KB) { "$([int]($item.Length / 1KB))K" }
                    else { "$($item.Length)B" }
            $updated = $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
        }
        $rows += [pscustomobject]@{
            target  = $target.Id
            what    = $target.Label
            kind    = $target.Kind
            # A command-backed target has no file; null is the honest answer and
            # is what tells a caller to use `exakit logs <target>` instead.
            path    = if ($target.Kind -eq "cmd") { $null } else { $target.Source }
            command = if ($target.Kind -eq "cmd") { $target.Source } else { $null }
            size    = $size
            updated = $updated
        }
    }
    [pscustomobject]@{ count = $rows.Count; targets = @($rows) } | ConvertTo-Json -Depth 6
}

function Show-ExakitLogsOverview {
    $targets = Get-ExakitLogTargets
    if ($targets.Count -eq 0) {
        Info "No logs yet. They appear here after an install or once a service has run."
        return
    }
    Write-Host ""
    Write-Host "  Component logs"
    Write-Host "  --------------"
    Write-Host ("{0,-22} {1,-26} {2,-8} {3}" -f "Target", "What", "Size", "Updated")
    foreach ($target in $targets) {
        if ($target.Kind -eq "cmd") {
            Write-Host ("{0,-22} {1,-26} {2,-8} {3}" -f $target.Id, $target.Label, "live", "kept by the engine")
            continue
        }
        $size = "-"; $updated = "-"
        if (Test-Path $target.Source) {
            $item = Get-Item $target.Source
            $size = if ($item.Length -ge 1MB) { "$([int]($item.Length / 1MB))M" }
                    elseif ($item.Length -ge 1KB) { "$([int]($item.Length / 1KB))K" }
                    else { "$($item.Length)B" }
            $updated = $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
        }
        Write-Host ("{0,-22} {1,-26} {2,-8} {3}" -f $target.Id, $target.Label, $size, $updated)
    }
    Write-Host ""
    Info "View one:  exakit logs <target>        (add -f to follow it live)"
    Info "Its path:  exakit logs <target> --path"
}

function Show-ExakitLog {
    param([Parameter(Mandatory)][string]$Target, [switch]$Follow, [int]$Lines = 200, [switch]$PathOnly)
    $entry = Get-ExakitLogTargets | Where-Object { $_.Id -eq $Target } | Select-Object -First 1
    if (-not $entry) {
        $known = ((Get-ExakitLogTargets | ForEach-Object { $_.Id }) -join " ")
        Fail ("No log called '$Target'." + $(if ($known) { " Available: $known" } else { "" }))
    }
    if ($entry.Kind -eq "cmd") {
        if ($PathOnly) { Write-Host "$($entry.Source) logs $($entry.Container)"; return }
        $engineArgs = @("logs", "--tail", $Lines, $entry.Container)
        if ($Follow) { $engineArgs += "-f" }
        & $entry.Source @engineArgs
        return
    }
    if ($PathOnly) { Write-Host $entry.Source; return }
    if (-not (Test-Path $entry.Source)) {
        Fail "The $Target log has not been written yet ($($entry.Source))."
    }
    if ($Follow) {
        Info "Following $($entry.Source) - Ctrl-C to stop"
        Get-Content -Path $entry.Source -Tail $Lines -Wait
    } else {
        Get-Content -Path $entry.Source -Tail $Lines
    }
}

# exakit logs [target] [-f] [--lines N] [--path] - every log the kit can show,
# in one place. No target lists what is available; a target tails it.
function Invoke-CmdLogs {
    param([string[]]$LogArgs = @())
    $target = ""
    $follow = $false
    $pathOnly = $false
    $json = $false
    $lines = 200
    for ($i = 0; $i -lt $LogArgs.Count; $i++) {
        switch ($LogArgs[$i]) {
            { $_ -in @("-f", "--follow", "-Follow") } { $follow = $true }
            { $_ -in @("--path", "-Path") }           { $pathOnly = $true }
            { $_ -in @("--json", "-j", "-Json") }     { $json = $true }
            { $_ -in @("--lines", "-n", "-Lines") }   { $i++; $lines = [int]$LogArgs[$i] }
            default {
                if ($LogArgs[$i].StartsWith("-")) {
                    Stop-ExakitBadOption "Unknown option '$($LogArgs[$i])' for logs (supported: -f/--follow, --lines N, --path, --json)."
                }
                if ($target) { Fail "Only one log target at a time (got '$target' and '$($LogArgs[$i])')." }
                $target = $LogArgs[$i]
            }
        }
    }
    if (-not $target) {
        if ($json) { Show-ExakitLogsOverviewJson; return }
        Show-ExakitLogsOverview; return
    }
    if ($json) {
        Fail "--json lists the log targets; it does not apply to one target's contents. Use: exakit logs --json, then exakit logs $target --path"
    }
    Show-ExakitLog -Target $target -Follow:$follow -Lines $lines -PathOnly:$pathOnly
}

function Invoke-CmdDataLoad {
    param([string]$Argument = "")
    Assert-ExakitInstalled
    # data-load takes either -Force or a PATH. A path names what to load without
    # walking the menu to type it in - and a folder path is the bulk load: every
    # CSV/Parquet file in it, one table each. Twin of cmd_data_load in exakit.
    $ForceFlag = ""
    $loadPath = ""
    if ($Argument) {
        if ($Argument -eq "-Force" -or $Argument -eq "--force") {
            $ForceFlag = $Argument
        } elseif ($Argument.StartsWith("-")) {
            Stop-ExakitBadOption "Unknown option '$Argument' for data-load (pass -Force, or a file or folder path)."
        } else {
            $loadPath = Get-ExakitNormalizedPath $Argument
            if (-not (Test-Path $loadPath)) { Fail "No such file or folder: $Argument" }
            # Naming a path IS choosing the local-file row, which is exactly what
            # EXAKIT_DATA_FILE already means - so one contract covers the
            # argument and the variable, and the menu never draws for either.
            $env:EXAKIT_DATA_FILE = $loadPath
        }
    }
    Initialize-ExakitLogging
    # Loading data needs a database that answers - a stopped one used to make
    # the dataset checks silently trust the manifest and the load itself fail.
    Confirm-ExakitRuntimeRunning -Deploy
    if ($ForceFlag) {
        $kitRoot = Get-ExakitRepoRoot
        if (-not $kitRoot) { Fail "Could not find the kit's sql/ and data/ files to load." }
        # EXAKIT_DATASETS names WHICH datasets; -Force says "reload them even
        # though they are already there". They compose. -Force used to ignore the
        # variable outright and reload the bundled sample alone, so an unattended
        # reload silently restored one of three datasets and reported success.
        if ($env:EXAKIT_DATASETS) {
            $known = @(Get-ExakitBundledDatasets | ForEach-Object { $_.Id })
            $any = $false
            foreach ($id in ($env:EXAKIT_DATASETS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                if ($known -contains $id) {
                    $any = $true
                    Info "Reloading dataset '$id' (EXAKIT_DATASETS, -Force)"
                    Invoke-ExakitDatasetLoad -KitRoot $kitRoot -Id $id -Force
                } else {
                    Warn2 "Unknown dataset id '$id' in EXAKIT_DATASETS (available: $($known -join ', '))."
                }
            }
            if (-not $any) {
                Fail "EXAKIT_DATASETS='$($env:EXAKIT_DATASETS)' matched no bundled dataset - nothing was reloaded."
            }
            return
        }
        Info "Reloading the bundled sample dataset (log: $script:LogFile)"
        Invoke-ExakitSampleDataLoad -KitRoot $kitRoot -Force
    } elseif ($env:EXAKIT_DATASETS -and -not $env:EXAKIT_DATA_FILE) {
        # Named datasets, unattended: load the ones not yet loaded, say so for
        # the rest, exit 0. This used to fall through to the interactive menu,
        # whose non-interactive default row is the local file. Twin of the same
        # branch in cmd_data_load.
        $kitRoot = Get-ExakitRepoRoot
        if (-not $kitRoot) { Fail "Could not find the kit's sql/ and data/ files to load." }
        $known = @(Get-ExakitBundledDatasets | ForEach-Object { $_.Id })
        $pendingIds = @(Get-ExakitPendingDatasets | ForEach-Object { $_.Id })
        $any = $false
        $failed = $false
        foreach ($id in ($env:EXAKIT_DATASETS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            if ($known -contains $id) {
                $any = $true
                if ($pendingIds -contains $id) {
                    Info "Loading dataset '$id' (EXAKIT_DATASETS)."
                    try { Invoke-ExakitDatasetLoad -KitRoot $kitRoot -Id $id } catch { $failed = $true; Warn2 "Dataset '$id' did not load: $_" }
                } else {
                    Ok "Dataset '$id' is already loaded - nothing to do (reload it with: exakit data-load --force)"
                }
            } else {
                Warn2 "Unknown dataset id '$id' in EXAKIT_DATASETS (available: $($known -join ', '))."
            }
        }
        if (-not $any) { Fail "EXAKIT_DATASETS='$($env:EXAKIT_DATASETS)' matched no bundled dataset - nothing was loaded." }
        if ($failed) { exit 1 }
    } else {
        Show-ExakitDataLoadMenu
    }
}

function Invoke-CmdMcpSetup {
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not (Invoke-McpSetup)) { Fail "Could not complete AI client setup." }
}

function Invoke-CmdMcpOperation {
    param([Parameter(Mandatory)][string]$Operation, [string[]]$OpArgs = @())
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not (Invoke-McpOperation -Operation $Operation -InputArgs $OpArgs)) {
        # In --json mode the report IS the answer: the Fail card would land on
        # stdout after the object (the host writes Write-Host there when
        # redirected) and break every parser with "extra data". Exit 1 quietly;
        # the report's status and remedy already say what is wrong.
        if ($env:EXAKIT_MCP_RESULT_JSON -eq "1") { exit 1 }
        Fail "Could not complete MCP $Operation"
    }
}

function Invoke-CmdCatalog {
    param([string]$Search = "", [switch]$Json)
    # Rendered from the same help documents every other screen uses
    # (setup/help/*.json - see help.ps1). -Json keeps its original shape: one
    # object whose "commands" array carries tool/command/options/description.
    if ($Json) {
        Show-ExakitHelpJson -Which $Search
        return
    }
    Show-ExakitHelpCatalog -Search $Search | Out-Null
}

function Invoke-CmdSkillsInstall {
    Initialize-ExakitLogging
    if (-not (Install-ExakitSkills)) { Fail "Could not install the kit's AI skills" }
}

function Invoke-CmdSkills {
    param([switch]$Json)
    if ($Json) { [void](Show-ExakitSkills -Json) } else { [void](Show-ExakitSkills) }
}

# Invoke-CmdInfoJson - the install record plus the state keys, on stdout. Mirrors cmd_info_json.
#
# manifest.json is what every other command reads: which runtime, which versions,
# which paths, what the last data load did. `exakit info --json` hands that to a
# script or a support thread without anyone having to know where the file lives.
#
# Printed as read rather than through ConvertFrom-Json/ConvertTo-Json: this is a
# copy of the file, and a round trip could only make it disagree with the file
# (PowerShell 5.1's converter also flattens deep nesting and reorders nothing
# predictably). Read as UTF-8 explicitly - 5.1 would otherwise decode the bytes
# as the system ANSI codepage and corrupt any non-ASCII path in there.
#
# Nothing else may reach stdout on this path - no banner, no update notice, no
# hint - or the output stops being JSON. The caller sets $script:JsonOutput so the
# notice gate at the bottom of the dispatcher skips it, and Fail writes to stderr.
#
# Secrets are not a concern here: the manifest stores password *file paths*
# (runtime.password_file, components.mcp_server.connection.password_file), never a
# password. Keep it that way.
function Invoke-CmdInfoJson {
    if (-not (Test-Path $script:ManifestPath)) {
        Write-ExakitNotInstalledAnswer -Json
    }
    $raw = Get-Content -Raw -Encoding UTF8 -Path $script:ManifestPath
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-ExakitNotInstalledAnswer -Json
    }
    # THE SAME TRI-STATE AS `status`, in the exit code AND in the document.
    # AGENTS.md promises `installed`, `status` and `remedy` in every --json
    # answer; this one printed the raw manifest, so a parser branching on
    # .status the way it was told hit a KeyError on exactly the state worth
    # branching on. Twin of cmd_info_json.
    $running = ((Get-ExakitRuntimeStatus) -eq "running")
    try {
        $doc = $raw | ConvertFrom-Json
        # A one-element list was written by PowerShell 5.1 as a bare string
        # ("steps_completed": "launcher"); hand parsers the array they were promised.
        if ($doc.PSObject.Properties["steps_completed"]) { $doc.steps_completed = @($doc.steps_completed | Where-Object { $null -ne $_ }) }
        $doc | Add-Member -NotePropertyName "installed" -NotePropertyValue $true -Force
        # "stopped" - one word per state across all five queries; see the note
        # in the shell twin's cmd_mcp_doctor.
        $statusText = "stopped"
        $remedyText = "exakit start"
        $remedyHint = $null
        if ($running) { $statusText = "running"; $remedyText = $null }
        elseif (-not (Get-RuntimeType)) {
            # No runtime recorded means no database exists yet, so "exakit
            # start" is the one command that cannot help. `status --json`
            # answers "no database" with the installer's own command for this
            # same machine state, and two state queries may not disagree.
            $statusText = "no database"
            $remedyText = (Get-ExakitInstallCommand)
            $remedyHint = "no runtime is recorded yet; the installer resumes at the unfinished step"
        }
        # The same installing state `status --json` answers. Mid-install this said
        # "database not running - exakit start": the one command that must not
        # run underneath a live installer.
        $installStep = "$(Get-ExakitManifestValue 'install.current_step')"
        $installing = ($installStep -ne "" -and (Test-ExakitInstallRunning))
        if ($installing) {
            $statusText = "installing"
            # A RUNNABLE command; the sentence moves to remedy_hint.
            $remedyText = "exakit status --json"
            $remedyHint = "the installer is still running (step: $installStep) - poll the remedy until status is running"
        }
        $doc | Add-Member -NotePropertyName "status" -NotePropertyValue $statusText -Force
        # Kept for callers written against the older shape, the same way the
        # shell twin keeps it.
        if ($statusText -eq "stopped") {
            $doc | Add-Member -NotePropertyName "database" -NotePropertyValue "not running" -Force
        }
        $doc | Add-Member -NotePropertyName "remedy" -NotePropertyValue $remedyText -Force
        if ($remedyHint) { $doc | Add-Member -NotePropertyName "remedy_hint" -NotePropertyValue $remedyHint -Force }
        # The skill set's verdict, from the manifest and the cached versions
        # document (no network). Twin of the skills block in cmd_info_json.
        $ijHave = Get-ExakitManifestValue "components.skills.version"
        $ijWant = Get-ExakitVersionsValue -Path "components.skills.version"
        $ijPending = ($ijHave -and $ijWant -and ("$ijHave" -ne "$ijWant"))
        $doc | Add-Member -NotePropertyName "skills" -NotePropertyValue ([ordered]@{
            installed_version = $(if ($ijHave) { "$ijHave" } else { $null })
            advertised_version = $(if ($ijWant) { "$ijWant" } else { $null })
            status = $(if ($ijPending) { "update_pending" } else { "current" })
            next = $(if ($ijPending) { "exakit update" } else { $null })
        }) -Force
        Write-Output ($doc | ConvertTo-Json -Depth 8)
    } catch {
        Write-Output $raw.TrimEnd("`r", "`n")
    }
    if ($installing -or -not $running) { exit 3 }
    exit 0
}

# Invoke-CmdSql <statement> [-Write] - run one SQL statement and translate the
# error. Twin of cmd_sql in setup/exakit; see there for why it exists (the error
# translator was wired only into the kit's own internal SQL, never the path an
# agent actually runs) and why the statement gate is a seatbelt rather than a
# sandbox - the starter-kit profile is the ADMIN connection, and the real
# boundary is the read-only MCP user.
function Invoke-CmdSql {
    param([string]$Statement, [switch]$Write, [string]$File = "", [switch]$Json)
    # Twin of _sql_reject: in --json mode a refusal is one JSON object on stdout
    # (exit 2 either way, nothing recorded as a failure).
    function Write-ExakitSqlReject([string]$Msg) {
        if ($Json) {
            [ordered]@{ ok = $false; error = $Msg; remedy = $null; rejected = $true } | ConvertTo-Json -Compress | Write-Output
            exit 2
        }
        Write-Host ""; Write-Host "  [x] $Msg"; exit 2
    }
    # In -Json mode the install gate answers in JSON too: the other order left
    # stdout empty on the one path where a parser most needs an answer.
    Assert-ExakitInstalled -Json:$Json
    # The saved-workflow path the skill teaches: `exakit sql --file <path>`.
    # A file's leading "-- comment" line used to be parsed as an option, so the
    # only way to rerun a saved statement was exapump on the admin connection.
    # Twin of the same handling in cmd_sql.
    if ($File) {
        if ($Statement) { Write-ExakitSqlReject "Pass either a statement or --file, not both." }
        if (-not (Test-Path $File)) { Write-ExakitSqlReject "No such file: $File" }
        $Statement = Get-Content -Raw -Encoding UTF8 -Path $File
    }
    if ($Statement) {
        $kept = @(($Statement -split "`r?`n") | Where-Object { $_ -notmatch '^\s*--' -and $_ -notmatch '^\s*$' })
        $Statement = ($kept -join "`n") -replace ';\s*$', ''
    }
    if (-not $Statement) { Write-ExakitSqlReject "Nothing to run. Usage: exakit sql 'SELECT ...'   or   exakit sql --file <path>   [--write]" }

    if (-not $Write) {
        $probe = ($Statement -replace '[\r\n\t]', ' ').TrimStart()
        $word = (($probe -replace '[^A-Za-z].*$', '')).ToUpperInvariant()
        if ($word -in @("SELECT", "WITH", "DESCRIBE", "DESC", "EXPLAIN", "SHOW")) {
            # a read
        } elseif ($word -in @("INSERT", "UPDATE", "DELETE", "MERGE", "CREATE", "DROP", "ALTER", "TRUNCATE", "GRANT", "REVOKE", "COMMIT", "ROLLBACK", "IMPORT", "EXPORT", "EXECUTE", "CALL", "SET", "OPEN", "CLOSE", "KILL", "FLUSH", "RENAME", "COMMENT", "RECOMPRESS", "REORGANIZE", "PRELOAD", "ENFORCE")) {
            Write-ExakitSqlReject "That is not a read statement, and 'exakit sql' defaults to reads. Re-run with --write if you mean it - and note the profile it uses is the ADMIN connection, not the read-only MCP user."
        } else {
            # Neither a read nor a known write is almost always a typo. This used
            # to be reported as a write attempt and pointed at --write, the one
            # hint that sends an agent to the admin connection.
            if (-not $word) { $word = $probe.Substring(0, [Math]::Min(12, $probe.Length)) }
            Write-ExakitSqlReject "'$word' is not an SQL statement this command recognises - check the spelling. Reads start with SELECT, WITH, DESCRIBE, EXPLAIN or SHOW; a write needs --write."
        }
        # Reject a second statement outright. The MCP tool gate lets
        # "SELECT 1; DROP TABLE T" through because it only inspects the opening
        # keyword; refusing it here costs nothing and removes the same footgun.
        if (($probe -replace ';*\s*$', '') -match ';') {
            Write-ExakitSqlReject "Only one statement at a time. A trailing ';' is fine; a second statement is not."
        }
    }

    if ($Json) {
        # One JSON object on stdout, nothing else there. exapump's own
        # `--format json` puts the rows on stdout and every "[1/1] ..." and
        # "1 statement executed" line on stderr, so the two are separable
        # without parsing. Twin of the --json branch in cmd_sql:
        #   {"ok": true,  "rows": [...]}
        #   {"ok": false, "error": "<engine text>", "remedy": "<...>" | null}
        # stdout and stderr kept apart in one pass, each line as its TEXT. The
        # old `2>$errFile` had PowerShell format every stderr line as an error
        # record wrapped at console width, so the engine text in `error` was cut
        # mid-sentence ("... not found [line 1, column 8] (Session:") and the SQL
        # state never made it into the object.
        $outLines = @()
        $errLines = @()
        $code = 1
        $previousEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $captured = @(& (Get-ExapumpCli) @("sql", "-p", $script:ExapumpProfile, "-f", "json", $Statement) 2>&1)
            $code = $LASTEXITCODE
            foreach ($item in $captured) {
                if ($item -is [System.Management.Automation.ErrorRecord]) { $errLines += "$($item.Exception.Message)" } else { $outLines += "$item" }
            }
        } catch {
            $errLines += "$_"
        } finally {
            $ErrorActionPreference = $previousEap
        }
        $rowsText = ($outLines -join "`n")
        $errText = ($errLines -join "`n")
        if ($code -eq 0) {
            # One row object per row - see ConvertFrom-ExakitJsonRows for the
            # {"value":[...],"Count":n} wrapper this used to print on PowerShell 5.1.
            $rows = @(ConvertFrom-ExakitJsonRows -Text $rowsText)
            [ordered]@{ ok = $true; rows = $rows } | ConvertTo-Json -Depth 6 -Compress | Write-Output
            exit 0
        }
        $remedyLines = @(Get-ExakitDbErrorRemedy -Text $errText -Statement $Statement)
        $errLines = @(("$errText" -split "`r?`n") | Where-Object { $_.Trim() })
        # exapump ends a failed run with one "Error: <engine text>" line; that
        # is the message. Failing that, the first failure-looking line that is
        # not exapump's own framing ("Error in statement 1:", "Hint: ...").
        $detail = "query failed"
        $summary = @($errLines | Where-Object { $_.Trim().StartsWith("Error: ") })
        if ($summary.Count -gt 0) {
            $detail = $summary[$summary.Count - 1].Trim().Substring(7)
        } else {
            foreach ($l in $errLines) {
                $t = $l.Trim()
                if (($t -match 'rror' -or $t -match 'failed') -and $t -notlike 'Hint:*' -and $t -notlike 'Error in statement*') { $detail = $t; break }
            }
            if ($detail -eq "query failed" -and $errLines.Count -gt 0) { $detail = $errLines[0].Trim() }
        }
        # The COMMAND and the SENTENCE travel separately: remedy is runnable
        # verbatim or null, and the prose the human path prints is remedy_hint.
        $remedyHint = $null
        if ($remedyLines.Count -gt 0) { $remedyHint = ($remedyLines -join " ") }
        $remedyCmd = Get-ExakitDbErrorRemedyCommand -Text $errText
        if (-not $remedyCmd) { $remedyCmd = $null }
        [ordered]@{ ok = $false; error = $detail; remedy = $remedyCmd; remedy_hint = $remedyHint } | ConvertTo-Json -Depth 3 -Compress | Write-Output
        exit 1
    }
    $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, $Statement)
    if (-not $result.Success) {
        # The whole point: say what to do about it - FIRST, and on the output
        # stream with the error, not as a warning after it. When the kit has a
        # specific remedy, exapump's generic "Hint:" line is noise and is dropped.
        $remedy = @(Get-ExakitDbErrorRemedy -Text $result.Output -Statement $Statement)
        if ($remedy.Count -gt 0) {
            foreach ($line in $remedy) { Write-Output "! $line" }
            if ($result.Output) {
                Write-Output ((($result.Output -split "`r?`n") | Where-Object { $_ -notmatch '^\s*Hint: ' }) -join "`n")
            }
        } elseif ($result.Output) {
            Write-Output $result.Output
        }
        exit 1
    }
    if ($result.Output) { Write-Output $result.Output }
    exit 0
}

# Stop-ExakitBadOption <message> - refuse an unknown option as BAD INPUT: exit 2,
# the code AGENTS.md documents and the bash twin returns. These arms used Fail,
# which exits 1 and records a failure note, so an agent reading the exit code
# saw a broken kit where there was only a typo. Same output as
# Assert-ExakitKnownOptions.
function Stop-ExakitBadOption([string]$Msg) {
    # Delegates rather than duplicating. This function and Deny-ExakitInput
    # were written independently for the same defect - a bad option answered
    # with Fail's exit 1, where the shell CLI answers reject()'s 2 - and kept
    # side by side they would drift, which is the failure mode this repo has
    # been bitten by often enough to have a name for. Deny-ExakitInput is the
    # one with the fuller behaviour: it also honours --json, so a refusal
    # reaches an agent as one object on stdout rather than prose on a stream it
    # is not reading. The name is kept because it reads well at the call sites
    # that use it, and because keeping it costs nothing once it is a delegate.
    Deny-ExakitInput $Msg
}

function Show-ExakitUsage {
    param([string]$Topic = "", [switch]$All, [switch]$Json)
    # Every help screen comes from setup/help/*.json - see help.ps1. Twin of
    # usage() in the bash CLI, including -Json, which hands the underlying
    # document to a script instead of drawing it.
    if ($Topic -eq "--all" -or $Topic -eq "-a") { $All = $true; $Topic = "" }
    if ($Json) {
        if ($Topic) { Show-ExakitHelpJson -Which $Topic } else { Show-ExakitHelpJson -Which "all" }
        return
    }
    if ($All) { Show-ExakitHelpAll | Out-Null; return }
    if (-not $Topic) { Show-ExakitHelpOverview | Out-Null; return }
    if (Test-ExakitHelpId $Topic) { Show-ExakitHelpComponent -Id $Topic | Out-Null; return }
    Show-ExakitHelpCommand -Name $Topic | Out-Null
}

# `exakit <thing> --help` answers from the help documents - the same single
# source of truth `exakit catalog` renders - so every subcommand AND every
# component supports the flag. Twin of the bash pre-dispatch block.
#
# Did this caller ask for a machine answer? Set once, so the paths that REFUSE
# can honour --json and not only the paths that succeed. `sql` is excluded for
# the same reason it is excluded from the help hook below: its argument is
# arbitrary SQL, and a statement containing --json is a query.
$script:ExakitRefusalJson = ($Command -ne "sql") -and
    ((@($RestArgs) -contains "--json") -or (@($RestArgs) -contains "-j"))

# `sql` is excluded on purpose: its argument is arbitrary SQL text.
#
# So is help itself. The -File binder pushes a leading `--help` into $RestArgs
# and leaves $Command at its "help" default, so `exakit --help --json` arrived
# here looking like "the help command, asked for its own help page" and was
# answered with the human page for `help` - swallowing the --json an agent
# asked for. A help flag on the help command is the help command.
$_helpSelf = @("help", "--help", "-h", "-?") -contains "$Command"
if ($Command -and $Command -ne "sql" -and -not $_helpSelf -and ($RestArgs -contains "--help" -or $RestArgs -contains "-h")) {
    if (Test-ExakitHelpId $Command) {
        Show-ExakitHelpComponent -Id $Command | Out-Null
    } else {
        Show-ExakitHelpCommand -Name $Command | Out-Null
    }
    exit 0
}

try {
    # Twin of _exakit_refuse_unknown_options: the ONE rule for options a command
    # does not take - exit 2, nothing runs. Commands with their own option
    # parser (sql, status, version, logs, autostart, data-load, mcp-setup,
    # mcp-status, uninstall) keep it; this covers the rest.
    function Assert-ExakitKnownOptions {
        param([string]$CommandName, [string[]]$Allowed, [string[]]$Arguments)
        foreach ($a in @($Arguments)) {
            if ("$a" -like "-*" -and ($Allowed -notcontains "$a")) {
                if ($Allowed.Count -gt 0) { $msg = "Unknown option '$a' for $CommandName (supported: $($Allowed -join ' '))." }
                else { $msg = "Unknown option '$a' for $CommandName (it takes none)." }
                # --json gets one object on stdout; everyone else gets the card.
                if ($script:ExakitRefusalJson) { Deny-ExakitInput $msg }
                Write-Host ""
                Write-Host "  [x] $msg"
                exit 2
            }
        }
    }
    # THE -File BINDER EATS LEADING-DASH ARGUMENTS, so `exakit --version` never
    # reached the arm written for it.
    #
    # The .cmd shim runs `powershell -File exakit.ps1 %*`, and that binder never
    # lets a "-"-prefixed token fill a positional parameter: `--version` lands
    # in $RestArgs while $Command keeps its "help" default, so the CLI printed
    # the help screen and exited 0. Two things wrong at once - --version is the
    # commonest way anything asks a CLI its version, and a script that asked got
    # a success code with the wrong output and no way to tell.
    #
    # Recovered here rather than in the shim: rewriting the shim to use
    # -Command would put every argument through a second round of cmd.exe and
    # PowerShell quoting, and `exakit sql "SELECT ..."` has to survive intact.
    #
    # `-v` cannot be recovered at all - that binder discards it before the
    # script runs, so it does not even appear in $RestArgs - which is why it is
    # no longer advertised on this side.
    if ($Command -eq "help" -and @($RestArgs).Count -gt 0 -and "$($RestArgs[0])".StartsWith("-")) {
        $leading = "$($RestArgs[0])"
        $rest = @($RestArgs | Select-Object -Skip 1)
        switch ($leading) {
            "--version" { $Command = "version"; $RestArgs = $rest }
            "--help"    { $Command = "help";    $RestArgs = $rest }
            "-h"        { $Command = "help";    $RestArgs = $rest }
            "-?"        { $Command = "help";    $RestArgs = $rest }
            # help's OWN options, left in $RestArgs for the help arm to read.
            #
            # This block cannot tell a $Command that defaulted to "help" from
            # one the user typed, so `exakit help --json` - the documented
            # agent contract, and what the bash CLI answers with a 37-command
            # document - arrived here as an unknown top-level option and was
            # refused outright. Same for --all, which every help screen
            # advertises. They are options of the command, not of the CLI.
            "--json"    { }
            "-j"        { }
            "--all"     { }
            "-a"        { }
            default {
                # An unknown COMMAND already exits 2 with the help screen; an
                # unknown leading OPTION used to exit 0 with it, which is the
                # one shape a caller cannot detect.
                Stop-ExakitBadOption "Unknown option '$leading' (there is no top-level option by that name). Run 'exakit help' for the command list, or 'exakit version' for versions."
            }
        }
    }
    switch ($Command) {
        "preflight"    {
            Assert-ExakitKnownOptions -CommandName "preflight" -Allowed @() -Arguments $RestArgs
            Test-PersonalRequirements
        }
        "status"       {
            $statusJson = ($RestArgs -contains "--json" -or $RestArgs -contains "-j")
            $statusUnknown = @($RestArgs | Where-Object { $_ -notin @("--json", "-j") })
            if ($statusUnknown.Count -gt 0) { Stop-ExakitBadOption "Unknown option '$($statusUnknown[0])' for status (supported: --json)." }
            Invoke-CmdStatus -Json:$statusJson
        }
        "version"      {
            $versionJson = ($RestArgs -contains "--json" -or $RestArgs -contains "-j")
            $versionUnknown = @($RestArgs | Where-Object { $_ -notin @("--json", "-j") })
            if ($versionUnknown.Count -gt 0) { Stop-ExakitBadOption "Unknown option '$($versionUnknown[0])' for version (supported: --json)." }
            if ($versionJson) { $script:JsonOutput = $true }
            Invoke-CmdVersion -Json:$versionJson
        }
        # Reachable when the script is invoked directly (pwsh setup\exakit.ps1
        # --version) rather than through the shim; the block above covers the
        # shim's path. "-v" is deliberately absent: see that block.
        "--version"    { Invoke-CmdVersion }
        "update"        {
            # THE STAGED MAJOR-UPGRADE ROUTE IS NOT ON THIS PLATFORM, and the
            # generic refusal made that look like a typo. The shell CLI
            # implements --plan/--backup/--apply and its header advertised them
            # with no platform qualifier, so a Windows user meeting a Personal
            # MAJOR upgrade was pointed at a migration route and then told
            # "Unknown option '--plan'" - a blocked upgrade and nothing to do
            # about it. Naming the real route costs one arm and is the whole
            # difference between stuck and moving.
            foreach ($_upArg in @($RestArgs)) {
                if (@("--plan", "--backup", "--apply") -contains "$_upArg") {
                    Deny-ExakitInput ("$_upArg is part of the staged major-upgrade route, which the Windows CLI does not implement (it is macOS, Linux and WSL only). " +
                        "To take a major Exasol Personal upgrade here, re-run the installer: irm https://www.exasol.com/install/starter-kit.ps1 | iex")
                }
            }
            Assert-ExakitKnownOptions -CommandName "update" -Allowed @("--yes", "-y", "-Yes") -Arguments $RestArgs
            # -y/--yes/-Yes answers the runtime offer, so it must not be mistaken
            # for the target when it is the only argument given.
            $updateYes = ($RestArgs -contains "-Yes" -or $RestArgs -contains "--yes" -or $RestArgs -contains "-y")
            $updateArgs = @($RestArgs | Where-Object { $_ -notin @("-Yes", "--yes", "-y") })
            Invoke-CmdUpdate -Target ($updateArgs | Select-Object -First 1) -AssumeYes $updateYes
        }
        "info"         {
            Assert-ExakitKnownOptions -CommandName "info" -Allowed @("--json", "-j") -Arguments $RestArgs
            if ($RestArgs -contains "--json" -or $RestArgs -contains "-j") {
                $script:JsonOutput = $true
                Invoke-CmdInfoJson
            } else {
                # THE SAME EXIT CODE AS `info --json` FOR THE SAME MACHINE
                # STATE. AGENTS.md lists `exakit info` in its "Verify the
                # install" block, and the plain form answered 0 off a kit whose
                # database was not running while `info --json` answered 3 - so
                # an agent cross-checking two state queries got two verdicts for
                # one machine. Twin of cmd_info.
                if (-not (Test-Path $script:ManifestPath)) { Write-ExakitNotInstalledAnswer }
                Show-ExakitConnectionPanel
                # The --json form was reachable only from `exakit help`. The hint
                # lives here rather than in Show-ExakitConnectionPanel because the
                # install ends with that same panel, and someone finishing an
                # install is not looking for a JSON dump.
                Write-Host ""
                # Recorded, not exited: the update notice below still runs, the
                # way `_with_notice cmd_info` keeps it on the shell side.
                if ((Get-ExakitRuntimeStatus) -ne "running") { $script:PendingExitCode = 3 }
            }
        }
        "guide"        { Assert-ExakitKnownOptions -CommandName "guide" -Allowed @() -Arguments $RestArgs; Show-ExakitGuide }
        "start"        { Assert-ExakitKnownOptions -CommandName "start" -Allowed @() -Arguments $RestArgs; Invoke-CmdStart }
        "stop"         { Assert-ExakitKnownOptions -CommandName "stop" -Allowed @() -Arguments $RestArgs; Invoke-CmdStop }
        "sql" {
            # A lone --help is unambiguous; a statement may contain the text.
            if (@($RestArgs).Count -eq 1 -and ($RestArgs[0] -eq "--help" -or $RestArgs[0] -eq "-h")) { Show-ExakitUsage -Topic "sql"; break }
            $sqlWrite = ($RestArgs -contains "--write" -or $RestArgs -contains "-Write")
            $sqlJson = ($RestArgs -contains "--json" -or $RestArgs -contains "-j")
            $sqlBad = ""
            $sqlFile = ""
            $sqlRest = @()
            $expectFile = $false
            # Everything after a bare `--` is the statement, never a flag.
            $endOpts = $false
            foreach ($a in @($RestArgs)) {
                if ($expectFile) { $sqlFile = $a; $expectFile = $false; continue }
                if ($endOpts) { $sqlRest += $a; continue }
                # A STATEMENT WHOSE FIRST LINE IS AN SQL COMMENT IS SQL, NOT A
                # FLAG. "-- monthly revenue<newline>SELECT 1" was refused as
                # "Unknown option" with the whole statement echoed into the
                # option slot - and commented SQL is the normal shape of
                # anything an agent shows a user before running, and of anything
                # read out of the workflows folder. Options are single tokens:
                # one that carries a newline, or opens with the "-- " of a
                # comment, is the query. Twin of the same arms in cmd_sql.
                if ($a -like "-- *" -or $a -match "`n") { $sqlRest += $a; continue }
                if ($a -eq "--") { $endOpts = $true; continue }
                if ($a -in @("--write", "-Write", "--json", "-j")) { continue }
                if ($a -in @("--file", "-f", "-File")) { $expectFile = $true; continue }
                if ($a -like "--file=*") { $sqlFile = $a.Substring(7); continue }
                if ($a -like "--*") { $sqlBad = "Unknown option '$a' for sql (supported: --file <path>, --json, --write, --help). If that was your SQL, its first line is a '--' comment: put a space after the dashes, pass the statement after a bare '--', or save it and use exakit sql --file <path>."; break }
                $sqlRest += $a
            }
            if (-not $sqlBad -and $expectFile) { $sqlBad = "--file needs a path: exakit sql --file ~\.exasol-starter-kit\workflows\query.sql" }
            if (-not $sqlBad -and $sqlRest.Count -gt 1) { $sqlBad = "Pass ONE statement, quoted: exakit sql 'SELECT 1'" }
            if ($sqlBad) {
                if ($sqlJson) { [ordered]@{ ok = $false; error = $sqlBad; remedy = $null; rejected = $true } | ConvertTo-Json -Compress | Write-Output; exit 2 }
                Write-Host ""; Write-Host "  [x] $sqlBad"; exit 2
            }
            $sqlText = ""
            if ($sqlRest.Count -eq 1) { $sqlText = $sqlRest[0] }
            Invoke-CmdSql -Statement $sqlText -Write:$sqlWrite -File $sqlFile -Json:$sqlJson
        }
        "migrate" {
            # Its own option parser (values follow their flags), so the generic
            # unknown-option assertion does not apply. Twin of cmd_migrate.
            Invoke-CmdMigrate -Arguments @($RestArgs)
        }
        "repair-runtime" {
            Assert-ExakitKnownOptions -CommandName "repair-runtime" -Allowed @("--yes", "-y", "-Yes", "--json", "-j") -Arguments $RestArgs
            if ($RestArgs -contains "--json" -or $RestArgs -contains "-j") { $script:JsonOutput = $true }
            Invoke-CmdRepairRuntime `
                -Yes:([bool]($RestArgs -contains "--yes" -or $RestArgs -contains "-y" -or $RestArgs -contains "-Yes")) `
                -Json:([bool]($RestArgs -contains "--json" -or $RestArgs -contains "-j"))
        }
        "autostart"    { Invoke-CmdAutostart -Action (($RestArgs | Select-Object -First 1)) }
        "data-load"    { Invoke-CmdDataLoad -Argument ($RestArgs | Select-Object -First 1) }
        "mcp-setup"    {
            # Options are refused, not ignored: `mcp-setup --clients x` used to run
            # the plain setup, say "already connected" and exit 0. Twin of cmd_mcp_setup.
            foreach ($a in @($RestArgs)) {
                if ("$a" -like "-*") { Write-Host ""; Write-Host "  [x] Unknown option '$a' for mcp-setup (it takes none; name clients with EXAKIT_MCP_CLIENTS=claude,codex exakit mcp-setup)."; exit 2 }
                Write-Host ""; Write-Host "  [x] mcp-setup takes no arguments; name clients with EXAKIT_MCP_CLIENTS=$a exakit mcp-setup"; exit 2
            }
            Invoke-CmdMcpSetup
        }
        "mcp-doctor"   {
            # Diagnosis order: a stopped database is diagnosed as exactly that
            # (exit 3, remedy named) before anything that needs it runs - the
            # first downstream failure used to headline as a broken MCP user.
            # Parse BEFORE asserting: the assertion's own answer has to honour
            # --json and exit 4 rather than 1. Reversing these two lines is what
            # made `mcp-doctor --json` print nothing on an uninstalled machine.
            $doctorJson = ($RestArgs -contains "--json" -or $RestArgs -contains "-j")
            Assert-ExakitKnownOptions -CommandName "mcp-doctor" -Allowed @("--json", "-j") -Arguments $RestArgs
            # Mid-install the runtime is not recorded yet, and this answered "not
            # installed", exit 4 - which sends an agent to start a SECOND install.
            # `status` knows the installing state; say the same thing here.
            $doctorStep = "$(Get-ExakitManifestValue 'install.current_step')"
            if ((Test-Path $script:ManifestPath) -and $doctorStep -ne "" -and (Test-ExakitInstallRunning)) {
                if ($doctorJson) {
                    # A RUNNABLE remedy; the sentence lives in remedy_hint.
                    [ordered]@{ installed = $true; status = "installing"; remedy = "exakit status --json"; remedy_hint = "the installer is still running (step: $doctorStep) - poll the remedy until status is running" } | ConvertTo-Json
                } else {
                    Info "The installer is still running (step: $doctorStep) - MCP diagnostics wait for it. Poll: exakit status"
                }
                exit 3
            }
            if (-not (Test-Path $script:ManifestPath)) {
                Write-ExakitNotInstalledAnswer -Json:$doctorJson
            }
            if (-not (Get-RuntimeType)) {
                # A manifest with no runtime is an INCOMPLETE install, not "not
                # installed". This arm used to answer installed: false / exit 4
                # for the exact machine state `status --json` calls installed:
                # true / exit 3 - so an agent cross-checking the two state
                # queries got opposite answers to "is the kit installed?".
                # Twin of the same arm in cmd_mcp_doctor.
                if ($doctorJson) {
                    [ordered]@{
                        installed = $true; status = "no database"; database = "not installed"
                        remedy = (Get-ExakitInstallCommand)
                        remedy_hint = "no runtime is recorded yet; the installer resumes at the unfinished step"
                    } | ConvertTo-Json
                } else {
                    Warn2 "No runtime is recorded in the manifest yet, so there is no database to diagnose against."
                    Info "Finish the install first: $(Get-ExakitInstallCommand)"
                }
                exit 3
            }
            $doctorArgs = @($RestArgs | Where-Object { $_ -notin @("--json", "-j") })
            $doctorType = Get-RuntimeType
            $doctorUp = ($doctorType -eq "personal" -and (Get-PersonalStatus) -eq "running")
            if (-not $doctorUp) {
                if ($doctorJson) {
                    # The same three keys every --json state answer carries.
                    # "stopped", matching status --json and the shell twin.
                    [ordered]@{ installed = $true; status = "stopped"; remedy = "exakit start"; database = "not running" } | ConvertTo-Json
                } else {
                    Warn2 "The database is not running - fix that first: exakit start"
                    Info "MCP diagnostics need a live database (the read-only user and its grants are checked against it)."
                }
                exit 3
            }
            if ($doctorJson) { $env:EXAKIT_MCP_RESULT_JSON = "1" }
            Invoke-CmdMcpOperation -Operation "doctor" -OpArgs $doctorArgs
        }
        "mcp-remove"   {
            # Twin of cmd_mcp_remove: the kit's managed entries out of the named
            # clients, and forgotten. The remedy doctor prints for a client that
            # is gone names this command.
            Assert-ExakitKnownOptions -CommandName "mcp-remove" -Allowed @() -Arguments $RestArgs
            if (@($RestArgs).Count -eq 0) { Write-Host ""; Write-Host "  [x] Name the client(s) to remove the kit's MCP entries from: exakit mcp-remove cursor (see: exakit mcp-status)"; exit 2 }
            if ($RestArgs -contains "all") { Write-Host ""; Write-Host "  [x] mcp-remove takes client names, not 'all' - the full removal is: exakit uninstall"; exit 2 }
            Invoke-CmdMcpOperation -Operation "uninstall" -OpArgs $RestArgs
        }
        "mcp-status"   {
            # The JSON form existed behind an env var the doctor sets for itself;
            # here "--json" was read as a client name.
            $mcpStatusJson = ($RestArgs -contains "--json" -or $RestArgs -contains "-j")
            $mcpStatusArgs = @($RestArgs | Where-Object { $_ -notin @("--json", "-j") })
            foreach ($a in $mcpStatusArgs) { if ($a -like "-*") { Stop-ExakitBadOption "Unknown option '$a' for mcp-status (supported: --json)." } }
            if ($mcpStatusJson) { $env:EXAKIT_MCP_RESULT_JSON = "1"; $script:JsonOutput = $true }
            Invoke-CmdMcpOperation -Operation "status" -OpArgs $mcpStatusArgs
        }
        "skills"       {
            Assert-ExakitKnownOptions -CommandName "skills" -Allowed @("--json", "-j") -Arguments $RestArgs
            if ($RestArgs -contains "--json" -or $RestArgs -contains "-j") {
                # Same reason as `info --json`: a trailing update notice would
                # stop the output being parseable JSON.
                $script:JsonOutput = $true
                Invoke-CmdSkills -Json
            } else {
                Invoke-CmdSkills
            }
        }
        "skills-install" { Assert-ExakitKnownOptions -CommandName "skills-install" -Allowed @() -Arguments $RestArgs; Invoke-CmdSkillsInstall }
        "marketplace"  { Invoke-CmdMarketplace -Arguments $RestArgs }
        "upgrade-kit2"  { Write-ExakitKit2NotAvailable -Command "exakit upgrade-kit2" }
        "rollback-kit2" { Write-ExakitKit2NotAvailable -Command "exakit rollback-kit2" }
        "uninstall"    {
            # One optional positional: a marketplace add-on id for selective
            # removal; validated inside Invoke-CmdUninstall.
            $unAddon = "" + (@($RestArgs | Where-Object { "$_" -notlike "-*" }) | Select-Object -First 1)
            Invoke-CmdUninstall -Addon $unAddon -AssumeYes:($RestArgs -contains "-Yes" -or $RestArgs -contains "--yes" -or $RestArgs -contains "-y") -DryRun:($RestArgs -contains "-DryRun" -or $RestArgs -contains "--dry-run" -or $RestArgs -contains "-n") }
        "whats-new"    { Assert-ExakitKnownOptions -CommandName "whats-new" -Allowed @() -Arguments $RestArgs; Invoke-CmdWhatsNew -Version ($RestArgs | Select-Object -First 1) }
        "logs"         { Invoke-CmdLogs -LogArgs $RestArgs }
        "catalog"      {
            Assert-ExakitKnownOptions -CommandName "catalog" -Allowed @("--json", "-j") -Arguments $RestArgs
            $catJson = ($RestArgs -contains "--json" -or $RestArgs -contains "-j" -or $RestArgs -contains "-Json")
            $catSearch = @($RestArgs | Where-Object { $_ -notin @("--json", "-j", "-Json") }) | Select-Object -First 1
            Invoke-CmdCatalog -Search $catSearch -Json:$catJson
        }
        { $_ -in @("help", "-h", "--help") } {
            # First non-flag argument is the topic: a component id or a command.
            $helpTopic = ""
            foreach ($a in $RestArgs) {
                if ($a -notlike "-*") { $helpTopic = $a; break }
            }
            Show-ExakitUsage -Topic $helpTopic `
                -All:($RestArgs -contains "--all" -or $RestArgs -contains "-a") `
                -Json:($RestArgs -contains "--json" -or $RestArgs -contains "-j")
        }
        default {
            # One object on stdout for a machine, and the whole usage screen
            # NOT dumped into the middle of it.
            if ($script:ExakitRefusalJson) {
                Deny-ExakitInput "Unknown command '$Command'." "exakit catalog --json"
            }
            Write-Host "exakit: unknown command '$Command'" -ForegroundColor Red
            Show-ExakitUsage
            exit 2
        }
    }
    # Only these commands carry the update notice. `version` and `update` render
    # version state themselves, uninstall is a farewell, and help/catalog are
    # reference screens that stay instant and
    # clean. A command that failed reaches the catch below instead, so the notice
    # never talks over an error - and $script:JsonOutput excludes `info --json`,
    # where a notice on stdout would stop the output being parseable JSON.
    if (-not $script:JsonOutput -and
        @("status", "info", "guide", "start", "stop", "data-load", "preflight",
          "skills", "skills-install", "marketplace", "autostart", "logs", "mcp-setup", "mcp-doctor",
          "mcp-status") -contains $Command) {
        Show-ExakitUpdateNotice
    }
    # A state query whose answer IS its exit code, set before the notice so the
    # notice still prints. `exakit info` is the one that uses it today.
    if ($script:PendingExitCode -ne 0) { exit $script:PendingExitCode }
} catch [ExakitFailException] {
    # Fail() already printed the error and the log path; just set the exit code.
    exit 1
} catch {
    Write-Host "  x Unexpected error: $_" -ForegroundColor Red
    exit 1
}
