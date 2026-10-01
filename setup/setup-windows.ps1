# setup-windows.ps1 - Exasol Personal Local Starter Kit, Windows path.
#
# (Renamed during the runtime migration: the Windows database is an Exasol
# Personal deployment now, and the file that installs it is named for the
# platform rather than for an engine it does not use.)
#
# Installs and connects the database, exapump, the Exasol MCP server, and
# pyexasol. Prints connection details when done. The database is an Exasol
# Personal local deployment running through host Podman; the launcher installs
# Podman itself through winget when it is missing.
#
# Usually launched by install.ps1, but runs standalone from a checkout too:
#   powershell -ExecutionPolicy Bypass -File setup\setup-windows.ps1
#
# Safe to re-run: completed steps are skipped, failed steps are retried.

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $PSCommandPath
$LibDir = Join-Path $ScriptDir "lib"
$KitRoot = Split-Path -Parent $ScriptDir

. (Join-Path $LibDir "exakit-common.ps1")
. (Join-Path $LibDir "runtime-personal.ps1")
$legacyModule = Join-Path $LibDir "legacy-crossing.ps1"
if (Test-Path $legacyModule) { . $legacyModule }
. (Join-Path $LibDir "exapump.ps1")
. (Join-Path $LibDir "mcp.ps1")
. (Join-Path $LibDir "pyexasol.ps1")
# Marketplace add-on modules: sourcing installs NOTHING - the modules are
# needed only so the closing marketplace offer can install what the user says
# yes to. A module missing from an older kit copy just skips its row.
foreach ($addonEntry in (Get-ExakitMarketplaceAddons)) {
    $addonModule = Join-Path $LibDir "$($addonEntry.Id).ps1"
    if (Test-Path $addonModule) { . $addonModule }
}

Initialize-ExakitLogging
Initialize-ExakitManifest
# The installer is the one process whose Fail() reason belongs in .last-failure.
$script:ExakitRecordFailureNotes = $true
Resolve-ExakitInstallVersions

if ($env:EXAKIT_BANNER_SHOWN -ne "1") { Write-ExakitBanner "Personal Local Starter Kit" }

Set-ExakitManifestValue "os" "windows"
Set-ExakitManifestValue "arch" $env:PROCESSOR_ARCHITECTURE
$kitSource = if ($env:EXAKIT_KIT_SOURCE) { $env:EXAKIT_KIT_SOURCE } else { "checkout:$KitRoot" }
# BEFORE kit.source is overwritten, because overwriting it is what erases the
# record of where this installation came from.
Show-ExakitKitUpgrade -Installing $env:EXAKIT_KIT_SOURCE
Set-ExakitManifestValue "kit.source" $kitSource
# The kit's own version comes from the versions manifest shipping with THIS
# tree, not from whatever copy an earlier install left under the kit home.
# Record the move BEFORE kit.version is overwritten: the "What's new" box at the
# end of the run reads that record, and it survives a run that dies partway.
Set-ExakitKitUpgradeNote -KitRoot $KitRoot
$kitVersion = Get-ExakitKitVersionAt -KitRoot $KitRoot
if ($kitVersion) { Set-ExakitManifestValue "kit.version" $kitVersion }

# The `exakit` command first, so `exakit status` answers from the first seconds
# of this install (AGENTS.md tells an agent to poll it). It used to be written
# by the LAST step. install.ps1 has already staged the kit copy the shim points
# at; step 6 still records the tick. Twin of exakit_install_helper_early.
$earlyPs1 = Join-Path $script:ExakitHome "kit\setup\exakit.ps1"
if (Test-Path $earlyPs1) {
    try {
        New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
        [void](Set-ExakitCmdShim -PsTarget $earlyPs1)
        # Recorded in the log, not on the screen. Twin of exakit_install_helper_early.
        Write-ExakitLog "INFO" "exakit command ready - exakit status answers from here on"
    } catch { }
}

try {
    # One setup run at a time; the lock's pid is how `exakit status` tells a live
    # install from one that crashed. Twin of exakit_enable_failure_handling.
    Enter-ExakitInstallLock

    # --- step 0: an installation this kit cannot manage ----------------------
    # An older kit could put the database in a container. This asks what to do
    # with it, copies the data out while it is still readable, and stops it so
    # the new deployment can have the port. A machine with no such installation
    # - which is every fresh one - passes straight through.
    if (Get-Command Invoke-LegacyCrossingBefore -ErrorAction SilentlyContinue) {
        Invoke-LegacyCrossingBefore
    }

    # --- step 1: requirements ------------------------------------------------
    Test-PersonalRequirements

    # --- step 2: the launcher --------------------------------------------------
    # Its own step, matching the macOS shape and heading. Twin of the same
    # split in setup-macos.sh and setup-linux.sh.
    if (Begin-ExakitStep "launcher" "Step 1/6  Exasol launcher") {
        Install-PersonalLauncher
        Set-ExakitStepDone "launcher"
    }

    if (Begin-ExakitStep "runtime" "Step 2/6  Local database deployment") {
        $script:PersonalNoDatabase = $false
        Install-PersonalDeployment
        if ($script:PersonalNoDatabase) {
            Register-ExakitSoftFailure -Component "runtime" -Repair (Get-ExakitInstallCommand) `
                -Reason (Get-ExakitFailureReason) -Label "the local database"
            Warn2 "The database was not installed - carrying on so the rest of the install completes"
        } else {
            Set-ExakitStepDone "runtime"
        }
    } else {
        # A deployment recorded by an earlier run can still carry the old
        # container's keys (status read "personal (docker)"); this is the run
        # that clears them.
        Clear-PersonalStaleRecord
        # The resume arms every setup carries: redeploy what is gone, start what
        # is merely stopped - every later step talks SQL to the database.
        # Twin of setup-macos.sh / setup-linux.sh.
        if (-not (Test-PersonalDeploymentExists)) {
            Info "Deployment marked done but not reachable - redeploying"
            $script:PersonalNoDatabase = $false
            Install-PersonalDeployment
            if ($script:PersonalNoDatabase) {
                Register-ExakitSoftFailure -Component "runtime" -Repair (Get-ExakitInstallCommand) `
                    -Reason (Get-ExakitFailureReason) -Label "the local database"
                Warn2 "The database was not installed - carrying on so the rest of the install completes"
            }
        } elseif (-not (Test-PersonalDeploymentRunning)) {
            Info "Database is deployed but not running - starting it"
            # Recorded, not fatal, and for the same reason as the arm above.
            # Invoke-ExakitSoftStep catches Start-Personal's own Fail, which is
            # right for `exakit start` and wrong here, where this is one step of
            # six; Wait-PersonalReadyOrDeploy repairs a start the launcher
            # accepted without acting on. Twin of the subshell in setup-linux.sh.
            [void](Invoke-ExakitSoftStep -Component "runtime" -Repair "exakit start" `
                -Label "the local database" -Body {
                    Start-Personal
                    return (Wait-PersonalReadyOrDeploy)
                })
        }
    }

    # exapump publishes Windows binaries for x86_64 only. On other
    # architectures (e.g. Windows-on-ARM) the exapump, sample-data and AI
    # bridge steps are skipped gracefully instead of aborting an install whose
    # database container is already up and fully usable.
    #
    # The note has to name the WHOLE skip. It used to say "MCP client setup",
    # which reads as "your AI clients are not configured, the bridge is there" -
    # and the bridge is not there: step 3 installs and validates the MCP SERVER
    # too, because the read-only database user it connects as is provisioned
    # through exapump. Understating it is how a reader ends up hunting for a
    # server that was never built.
    # SAID ONCE, not discovered four times. Without a database, exapump has
    # nothing to connect to, the sample data has nowhere to go, the AI bridge
    # cannot provision its read-only user and pyexasol cannot validate - and
    # each of those used to fail on its own, four errors deep, for one cause
    # already named above. Twin of _kss_nodb in kit_shared_steps (common.sh).
    # The exakit helper below still installs: it is the command that finishes
    # the job once Podman is there.
    $dbReady = -not (Test-ExakitSoftFailed "runtime")
    if (-not $dbReady) {
        Info "Skipping exapump, the sample data, the AI bridge and pyexasol - they all need the database, which is not installed"
    }

    $exapumpSupported = ((Get-ExakitHostArch) -eq "amd64")
    if (-not $exapumpSupported) {
        Warn2 "exapump publishes Windows builds for x86_64 only (this machine's hardware is $(Get-ExakitHostArch))."
        Info "Skipping exapump, the sample data and the whole AI bridge (MCP server and clients) - the read-only database user the bridge connects as is provisioned through exapump, so the bridge cannot be built without it."
        Info "The database container itself is fully supported. Details: quickstarts/windows.md"
    }

    # --- step 3: exapump (data loading CLI) ------------------------------------
    if ($dbReady -and $exapumpSupported -and (Begin-ExakitStep "exapump" "Step 3/6  exapump (data loading CLI)")) {
        # Three lines for this step, not nine. Invoke-ExakitLogged animates the
        # label Begin-ExakitStep set, so the Info bullets under it were the
        # second telling. What survives goes through OkStep: what was installed
        # and where, the profile name someone types again, and the one fact the
        # next steps depend on - that the database can persist a schema, not
        # merely answer SELECT 1. Twin of _exakit_install_exapump (common.sh).
        if (Invoke-ExakitSoftStep -Component "exapump" -Repair "exakit update" -Body {
                $prevQuiet = $script:ExakitQuietDetail
                if (Test-ExakitStdoutIsTerminal) { $script:ExakitQuietDetail = $true }
                try {
                    Install-Exapump
                    New-ExapumpProfile
                    Test-ExapumpConnection
                } finally {
                    $script:ExakitQuietDetail = $prevQuiet
                }
            }) {
            Set-ExakitStepDone "exapump"
        }
    } elseif (-not $exapumpSupported) {
        # Say which step is not happening. Begin-ExakitStep is the only thing
        # that prints a step label, so gating the whole call made the screen
        # jump from "Step 2/6" to "Step 5/6" - which reads as output that got
        # lost, not as two steps this machine does not need. Twin of
        # kit_shared_steps (common.sh), which prints this same line when a
        # step is not part of the installation.
        Info "Step 3/6  exapump - not part of this installation, skipping"
    }

    # Load the sample data before any MCP configuration. exapump is now up
    # (its only dependency), and doing this first means the read-only MCP
    # user is provisioned, granted, and posture-checked against a schema
    # that already holds the sample tables - and the AI client has data to
    # query the moment it connects. Wrapped so a failed/declined load never
    # aborts the rest of setup (mirrors kit_shared_steps' `|| true` in bash).
    if (-not $dbReady) {
        # already said above - nothing more to add here
    } elseif ($exapumpSupported -and (Test-ExakitSoftFailed "exapump")) {
        Info "Skipping the sample data - it is loaded with exapump, which is not installed"
    } elseif ($exapumpSupported) {
        # YOUR OWN DATA FIRST, THEN THE SAMPLE. The copy out of the old
        # container needs three things this point in the run is the first to
        # have: a database that is up, an exapump binary, and a profile
        # pointing at the new database. It used to run at the very end, after
        # every other step, which put a user's own tables last in a run that is
        # mostly about them. Twin of the call in exakit_maybe_offer_data_load.
        if (Get-Command Invoke-LegacyCrossingAfter -ErrorAction SilentlyContinue) {
            Invoke-LegacyCrossingAfter
        }
        # THE BRIDGE'S DOWNLOAD STARTS HERE, not two steps later. Priming the
        # MCP package is a network download and an unpack; the load below is a
        # local database reading local files. Neither needs the other, so the
        # download runs underneath the load and Step 4 collects a finished one.
        # See Start-ExakitMcpPrefetch. Twin of the same call in kit_shared_steps.
        if (Get-Command Start-ExakitMcpPrefetch -ErrorAction SilentlyContinue) {
            try { Start-ExakitMcpPrefetch } catch { }
        }
        [void](Invoke-ExakitBestEffort -Component "sample_data" -Repair "exakit data-load" `
            -Label "sample data" `
            -Warning "Sample data load did not finish cleanly." `
            -Body { Request-ExakitDataLoadOffer -KitRoot $KitRoot })
    }

    # --- step 3: AI bridge (server, clients, skills) ----------------------------
    if ($dbReady -and $exapumpSupported -and (Begin-ExakitStep "mcp" "Step 4/6  AI bridge (MCP server, clients and skills)")) {
        if (Invoke-ExakitSoftStep -Component "mcp" -Repair "exakit update" -Body {
                # One line for this step's server work: the spinner narrates
                # the prime and the handshake, so the Info/Ok pairs beneath
                # were the second telling. try/finally because the body can
                # throw and this is a soft step - a leaked quiet flag would
                # silence every step after it.
                # Twin of _exakit_install_mcp (common.sh).
                $prevQuiet = $script:ExakitQuietDetail
                if (Test-ExakitStdoutIsTerminal) { $script:ExakitQuietDetail = $true }
                try {
                    Install-Mcp
                    Test-McpServer
                } finally {
                    $script:ExakitQuietDetail = $prevQuiet
                }
            }) {
            Set-ExakitStepDone "mcp"
        }
    } elseif (-not $exapumpSupported) {
        Info "Step 4/6  AI bridge (MCP server, clients and skills) - not part of this installation, skipping"
    }

    # The AI bridge is finished HERE, in the step that says it is being built:
    # the server, the clients that talk to it, the skills those clients load, and
    # the "restart your client" line that makes all three take effect. These two
    # offers used to run at the very end of the run instead - so a reader watched
    # this step announce the AI bridge, sat through pyexasol and the exakit
    # helper, and was then asked which AI clients to connect, under no step at
    # all. The step numbering said one thing and the screen did another.
    #
    # Nothing here needs a later step. The client configs point at `uvx
    # <mcp-server>`, never at the exakit command, and the repo-root lookup falls
    # back to the checkout for skills\ when the helper step has not staged its
    # copy yet. What they DO need is the database and exapump, two steps back.
    # Twin of the same block in kit_shared_steps (common.sh).

    # Gated on $exapumpSupported like the step that builds the bridge. Ungated,
    # the installer skipped building the AI bridge and then asked which AI
    # clients to connect to it - pointing them at an MCP server this run never
    # installed and a read-only database user it never provisioned. The skills
    # offer below stays unconditional: skills are documents an AI client reads,
    # and they are just as useful with the database alone.
    if ($dbReady -and $exapumpSupported) {
        [void](Invoke-ExakitBestEffort -Component "mcp_clients" -Repair "exakit mcp-setup" `
            -Label "AI client (MCP) setup" `
            -Warning "Your local runtime is installed, but MCP client setup did not finish cleanly." `
            -Body { Request-ExakitMcpSetupOffer })
    }

    [void](Invoke-ExakitBestEffort -Component "skills" -Repair "exakit skills-install" `
        -Label "AI skills" `
        -Warning "Skills install did not finish cleanly." `
        -Body { Request-ExakitSkillsInstallOffer })

    # --- step 5: pyexasol (Exasol Python driver) --------------------------------
    # Not gated on $exapumpSupported: pyexasol is pure Python via uv, so it
    # works on Windows-on-ARM too, where only exapump's binary is missing.
    # A failed pyexasol install must not end the run: the exakit helper step
    # below still has to happen, or the user is left without the command that
    # manages everything else. The step stays unmarked so a re-run retries it.
    #
    # Test-PyexasolConnection runs INSIDE the soft step. Outside it, the step was
    # soft in name only: the driver could install fine and any Fail() raised while
    # validating (an unwritable manifest, say) still ended the run before the
    # exakit helper below existed. Install and validate are one isolated unit.
    if ($dbReady -and (Begin-ExakitStep "pyexasol" "Step 5/6  pyexasol (Exasol Python driver)")) {
        # Two lines for this step, not five: the outcome, and the interpreter to
        # run it with. Everything between is in the logfile, and the spinner
        # covered it live. Twin of _exakit_install_pyexasol (common.sh).
        if (Invoke-ExakitSoftStep -Component "pyexasol" -Repair "exakit update" -Body {
                $prevQuiet = $script:ExakitQuietDetail
                if (Test-ExakitStdoutIsTerminal) { $script:ExakitQuietDetail = $true }
                try {
                    if (-not (Install-Pyexasol)) { return $false }
                    Test-PyexasolConnection
                    return $true
                } finally {
                    $script:ExakitQuietDetail = $prevQuiet
                }
            }) {
            Set-ExakitStepDone "pyexasol"
        }
    }

    # --- step 6: exakit helper command ------------------------------------------
    # The step flag alone is not trusted: if the shim was removed (cleanup,
    # testing, older builds), a re-run must reinstall it rather than skip -
    # and the PATH check must run either way, since the PATH entry can be
    # missing even when the step is marked done.
    $helperNeeded = Begin-ExakitStep "exakit_helper" "Step 6/6  exakit helper command"
    if (-not $helperNeeded -and -not (Test-Path (Join-Path $script:BinDir "exakit.cmd"))) {
        Info "exakit command is missing - reinstalling it"
        $helperNeeded = $true
    }
    # A re-run over an older install arrives with the flag set and a shim already
    # on disk, so "installed" is not the same as "current". Rewrite one an older
    # kit left behind, or one aimed at a path this kit no longer uses.
    if (-not $helperNeeded -and
        -not (Test-ExakitCmdShimCurrent -PsTarget (Join-Path $script:ExakitHome "kit\setup\exakit.ps1"))) {
        Info "exakit command is out of date - refreshing it"
        $helperNeeded = $true
    }
    if (-not $helperNeeded) {
        Confirm-ExakitOnPath $script:BinDir
    }
    if ($helperNeeded) {
        New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null

        # Keep a copy of the kit library (and the mcp/, sql/, data/ packages
        # Get-ExakitRepoRoot depends on) next to the state so exakit finds
        # them even when this checkout disappears. Copy-ExakitAsset skips any
        # copy whose source already IS the destination - which is the case
        # when install.ps1 downloaded the kit straight into
        # ~\.exasol-starter-kit\kit and ran setup from there.
        $kitSetupDir = Join-Path $script:ExakitHome "kit\setup"
        New-Item -ItemType Directory -Force -Path $kitSetupDir | Out-Null
        # CLEAR WHAT WE ARE ABOUT TO REPLACE. A copy merges, it does not mirror,
        # so a module the new kit DELETED goes on living in the staged copy -
        # and the staged copy is what an installed exakit loads. Installing over
        # the official kit left its nano.ps1, runtime-nano.sh and catalog.tsv in
        # lib\, three files this kit removed on purpose. Twin of the same clear
        # in kit_shared_steps.
        #
        # ONLY WHEN THIS IS NOT THE KIT HOME ITSELF. install.ps1 unpacks the kit
        # into ~\.exasol-starter-kit\kit and runs setup from there, so these
        # "stale" directories are this run's own sources: clearing them deleted
        # setup\help, and every Copy-ExakitAsset below then found no source and
        # returned without a word. With no help documents on disk the
        # marketplace lost its tagline tier and every add-on's Description read
        # "Details: exakit help <id>". The bash twin skips the whole block on the
        # same condition ([ "$_script_dir" -ef "$EXAKIT_HOME/kit/setup" ]).
        $kitSetupInPlace = $false
        try {
            $kitSetupInPlace = [string]::Equals(
                (Resolve-Path $ScriptDir).Path.TrimEnd('\', '/'),
                (Resolve-Path $kitSetupDir).Path.TrimEnd('\', '/'),
                [System.StringComparison]::OrdinalIgnoreCase)
        } catch { }
        if (-not $kitSetupInPlace) {
            foreach ($stale in @(
                (Join-Path $kitSetupDir "lib"), (Join-Path $kitSetupDir "help"),
                (Join-Path $script:ExakitHome "kit\mcp"), (Join-Path $script:ExakitHome "kit\sql"),
                (Join-Path $script:ExakitHome "kit\skills"))) {
                Remove-Item -Recurse -Force $stale -ErrorAction SilentlyContinue
            }
        }
        Copy-ExakitAsset -Source $LibDir -Destination (Join-Path $kitSetupDir "lib")
        Copy-ExakitAsset -Source (Join-Path $ScriptDir "exakit.ps1") -Destination (Join-Path $kitSetupDir "exakit.ps1")
        # skills/ is not optional decoration: exakit skills, exakit
        # skills-install and the post-install skills step all resolve through
        # the repo-root lookup, which PREFERS this staged copy. Omitting it does
        # not fall back to the checkout - it shadows it, so every one of those
        # commands reports "no skills/ directory in this kit build".
        foreach ($dir in @("mcp", "sql", "data", "skills")) {
            Copy-ExakitAsset -Source (Join-Path $KitRoot $dir) -Destination (Join-Path $script:ExakitHome "kit\$dir")
        }
        # The versions manifest travels with the copy: it is the offline tier of
        # version resolution and the record of which kit version this is.
        Copy-ExakitAsset -Source (Join-Path $KitRoot "versions.json") -Destination (Join-Path $script:ExakitHome "kit\versions.json")
        Copy-ExakitAsset -Source (Join-Path $KitRoot "setup\whats-new.json") -Destination (Join-Path $script:ExakitHome "kit\setup\whats-new.json")
        # setup\help\ is the WHOLE help corpus - one JSON per topic, and
        # `exakit help <topic>` resolves through the repo-root lookup, which
        # PREFERS this staged copy. Omitting it did not fall back to the
        # checkout, it shadowed it: on every installed kit `exakit help mcp`,
        # `exapump`, `personal`, `pyexasol`, `exakit` and all add-ons answered
        # "No help entry for ...".
        #
        # It also silently broke the marketplace. An add-on's description falls
        # back to the `tagline` in its help document when the GitHub About
        # cannot be fetched, so with no documents staged every add-on in the
        # table read "Details: exakit help <id>" - pointing at the very command
        # this omission had disabled. Same shape as the skills note above.
        Copy-ExakitAsset -Source (Join-Path $KitRoot "setup\help") -Destination (Join-Path $script:ExakitHome "kit\setup\help")

        # Set-ExakitCmdShim owns the shim's content (the kit self-update writes the
        # same file, so it must not drift): the bare `exakit` command is ONLY the
        # .cmd, pointing at the kit's copy by absolute path.
        $shimPath = Set-ExakitCmdShim -PsTarget (Join-Path $kitSetupDir "exakit.ps1")

        Confirm-ExakitOnPath $script:BinDir
        Set-ExakitStepDone "exakit_helper"
        OkStep "exakit installed ($(Get-ExakitTilde (Join-Path $script:BinDir 'exakit.cmd')))"
    }

    # The upgrade news (Write-ExakitWhatsNewBox) and the closing summary
    # (Write-ExakitSoftFailures) are printed after the connection panel at the
    # very end of the run - not here, in the middle of the step output where
    # the connection details would push them off the screen.

    # The other half of the crossing. Last, because it needs all three things
    # the steps above provide: a database that is up, an exapump binary, and a
    # profile pointing at the NEW database.
    if (Get-Command Invoke-LegacyCrossingAfter -ErrorAction SilentlyContinue) {
        Invoke-LegacyCrossingAfter
    }

    Show-ExakitConnectionSummary
    # Only when the kit version moved during this run, and never able to fail it:
    # every reader inside degrades to silence.
    Write-ExakitWhatsNewBox -KitRoot $KitRoot
    # Last on screen, after the payoff panel: anything that did not complete, with
    # the one command that installs it. A step that failed mid-run scrolls away;
    # this is what the user is still looking at when the installer exits.
    Write-ExakitSoftFailures
    # The install's one closing line, after the panel and after anything that
    # did not finish. Silent when a soft failure was recorded.
    Write-ExakitReadyLine
    # The closing offer: optional marketplace add-ons, asked exactly once, only
    # on an interactive run whose steps all completed, and only while something
    # is actually on offer (an add-on already on this machine is never
    # advertised). Best-effort: nothing in it may end an install that already
    # succeeded.
    # Automatic start defaults to ON for a fresh install: the kit's promise is a
    # database that is simply there, and leaving it off meant a reboot quietly
    # took it away. Only applied when the manifest has no opinion yet, so
    # `exakit autostart off` survives a re-run. Before the offer, so an add-on
    # installed from it joins the boot set.
    [void](Invoke-ExakitBestEffort -Component "autostart" -Repair "exakit autostart" `
        -Label "automatic start" `
        -Warning "Automatic start could not be turned on." `
        -Body { Enable-ExakitAutostartDefault })
    [void](Invoke-ExakitBestEffort -Component "marketplace" -Repair "exakit marketplace" `
        -Label "marketplace add-ons" `
        -Warning "The marketplace offer did not finish cleanly." `
        -Body { Request-ExakitMarketplaceOffer })
    # A rule, then a heading: the last line on screen is where the reader is
    # left, and run together with whatever the marketplace printed it read as
    # one more of its bullets. The rule gives it air; the green arrow says it
    # is not a step.
    # The install is complete: the step marker `exakit status` reads back as
    # "installing" goes with it. Twin of the same clear in exakit_finish.
    try { Remove-ExakitManifestValue "install.current_step" } catch { }
    # A run that finished with every step complete has nothing pending: a note
    # left from an earlier failed run would otherwise outlive its cause.
    if ($script:ExakitSoftFailed.Count -eq 0) {
        try { Remove-Item -Path $script:FailureNotePath -Force -ErrorAction SilentlyContinue } catch { }
    }
    Exit-ExakitInstallLock
    Write-ExakitRule
    Write-ExakitHeading "Run ""exakit help"" for support"
    # Two blank lines before the console prompt returns. The installer's last
    # line was landing directly against it, so the prompt read as part of the
    # output.
    Write-Host ""
    Write-Host ""
} catch [ExakitFailException] {
    # A hard stop (no container runtime, no database) still owes the user the
    # account of what had already been skipped before it.
    Write-ExakitSoftFailures
    Exit-ExakitInstallLock
    exit 1
} catch {
    # Same "card" shape as Fail(): prominent x header + dim gutter line to the log.
    Write-Host ""
    Write-Host ("  {0}{1} {2}Unexpected error: $_{3}" -f $script:UiErr, $script:UiCross, $script:UiBold, $script:UiReset)
    if ($script:LogFile) { Write-Host ("    {0}{1} Log: {2}{3}" -f $script:UiDim, $script:UiVB, $script:LogFile, $script:UiReset) }
    Write-ExakitSoftFailures
    Exit-ExakitInstallLock
    exit 1
} finally {
    # STOP ANIMATING BEFORE ANYTHING ELSE. The spinner runs in its own runspace,
    # and a live runspace keeps Windows PowerShell 5.1 from terminating - so a
    # run that ended while one was spinning printed its last line and then sat
    # there, which reads as a hang rather than as a finished install. Fail()
    # stops it on the path it owns; this covers every other way out, including
    # the ones nobody has thought of yet.
    try { Stop-ExakitAnimation } catch { }
    # A prefetch that never got collected (the MCP step was skipped, or the run
    # is ending early) must not outlive the installer. This finally is the one
    # place every exit passes through. Twin of the same call in exakit_finish.
    if (Get-Command Stop-ExakitMcpPrefetch -ErrorAction SilentlyContinue) {
        try { Stop-ExakitMcpPrefetch } catch { }
    }
    Exit-ExakitInstallLock
}
