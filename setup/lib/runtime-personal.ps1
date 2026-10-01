# runtime-personal.ps1 - Exasol Personal local runtime module (Windows).
#
# Twin of setup/lib/runtime-personal.sh, at the eleven-function contract the
# rest of the kit actually calls - not a line-for-line port of its 1,200 lines.
# Dot-sourced by exakit-common.ps1 consumers after that file has loaded; every
# helper this module leans on (Info/Ok/Warn2/Fail, the manifest, credentials,
# bounded probes, downloads) lives there.
#
# Launcher facts, from the same release this module downloads:
#   - the Windows asset is exasol-personal_Windows_x86_64.zip + checksums;
#     there is NO Windows arm64 local deployment
#   - the database runs through HOST Podman inside Podman's default machine;
#     a missing Podman is offered for install by the launcher itself (winget,
#     possibly with an administrator prompt) - the kit never installs it
#   - that default machine is shared host-wide: the launcher never reconfigures
#     an existing one and leaves it running after stop and destroy, so this
#     module owns the DEPLOYMENT and nothing else
#   - deployment state: ~\.exasol\personal\deployments\default
#   - from 2.3, non-interactive host preparation FAILS without --auto-approve;
#     the flag is probed per subcommand exactly as the sh side does

$script:PersonalRepo            = "exasol/exasol-personal"
# 2.3.0 FINAL since 2026-09-21. This was a release candidate, and candidates
# get deleted: rc2 and rc3 were both removed upstream while pinned here, and
# rc3 reached a user as a 404 mid-install. A published release is not removed
# that way, so this is the first pin here that is not living on borrowed time.
# Twin of EXAKIT_PERSONAL_VERSION_FALLBACK in common.sh; both move together,
# and both were checked against the upstream release before being written.
$script:PersonalVersionFallback = "2.3.0"
$script:PersonalPort            = 8563
$script:PersonalProbeTimeout    = if ($env:EXAKIT_PERSONAL_PROBE_TIMEOUT) { [int]$env:EXAKIT_PERSONAL_PROBE_TIMEOUT } else { 10 }
$script:PersonalMinRamGb        = if ($env:EXAKIT_PERSONAL_MIN_RAM_GB)  { [int]$env:EXAKIT_PERSONAL_MIN_RAM_GB }  else { 8 }
$script:PersonalMinDiskGb       = if ($env:EXAKIT_PERSONAL_MIN_DISK_GB) { [int]$env:EXAKIT_PERSONAL_MIN_DISK_GB } else { 20 }
$script:PersonalBinPath         = Join-Path $script:BinDir "exasol.exe"
# Get-ExakitProfileHome, not $HOME: on a domain-joined machine PowerShell's
# $HOME is the account's home-directory attribute (H:\, \\server\share\user),
# and the deployment cannot live there. Twin of the same rule in
# exakit-common.ps1, which is dot-sourced before this file.
$script:PersonalDeployDir       = if ($env:EXAKIT_PERSONAL_DEPLOY_DIR) { $env:EXAKIT_PERSONAL_DEPLOY_DIR } else { Join-Path (Get-ExakitProfileHome) ".exasol\personal\deployments\default" }
$script:PersonalRebuildNoted    = $false

# Get-PersonalTargetVersion - the launcher version this kit installs or updates
# to: the env override, the advertised manifest, the fallback - the same
# resolution order the sh side gets from exakit_resolve_install_versions.
function Get-PersonalTargetVersion {
    if ($env:EXAKIT_PERSONAL_VERSION) { return $env:EXAKIT_PERSONAL_VERSION }
    $advertised = Get-ExakitComponentAvailable "personal"
    if ($advertised) { return $advertised }
    return $script:PersonalVersionFallback
}

# Get-PersonalCli - the kit-managed launcher when it exists, a launcher on PATH
# otherwise, and the kit-managed path as the answer either way when neither
# runs (so error messages name where it WOULD be). Twin of personal_cli.
function Get-PersonalCli {
    if (Test-Path $script:PersonalBinPath) { return $script:PersonalBinPath }
    $onPath = Get-Command exasol -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $script:PersonalBinPath
}

# Get-PersonalDbPort - the port THIS deployment is on, which is not necessarily
# $script:PersonalPort: from 2.3 the launcher selects and persists a concrete
# port. deployment.json is the answer; the constant only until one exists.
# Twin of personal_db_port, regex and all - no JSON parser on the status path.
function Get-PersonalDbPort {
    $file = Join-Path $script:PersonalDeployDir "deployment.json"
    if (Test-Path $file) {
        try {
            $raw = [System.IO.File]::ReadAllText($file)
            if ($raw -match '"dbPort"\s*:\s*(\d+)') { return [int]$Matches[1] }
        } catch { }
    }
    return $script:PersonalPort
}

# Get-PersonalLauncherVersion - the version of the launcher BINARY on this
# machine, asked of the binary itself ("exasol version" prints it bare). The
# deployment's version and the launcher's are two different facts; conflating
# them made a completed update advertise itself forever. Twin of
# personal_launcher_version.
function Get-PersonalLauncherVersion {
    $out = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @("version") -TimeoutSeconds $script:PersonalProbeTimeout
    if (-not $out) { return $null }
    $raw = ($out -split "`n")[0].Trim() -replace '^v', ''
    if ($raw -notmatch '^[0-9][0-9A-Za-z.+_-]*$') { return $null }
    return $raw
}

# Get-PersonalDeployedVersion - the launcher version that created the deployment
# on disk; $null when there is no deployment or its state cannot say. Read from
# STATE, never by executing a launcher - the decision this feeds is made before
# any binary is installed. Twin of personal_deployed_version.
function Get-PersonalDeployedVersion {
    if (-not (Test-Path $script:PersonalDeployDir)) { return $null }
    $bare = Join-Path $script:PersonalDeployDir ".exasolLauncher.version"
    $raw = ""
    if (Test-Path $bare) {
        try { $raw = ([System.IO.File]::ReadAllText($bare)).Trim() } catch { }
    }
    if (-not $raw) {
        $state = Join-Path $script:PersonalDeployDir ".exasolLauncherState.json"
        if (Test-Path $state) {
            try {
                $text = [System.IO.File]::ReadAllText($state)
                if ($text -match '"deploymentVersion"\s*:\s*"([^"]*)"') { $raw = $Matches[1] }
            } catch { }
        }
    }
    $raw = $raw -replace '^v', ''
    # Only answer with something that looks like a version: garbage must read as
    # "unknown" and let the install proceed, never as a version that blocks it.
    if ($raw -notmatch '^[0-9][0-9A-Za-z.+_-]*$') { return $null }
    return $raw
}

# Test-PersonalLauncherSupports <token> - does the launcher's TOP-LEVEL help
# name this subcommand? Line-anchored like personal_help_names_token: a help row
# reading "stop   Stop a running local deployment" must not satisfy "local".
function Test-PersonalLauncherSupports {
    param([Parameter(Mandatory)][string]$Token)
    $help = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @("--help") -TimeoutSeconds $script:PersonalProbeTimeout
    if (-not $help) { return $false }
    $anchored = '(?m)^\s*(-[-a-zA-Z0-9]+,\s*)?' + [regex]::Escape($Token) + '(\s|,|$)'
    return [bool]($help -match $anchored)
}

# Get-PersonalAutoApproveFlag <subcommand> - "--auto-approve" when this launcher
# takes it there, $null when it does not. Probed on the SUBCOMMAND's help: a
# subcommand's flags never appear at the top level, so the probe above would
# answer "no" for every launcher including the 2.3 ones that need this most.
# A launcher that does not know the flag is never handed it - an unknown flag
# is a hard failure and 2.2 deployments stay supported. Twin of
# personal_auto_approve_flag.
function Get-PersonalAutoApproveFlag {
    param([Parameter(Mandatory)][string]$Subcommand)
    $help = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @($Subcommand, "--help") -TimeoutSeconds $script:PersonalProbeTimeout
    if (-not $help) { return $null }
    if ($help -match '(?m)^\s*(-[-a-zA-Z0-9]+,\s*)?--auto-approve(\s|,|$)') { return "--auto-approve" }
    return $null
}

function Test-PersonalDeploymentExists {
    if (-not (Test-Path $script:PersonalDeployDir)) { return $false }
    $answer = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @("info") -TimeoutSeconds $script:PersonalProbeTimeout
    return ($null -ne $answer)
}

# Test-PersonalDbAnswers - is the thing on the SQL port actually Exasol? A real
# SELECT through the kit's exapump profile when that module is loaded (it is,
# in the CLI and the installer); without it, a completed TLS handshake
# (Test-PersonalTlsAnswers). A port that is merely open is never the answer
# (see Get-PersonalStatus for why) - and under rootless Podman the open port
# is pasta's, there from the moment the container starts and a minute or more
# before the database inside it accepts a connection. Twin of
# personal_db_answers.
function Test-PersonalDbAnswers {
    # THE HANDSHAKE ALONE, for a deployment that is ours. Asking exapump for a
    # SELECT here made the database's liveness depend on a second tool: when a
    # virus scanner held the freshly installed exapump.exe, every probe said
    # "not running" about a database that was up, and the installer went on to
    # "self-heal" it. Proving WHOSE database answers is a different question,
    # asked only where it arises - see Test-PersonalDeploymentRunning.
    return (Test-PersonalTlsAnswers)
}

# Test-PersonalTlsAnswers - does the database complete a TLS handshake on its
# port? The one probe that tells a database apart from the process publishing
# its port: pasta (rootless Podman) and the launcher's own runner accept the
# TCP connection themselves and reset it when nothing answers behind them,
# which every SQL client reports as "tls handshake eof" - the launcher's own
# 27-second first-boot budget ran out on exactly that, and a port-open wait
# returned the instant the container started. The certificate is self-signed
# by design, so it is accepted, not validated. Twin of personal_tls_answers.
function Test-PersonalTlsAnswers {
    $port = Get-PersonalDbPort
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect("127.0.0.1", $port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(700, $false)) { return $false }
        $client.EndConnect($async)
        $ms = $script:PersonalProbeTimeout * 1000
        $client.ReceiveTimeout = $ms
        $client.SendTimeout = $ms
        $accept = [System.Net.Security.RemoteCertificateValidationCallback]{ $true }
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $accept)
        try {
            $ssl.AuthenticateAsClient("localhost")
            return $true
        } finally {
            $ssl.Dispose()
        }
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# Get-PersonalForeignDbHint - one sentence for a port that answers like Exasol
# but is not this kit's deployment; empty when nothing completes a handshake.
# Windows and WSL share one network stack, so a database deployed on either
# side holds 8563 for both; naming that spares the reader a hunt for an
# application that is not there. Twin of personal_foreign_db_hint.
function Get-PersonalForeignDbHint {
    if (-not (Test-PersonalTlsAnswers)) { return "" }
    # NAME WHAT IS ACTUALLY THERE. A recorded container of this machine's own
    # previous kit is the commonest holder of this port, and telling that user
    # to go and stop something in WSL sends them looking for a database that
    # does not exist. The crossing is the road out of it. Twin of
    # personal_foreign_db_hint.
    if ((Get-Command Test-LegacyDbRecorded -ErrorAction SilentlyContinue) -and (Test-LegacyDbRecorded) -and
        ((Get-LegacyContainerState) -eq "running")) {
        $c = Get-LegacyContainer
        return " It is the container database of your previous starter kit ($c), which this kit no longer manages. Stop it ($(Get-LegacyEngineName) stop $c) and re-run the installer, which then offers to copy its data across."
    }
    return " It answers like an Exasol database this kit did not deploy: stop that database first, then re-run. Windows and WSL share this port, so one deployed inside WSL holds it here too (stop it there with: exakit stop)."
}

# Get-PersonalLauncherState - the LAUNCHER'S OWN WORD for this deployment
# ("stopped", "database_ready", ...), empty when it cannot say. The port is not
# the owner: a stopped deployment can leave its runner alive and still
# answering, and calling that "running" makes `exakit start` refuse to start a
# database the user cannot otherwise recover. Twin of personal_launcher_state.
function Get-PersonalLauncherState {
    $out = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @("status", "--json") -TimeoutSeconds $script:PersonalProbeTimeout
    if ($out -and $out -match '"status"\s*:\s*"([^"]*)"') { return $Matches[1].ToLowerInvariant() }
    $out = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @("status") -TimeoutSeconds $script:PersonalProbeTimeout
    if ($out -and $out -match '(?m)^\s*Status:\s*([A-Za-z_]+)') { return $Matches[1].ToLowerInvariant() }
    return ""
}

function Test-PersonalDeploymentRunning {
    if (-not (Test-ExakitPortInUse (Get-PersonalDbPort))) { return $false }
    if (Test-PersonalDeploymentExists) {
        # THE LAUNCHER'S WORD OUTRANKS THE PORT. "stopped" can leave a runner
        # answering (see Get-PersonalStatus); "deployment_failed" is a first
        # boot the launcher gave up on - reconciled by Install-PersonalDeployment,
        # never adopted as running, or its stop and start stay no-ops for good.
        $state = Get-PersonalLauncherState
        if ($state -eq "stopped" -or $state -eq "deployment_failed") { return $false }
        return (Test-PersonalDbAnswers)
    }
    # NO DEPLOYMENT OF OURS. Something answers on the port, but only a SELECT
    # through the kit's own profile proves it is this kit's database. Windows
    # and WSL share one network stack, so a database deployed on either side
    # holds 8563 for both - and adopting the other side's database here handed
    # the rest of the install a password that could never work against it.
    if ((Get-Command Test-ExakitDbReachable -ErrorAction SilentlyContinue) -and (Get-ExakitManifestValue "components.exapump.profile")) {
        return [bool](Test-ExakitDbReachable)
    }
    return $false
}

# Test-PersonalDeploymentWedged - a SIGKILLed runner leaves the launcher's
# workflow state "interrupted", after which start is refused until the launcher
# rebuilds the deployment. Read from the state file, the same key the sh probe
# reads. From 2.3 the launcher stops producing this state; installed 2.2
# deployments still do, so the probe stays.
function Test-PersonalDeploymentWedged {
    $state = Join-Path $script:PersonalDeployDir ".exasolLauncherState.json"
    if (-not (Test-Path $state)) { return $false }
    try {
        $doc = [System.IO.File]::ReadAllText($state) | ConvertFrom-Json
        $workflow = $doc.currentWorkflowState
        if ($workflow -and $workflow.PSObject.Properties["interrupted"] -and $workflow.interrupted) { return $true }
    } catch { }
    return $false
}

# Get-PersonalStatus - the kit's documented status vocabulary, one word.
# A BUSY port is not a running database: with the database stopped and another
# program listening on the port, "running" here sent `exakit start` to say
# "already running" and exit 0 - a loop with no exit. When the port answers,
# ask the launcher; busy-but-not-Exasol is "conflict", its own state with its
# own remedy. Twin of personal_status.
function Get-PersonalStatus {
    $cliOnPath = Get-Command exasol -ErrorAction SilentlyContinue
    if (-not (Test-Path $script:PersonalBinPath) -and -not $cliOnPath) { return "not installed" }
    if (Test-PersonalDeploymentExists) {
        if (Test-ExakitPortInUse (Get-PersonalDbPort)) {
            # The launcher owns the lifecycle, so its word outranks the port:
            # a stopped deployment whose runner is still up is stopped, not
            # running, or it could never be started again.
            if ((Get-PersonalLauncherState) -eq "stopped") { return "stopped" }
            if (Test-PersonalDbAnswers) { return "running" }
            return "conflict"
        }
        if (Test-PersonalDeploymentWedged) { return "interrupted" }
        return "stopped"
    }
    return "not deployed"
}

# Test-PersonalGuestRebuildExpected / Show-PersonalGuestRebuildNote - from 2.3 a
# deployment runs the VM guest belonging to its launcher's runner, so the first
# start after the launcher changes rebuilds that guest: data kept, far longer
# than the ordinary readiness budget. Said BEFORE the start - silence through a
# long start is the failure mode - and once per run.
function Test-PersonalGuestRebuildExpected {
    $deployed = Get-PersonalDeployedVersion
    if (-not $deployed) { return $false }
    # The launcher actually installed, not the one the kit advertises: before an
    # update those differ, and announcing a rebuild for a launcher this machine
    # does not have yet is a promise about the wrong event.
    $launcher = Get-PersonalLauncherVersion
    if (-not $launcher) { $launcher = Get-PersonalTargetVersion }
    if (-not $launcher) { return $false }
    if ($deployed -eq $launcher) { return $false }
    # ONCE, not forever: a deployment keeps the version that created it, so this
    # comparison stays true after the rebuild has already happened. The
    # completed start records the launcher it completed under.
    return ((Get-ExakitManifestValue "runtime.guest_rebuilt_for") -ne $launcher)
}

function Show-PersonalGuestRebuildNote {
    if (-not (Test-PersonalGuestRebuildExpected)) { return }
    if ($script:PersonalRebuildNoted) { return }
    $script:PersonalRebuildNoted = $true
    Info "This deployment was created by an earlier launcher, so the first start rebuilds its VM guest - slower than usual, once. Your data is kept."
}

# Wait-PersonalReady - a WALL-CLOCK ceiling on the launcher answering, with the
# guest rebuild given its own budget: the ordinary one turned a successful
# upgrade into a reported crash. An explicitly set EXAKIT_PERSONAL_READY_TIMEOUT
# still wins - a number the user chose is never overridden by a guess. Twin of
# personal_wait_ready.
function Test-PersonalReadyProbe {
    Info "Checking deployment health"
    $budget = 150
    $raise = "EXAKIT_PERSONAL_READY_TIMEOUT"
    if ($env:EXAKIT_PERSONAL_READY_TIMEOUT) {
        $budget = [int]$env:EXAKIT_PERSONAL_READY_TIMEOUT
    } elseif (Test-PersonalGuestRebuildExpected) {
        Show-PersonalGuestRebuildNote
        $budget = 900
        if ($env:EXAKIT_PERSONAL_REBUILD_TIMEOUT) { $budget = [int]$env:EXAKIT_PERSONAL_REBUILD_TIMEOUT }
        $raise = "EXAKIT_PERSONAL_REBUILD_TIMEOUT"
    }
    $t0 = [DateTime]::UtcNow
    while (([DateTime]::UtcNow - $t0).TotalSeconds -lt $budget) {
        # A HANDSHAKE, NOT AN OPEN PORT. Under rootless Podman the port is
        # pasta's from the moment the container starts, and `exasol info`
        # answers from the deployment directory - together they declared
        # "reachable" a database that was still a minute from accepting a
        # connection, and the next step's SELECT 1 paid for it six times.
        if (Test-PersonalTlsAnswers) {
            Ok "Deployment is reachable"
            # The database answered under this launcher, so whatever rebuild that
            # first start owed is paid - recorded so the notice retires itself.
            $done = Get-PersonalLauncherVersion
            if (-not $done) { return $true }
            # [void], because THIS FUNCTION'S OUTPUT IS NOW ITS ANSWER. It
            # used to return nothing and a stray object from the manifest write
            # cost nobody anything; it is a $true/$false probe now, and anything
            # else it emits joins that answer.
            [void](Set-ExakitManifestValue "runtime.guest_rebuilt_for" $done)
            return $true
        }
        Start-Sleep -Seconds 5
    }
    $script:PersonalReadySpent  = [int]([DateTime]::UtcNow - $t0).TotalSeconds
    $script:PersonalReadyBudget = $budget
    $script:PersonalReadyRaise  = $raise
    return $false
}

# Wait-PersonalReady - the probe, and the end of the run when it fails. Every
# caller outside the install still reaches this one; the install's callers use
# Wait-PersonalReadyOrDeploy below, which tries the repair first and hands a
# refusal back instead of ending the run. Twin of personal_wait_ready.
function Wait-PersonalReady {
    if (Test-PersonalReadyProbe) { return }
    $spent  = $script:PersonalReadySpent
    $budget = $script:PersonalReadyBudget
    $raise  = $script:PersonalReadyRaise
    Fail "The deployment did not answer within ${spent} seconds (the ceiling is ${budget}s; raise it with ${raise}). Read the state with 'exakit status', then 'exakit start' to retry - a deployment stuck in 'interrupted' is repaired with 'exakit repair-runtime' (destructive, it asks first)."
}

# Wait-PersonalReadyOrDeploy - A START THAT REPORTED SUCCESS IS NOT A DATABASE.
# The launcher's start exits 0 and does nothing at all in more than one state:
# "deployment_failed" is the one the kit already knew about, and "initialized
# but not deployed yet" is the one that cost a whole install - start said OK,
# the kit said it was reusing the deployment, and then waited its entire
# 150-second budget for a database nobody had asked to exist.
#
# So this stops reading the state and reads the DATABASE. Whatever the launcher
# called it, a deployment that does not answer after a start it accepted was
# never started, and the launcher's own deploy is what brings it up - about
# twenty seconds. Asking the database rather than the record means the next
# spelling of this state needs no new case arm.
#
# $true when the database answers, $false when it never did. Never ends the
# run: the caller records it and carries on. Twin of
# personal_wait_ready_or_deploy.
function Wait-PersonalReadyOrDeploy {
    if (Test-PersonalReadyProbe) { return $true }
    Warn2 "The database did not answer after the launcher accepted the start."
    Info "In some states the launcher's start does nothing and its deploy is the fix - running that now."
    $deployArgs = @("deploy")
    $flag = Get-PersonalAutoApproveFlag "deploy"
    if ($flag) { $deployArgs += $flag }
    $script:ExakitActiveLabel = "Deploying the existing database"
    $rc = Invoke-ExakitLogged (Get-PersonalCli) @deployArgs
    $script:ExakitActiveLabel = ""
    if ($rc -ne 0) {
        Set-ExakitFailureReason "The database never answered, and the launcher's deploy could not bring it up"
        return $false
    }
    if (Test-PersonalReadyProbe) {
        Ok "The database answered after the launcher's deploy"
        return $true
    }
    Set-ExakitFailureReason "The database never answered, even after the launcher deployed it again"
    return $false
}

# Test-PersonalRequirements - the compatibility gate. Windows arm64 is refused
# by NAME: the launcher publishes no Windows arm64 local deployment, and this is
# the one machine class where the old container runtime is the only local
# database - the refusal says which knob keeps it. The hardware is asked, not
# PROCESSOR_ARCHITECTURE, which reports the emulated x64 shell on ARM devices.
# Twin of personal_check_requirements.
function Test-PersonalRequirements {
    $arch = Get-ExakitHostArch
    if ($arch -ne "amd64") {
        Fail "Exasol Personal supports macOS, native Linux and Windows x86_64 - it does not support Windows '$arch'. Nothing was installed. For the full kit on this machine, use a native Linux machine or VM."
    }
    $ramGb = 0
    try {
        $ramGb = [int][math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB)
    } catch { }
    if ($env:EXAKIT_FORCE -ne "1") {
        if ($ramGb -gt 0 -and $ramGb -lt $script:PersonalMinRamGb) {
            Fail "This machine is not compatible: Exasol Personal needs at least $($script:PersonalMinRamGb) GB RAM and this machine has ${ramGb} GB. Nothing was installed (or force at your own risk with EXAKIT_FORCE=1)."
        }
        $freeGb = 0
        try {
            $drive = (Get-Item (Get-ExakitProfileHome)).PSDrive
            if ($drive -and $drive.Free) { $freeGb = [int][math]::Round($drive.Free / 1GB) }
        } catch { }
        if ($freeGb -gt 0 -and $freeGb -lt $script:PersonalMinDiskGb) {
            Fail "This machine is not compatible right now: the database needs at least $($script:PersonalMinDiskGb) GB free disk and the home drive has ${freeGb} GB. Free up space and re-run (or force at your own risk with EXAKIT_FORCE=1)."
        }
    }
    # Nothing is said here about the container runtime the launcher brings with
    # it. On Windows the launcher installs what it needs itself, and the deploy
    # step names the one administrator prompt that can appear at the moment it
    # can appear - which is where a reader can act on it. A line at the gate
    # was an announcement about a step that had not started.
    #
    # ONE THING ABOUT A MACHINE THAT IS ALREADY THERE, though. Podman Desktop
    # creates the default machine ROOTFUL, and a rootful container publishes
    # its port as an iptables rule inside the machine - no listener, so neither
    # WSL's localhost relay nor gvproxy ever forwards it to Windows. The
    # launcher then deploys a database that answers inside the machine and
    # never on 127.0.0.1:8563, and every start waits 150 s for it. A machine
    # Podman creates itself is rootless and publishes through a real listener,
    # which the relay forwards. Found by running both on one laptop; refused
    # here, before anything is downloaded, with the fix named.
    $podmanCmd = Get-Command podman -ErrorAction SilentlyContinue
    if ($podmanCmd -and $env:EXAKIT_FORCE -ne "1") {
        $rootful = ("" + (Invoke-ExakitBounded -FilePath $podmanCmd.Source -Arguments @("machine", "inspect", "--format", "{{.Rootful}}") -TimeoutSeconds 20)).Trim()
        if ($rootful -eq "true") {
            # OFFER TO FIX IT, rather than hand over three commands and stop.
            # Every new Windows install where Podman Desktop made the machine
            # hits this, so "here is what to type" is the whole experience of
            # the product for those users.
            if (Repair-PersonalRootfulPodmanMachine) {
                $rootful = ("" + (Invoke-ExakitBounded -FilePath $podmanCmd.Source -TimeoutSeconds 30 `
                    -Arguments @("machine", "inspect", "--format", "{{.Rootful}}"))).Trim()
            }
        }
        if ($rootful -eq "true") {
            Fail "Podman's default machine is rootful, and a database published from a rootful machine is not reachable from Windows (the port is an iptables rule inside the machine, which nothing forwards). Make it rootless first: podman machine stop; podman machine set --rootful=false; podman machine start - or remove it and let the launcher create one (podman machine rm podman-machine-default). Force past this check with EXAKIT_FORCE=1."
        }
    }
    Ok "Compatibility check passed (windows $arch, ${ramGb} GB RAM)"
}

# Install-PersonalLauncher - download the launcher release, verify it against
# the release's checksums file, and place exasol.exe under the kit's bin dir. A
# launcher already on PATH that knows the 'local' preset is kept as it always
# was. Twin of personal_install_launcher.
# Repair-PersonalRootfulPodmanMachine - switch Podman's default machine to
# rootless, with consent. Returns $true when it believes it changed something.
#
# WHY THIS BLOCKS EVERY NEW WINDOWS INSTALL. Podman Desktop creates the default
# machine ROOTFUL, and a rootful container publishes its port as an iptables
# rule inside the machine - no listener, so nothing forwards it to Windows. The
# database then answers inside the machine and never on 127.0.0.1:8563. The
# check that catches it was right to exist and wrong to stop there: it printed
# three commands and gave up, which is the entire experience of this product for
# anyone whose machine Podman Desktop had already made.
#
# CONSENT IS EXPLICIT, because this is not ours to change quietly. The default
# machine is shared host-wide: restarting it interrupts anything else using
# Podman, and containers created under the rootful machine are not visible from
# the rootless one afterwards. They are not deleted - the connection changes,
# not the storage - but a reader has to be told before, not discover it after.
# So a terminal is asked and defaults to yes; a run with no terminal must set
# EXAKIT_PODMAN_SELFHEAL=1, the same opt-in the Linux rootless fix uses.
function Repair-PersonalRootfulPodmanMachine {
    $podman = Get-Command podman -ErrorAction SilentlyContinue
    if (-not $podman) { return $false }

    Warn2 "Podman's default machine is rootful, and a database published from one is not reachable from Windows."
    $question = "Let the kit switch Podman's default machine to rootless? It stops and restarts the machine, and containers made under the rootful one will not be visible afterwards"

    if (Test-ExakitInteractive) {
        if (-not (Confirm-ExakitPrompt $question $true)) {
            Info "Not changed."
            return $false
        }
    } else {
        switch ("" + $env:EXAKIT_PODMAN_SELFHEAL) {
            { $_ -in @("1", "y", "yes", "Y", "YES", "Yes") } { }
            default {
                Info "The kit can switch it for you, but it restarts a machine shared with everything else"
                Info "on this host, so an unattended run has to opt in:  EXAKIT_PODMAN_SELFHEAL=1"
                return $false
            }
        }
    }

    # Stop, set, start - in that order, because set refuses on a running
    # machine. A stop that fails because it was already stopped is not an
    # error, so only the set and the start are judged.
    Info "Switching Podman's default machine to rootless"
    [void](Invoke-ExakitBounded -FilePath $podman.Source -Arguments @("machine", "stop") -TimeoutSeconds 120)
    $set = Invoke-ExakitLogged $podman.Source "machine" "set" "--rootful=false"
    if ($set -ne 0) {
        Warn2 "Could not switch the machine to rootless (podman machine set exited $set)."
        return $false
    }
    $start = Invoke-ExakitLogged $podman.Source "machine" "start"
    if ($start -ne 0) {
        # The setting took even though the start did not; say both, because the
        # next run needs to know which half to retry.
        Warn2 "The machine is set to rootless but would not start (podman machine start exited $start). Start it yourself: podman machine start"
        return $false
    }
    Ok "Podman's default machine is rootless now"
    return $true
}

function Install-PersonalLauncher {
    if ($env:EXAKIT_FORCE_COMPONENT_INSTALL -ne "1") {
        $existing = Get-Command exasol -ErrorAction SilentlyContinue
        if ($existing) {
            $help = Invoke-ExakitBounded -FilePath $existing.Source -Arguments @("install", "--help") -TimeoutSeconds $script:PersonalProbeTimeout
            if ($help -and ($help -match '(?m)^\s*(-[-a-zA-Z0-9]+,\s*)?local(\s|,|$)')) {
                Ok "Exasol launcher already installed: $($existing.Source)"
                return
            }
            Warn2 "The installed Exasol launcher ($($existing.Source)) does not support the 'local' preset (too old)."
            Info "Installing launcher v$(Get-PersonalTargetVersion) to $(Get-ExakitTilde $script:PersonalBinPath) - your existing launcher is left untouched"
        }
    }

    $version = Get-PersonalTargetVersion
    $asset = "exasol-personal_Windows_x86_64.zip"
    $base = "https://github.com/$($script:PersonalRepo)/releases/download/v$version"
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-personal-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    # ONE LINE FOR THIS STEP, as on every other platform. The step label is
    # already animated and re-labelled per phase, so the download line, the
    # checksum verdict and the unpack line underneath were the second telling -
    # and they were the visible difference between a Windows install and a
    # macOS one. Piped or redirected, the detail stays, exactly as the shell
    # side behaves. Twin of the bracket in personal_install_launcher.
    $prevQuiet = $script:ExakitQuietDetail
    if (Test-ExakitStdoutIsTerminal) { $script:ExakitQuietDetail = $true }

    try {
        $script:ExakitActiveLabel = "Downloading Exasol launcher v$version"
        Info "Downloading Exasol launcher v$version ($asset)"
        Get-ExakitFile -Url "$base/$asset" -Dest (Join-Path $tmpDir $asset)
        Get-ExakitFile -Url "$base/exasol-personal_${version}_checksums.txt" -Dest (Join-Path $tmpDir "checksums.txt")

        # The checksums file is "HASH  filename" lines; the asset's own line is
        # the verdict. A checksums file that does not name the asset is treated
        # exactly like a mismatch - never as permission to skip verification.
        $expected = $null
        foreach ($line in (Get-Content (Join-Path $tmpDir "checksums.txt"))) {
            if ($line -match ('^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($asset) + '\s*$')) {
                $expected = $Matches[1].ToLowerInvariant()
                break
            }
        }
        if (-not $expected) {
            Fail "The release's checksums file does not name $asset; refusing to install an unverified launcher."
        }
        Test-ExakitSha256 -Path (Join-Path $tmpDir $asset) -Expected $expected

        $script:ExakitActiveLabel = "Installing launcher to $(Get-ExakitTilde $script:PersonalBinPath)"
        Info "Installing launcher to $(Get-ExakitTilde $script:PersonalBinPath)"
        Expand-Archive -Path (Join-Path $tmpDir $asset) -DestinationPath $tmpDir -Force
        $extracted = Get-ChildItem -Path $tmpDir -Filter "exasol.exe" -Recurse | Select-Object -First 1
        if (-not $extracted) {
            Fail "The launcher archive did not contain exasol.exe - the download looks wrong. Re-run the installer."
        }
        New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
        Move-Item -Force $extracted.FullName $script:PersonalBinPath
        OkStep "Exasol launcher v$version installed to $(Get-ExakitTilde $script:PersonalBinPath)"
    } finally {
        # The flag is restored in the SAME finally that cleans the temp dir:
        # a leaked quiet flag silences every step after this one, and a Fail
        # inside the try is the path that would leak it.
        $script:ExakitQuietDetail = $prevQuiet
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
}

# Clear-PersonalStaleRecord - drop the old container's keys from runtime.*.
#
# An install that crossed from the Docker-era kit kept runtime.engine,
# container, image and volume from the nano record, so status read "personal
# (docker)" - and the record named a container that is not this deployment's -
# while the database ran in Podman. Those keys describe the OLD database, and
# legacy.* is where the kit keeps it: migrate and the restore read it from
# there (Get-LegacyRecordValue). Copied across first when legacy.* has none, so
# a record saved before Save-LegacyRecord existed loses nothing. Called when
# the runtime is recorded and on every resumed install, so an install already
# carrying the stale keys heals on its next run. Twin of
# personal_clear_stale_record.
function Clear-PersonalStaleRecord {
    foreach ($key in @("container", "engine", "volume")) {
        $old = Get-ExakitManifestValue "runtime.$key"
        if ($null -eq $old -or "$old" -eq "") { continue }
        if (-not (Get-ExakitManifestValue "legacy.$key")) { Set-ExakitManifestValue "legacy.$key" $old }
    }
    foreach ($key in @("runtime.container", "runtime.image", "runtime.volume")) {
        if ($null -ne (Get-ExakitManifestValue $key)) { Remove-ExakitManifestValue $key }
    }
    # On Windows the launcher always runs the database in Podman (see header).
    Set-ExakitManifestValue "runtime.engine" "podman"
}

# Set-PersonalManifest [status] - the connection details this kit hands to every
# client, plus the runtime state. The deployment directory has everything a
# client needs: deployment.json (host, dbPort, username) and secrets.json
# (dbPassword). The keys are the contract every add-on reads - identical to the
# sh side's personal_record_manifest.
function Set-PersonalManifest {
    param([string]$Status = "")
    Set-ExakitManifestValue "runtime.type" "personal"
    Clear-PersonalStaleRecord
    # runtime.version is the COMPONENT the kit installs and compares against
    # versions.json, and that component is the LAUNCHER. The deployment's own
    # version - which decides whether a guest rebuild is still ahead - is
    # recorded beside it, never in its place. The advertised number is the last
    # resort, only when nothing on disk can answer.
    $deployed = Get-PersonalDeployedVersion
    $launcher = Get-PersonalLauncherVersion
    $recorded = $launcher
    if (-not $recorded) { $recorded = $deployed }
    if (-not $recorded) { $recorded = Get-PersonalTargetVersion }
    Set-ExakitManifestValue "runtime.version" $recorded
    if ($deployed) { Set-ExakitManifestValue "runtime.deployment_version" $deployed }
    Set-ExakitManifestValue "runtime.launcher" (Get-PersonalCli)
    Set-ExakitManifestValue "runtime.deployment_dir" $script:PersonalDeployDir

    $dsn = "127.0.0.1:$(Get-PersonalDbPort)"
    $dbUser = "sys"
    $depFile = Join-Path $script:PersonalDeployDir "deployment.json"
    if (Test-Path $depFile) {
        try {
            $dep = [System.IO.File]::ReadAllText($depFile) | ConvertFrom-Json
            if ($dep.connection) {
                $depHost = $dep.connection.host
                if (-not $depHost) { $depHost = "127.0.0.1" }
                $depPort = $dep.connection.dbPort
                if (-not $depPort) { $depPort = Get-PersonalDbPort }
                $dsn = "${depHost}:${depPort}"
                if ($dep.connection.username) { $dbUser = $dep.connection.username }
            }
        } catch { }
    }
    Set-ExakitManifestValue "runtime.dsn" $dsn
    Set-ExakitManifestValue "runtime.user" $dbUser

    $password = ""
    $secFile = Join-Path $script:PersonalDeployDir "secrets.json"
    if (Test-Path $secFile) {
        try {
            $sec = [System.IO.File]::ReadAllText($secFile) | ConvertFrom-Json
            if ($sec.dbPassword) { $password = $sec.dbPassword }
        } catch { }
    }
    if ($password) {
        Set-ExakitCredential "personal_sys_password" $password
        Set-ExakitManifestValue "runtime.password_file" (Join-Path $script:CredsDir "personal_sys_password")
    } else {
        Warn2 "Could not read the database password from the Exasol Personal secrets - the exapump profile and AI client configs will ask for it or need manual completion."
    }
    Set-ExakitManifestValue "runtime.tls" "self-signed"
    # Never assert health without either having just seen it or probing for it.
    if (-not $Status) { $Status = Get-PersonalStatus }
    Set-ExakitManifestValue "runtime.status" $Status
}

# Install-PersonalDeployment - run the local deployment, the long step. The
# consent ladder is the sh side's, question for question: a RUNNING database is
# offered for reuse (EXAKIT_REUSE_DB, default yes - the idempotent answer for
# automation); a stopped one is started and reused; only the explicit
# EXAKIT_REPLACE_DB consent ever reaches destroy - a failed start is not a
# licence to delete, and the reap-and-retry that saves the common case lives on
# the sh side's macOS daemon, which Windows does not have. Twin of
# personal_deploy_local.
# Test-PersonalPodmanAnswers - the smallest question that needs all of podman
# to work. Invoke-ExakitBounded returns $null on a non-zero exit, so a null is
# the failure.
function Test-PersonalPodmanAnswers {
    param([Parameter(Mandatory)]$Podman)
    return ($null -ne (Invoke-ExakitBounded -FilePath $Podman.Source -TimeoutSeconds 30 `
        -Arguments @("info", "--format", "{{.Host.Arch}}")))
}

# Test-PersonalPodmanRunning - INSTALLED IS NOT RUNNING, and on Windows the gap
# between the two is a whole VM. Podman here is a Linux machine under WSL, and
# `podman.exe` on PATH says nothing about whether that machine is up: after a
# reboot it is not, and Podman Desktop being closed is enough. Every podman
# command then fails, so the launcher's deploy fails, minutes in, with an error
# that names neither podman nor the machine.
#
# A STOPPED MACHINE IS STARTED, not reported. Starting one is not reconfiguring
# it - the kit's promise about leaving an existing machine alone is about its
# settings and its containers, and a machine that is off is the one state in
# which it can do no work for anyone. Twin of personal_podman_running, which
# has no machine to start and so only asks.
function Test-PersonalPodmanRunning {
    $podman = Get-Command podman -ErrorAction SilentlyContinue
    # Not installed is a different failure, and the launcher's to fix.
    if (-not $podman) { return $true }
    if (Test-PersonalPodmanAnswers $podman) { return $true }

    $list = "" + (Invoke-ExakitBounded -FilePath $podman.Source -TimeoutSeconds 30 `
        -Arguments @("machine", "list", "--format", "{{.Name}} {{.Running}}"))
    if ($list -match "false") {
        Info "Podman's machine exists but is not running - starting it (this takes a minute)"
        $script:ExakitActiveLabel = "Starting Podman's machine"
        [void](Invoke-ExakitLogged $podman.Source "machine" "start")
        $script:ExakitActiveLabel = ""
        if (Test-PersonalPodmanAnswers $podman) {
            Ok "Podman's machine is running"
            return $true
        }
    }

    # THE WHOLE ERROR TO THE LOG. The bounded probe above keeps only the exit
    # code, and "podman info failed" with nothing else is not diagnosable.
    [void](Invoke-ExakitLogged $podman.Source "info")
    Warn2 "Podman is installed, but it cannot run containers on this machine."
    Info "Check it with 'podman info' (and 'podman machine start' if its machine is off)."
    Info "Once that answers, re-run the installer to finish the install: $(Get-ExakitInstallCommand)"
    return $false
}

# Invoke-PersonalInstallLocal <args> - `exasol install local`, retried when it
# failed on a Windows file lock rather than on anything about the deployment.
#
# The launcher writes runtime-artifacts\index.json as a temp file renamed over
# the old one, and Windows refuses that rename while any other process holds
# the target open - Defender or another scanner inspecting the file it just
# wrote, the search indexer. Measured on a Nano-to-Personal upgrade:
#   rename ...\runtime-artifacts\index.json.tmp-1356456713 ...\index.json: Access is denied.
# a second after the deploy began, with nothing deployed, and the very next
# installer run went through untouched. The lock is gone within seconds, so the
# retry is short and only fires on that signature: any other failure is real and
# goes straight back to the caller. Nothing to undo in between - the launcher
# failed in initialisation, before creating a deployment.
# Windows only: POSIX rename replaces an open file, so the sh side has no twin.
function Invoke-PersonalInstallLocal {
    param([string[]]$InstallArgs)
    $attempts = 3
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $logBefore = 0
        if ($script:LogFile -and (Test-Path $script:LogFile)) {
            $logBefore = @(Get-Content -Path $script:LogFile).Count
        }
        $rc = Invoke-ExakitLogged (Get-PersonalCli) @InstallArgs
        if ($rc -eq 0) { return 0 }
        if ($attempt -eq $attempts -or -not $script:LogFile) { return $rc }
        if (Test-PersonalDeploymentExists) { return $rc }
        $output = @(Get-Content -Path $script:LogFile | Select-Object -Skip $logBefore) -join "`n"
        if ($output -notmatch 'Access is denied|being used by another process') { return $rc }
        Write-ExakitLog "WARN" "exasol install local hit a file lock (attempt $attempt of $attempts) - retrying"
        Start-Sleep -Seconds (3 * $attempt)
    }
    return $rc
}

function Install-PersonalDeployment {
    if (Test-PersonalDeploymentRunning) {
        Info "An Exasol database is already running on port $(Get-PersonalDbPort)."
        if (Confirm-ExakitEnvPrompt "EXAKIT_REUSE_DB" "Use it instead of deploying a new one?" $true) {
            Ok "Reusing the existing Exasol deployment"
            Set-PersonalManifest "healthy"
            return
        }
        # NOT THE END OF THE RUN. The user declined a database, not the kit:
        # nothing has been written and nothing is half made. Same shape as a
        # declined Podman install, and the same flag carries it out.
        Info "Stop it first ('exakit stop', or 'exasol stop'), then re-run the installer to deploy a fresh one - port $(Get-PersonalDbPort) stays in use while it is running: $(Get-ExakitInstallCommand)"
        Set-ExakitFailureReason "Declined to reuse the database already running on port $(Get-PersonalDbPort)"
        $script:PersonalNoDatabase = $true
        return
    }

    if (Test-PersonalDeploymentExists) {
        # A FIRST BOOT THE LAUNCHER GAVE UP ON is not a stopped deployment. In
        # "deployment_failed" its start and stop do nothing, so the
        # start-and-reuse path below would report success over a record that
        # stays failed - and every later exakit start would wait on nothing.
        # The launcher's own retry is its deploy; when that gives up on a
        # first boot again, the kit's budget and reconcile take over. Only a
        # database that never answers reaches the ladder below.
        if ((Get-PersonalLauncherState) -eq "deployment_failed") {
            Info "The launcher records this deployment as failed - retrying its deploy."
            $deployArgs = @("deploy")
            $flag = Get-PersonalAutoApproveFlag "deploy"
            if ($flag) { $deployArgs += $flag }
            $script:ExakitActiveLabel = "Retrying the deployment"
            if (((Invoke-ExakitLogged (Get-PersonalCli) @deployArgs) -eq 0) -or (Wait-PersonalSlowFirstBoot)) {
                Ok "Reusing the existing Exasol deployment (deployed again)"
                if (-not (Wait-PersonalReadyOrDeploy)) { $script:PersonalNoDatabase = $true; return }
                Set-PersonalManifest "healthy"
                return
            }
            Warn2 "The failed deployment could not be brought up.$(Get-PersonalForeignDbHint)"
        }
        Info "An Exasol deployment was found, not running."
        if (Confirm-ExakitEnvPrompt "EXAKIT_REUSE_DB" "Start the existing database and keep its data?" $true) {
            Show-PersonalGuestRebuildNote
            $startArgs = @("start")
            $flag = Get-PersonalAutoApproveFlag "start"
            if ($flag) { $startArgs += $flag }
            if ((Test-PersonalLauncherSupports "start") -and ((Invoke-ExakitLogged (Get-PersonalCli) @startArgs) -eq 0)) {
                Ok "Reusing the existing Exasol deployment (started)"
                # NOT "started, therefore running": the launcher accepts a start
                # for a deployment it has only initialized, does nothing, and
                # the kit then waits its whole budget for it.
                if (-not (Wait-PersonalReadyOrDeploy)) { $script:PersonalNoDatabase = $true; return }
                Set-PersonalManifest "healthy"
                return
            }
            Warn2 "The existing deployment could not be started."
        }
        # NO PATH DESTROYS WITHOUT THIS CONSENT - not even a failed start. A
        # deployment that will not start today may hold months of data and be
        # one diagnosis away from starting tomorrow; deleting it is the user's
        # call, made with the consequence in front of them.
        if (-not (Confirm-ExakitEnvPrompt "EXAKIT_REPLACE_DB" "DELETE the stopped deployment and its data, and deploy a fresh one? This cannot be undone." $false)) {
            Info "Nothing was deleted. Start it yourself with 'exakit start', diagnose with 'exakit status', repair with 'exakit repair-runtime' - or re-run with EXAKIT_REPLACE_DB=1 to replace it, deleting its data."
            Set-ExakitFailureReason "A stopped deployment could not be started, and deleting it was declined"
            $script:PersonalNoDatabase = $true
            return
        }
        Info "Replacing the existing deployment - its previous data is not recoverable."
        # --auto-approve: destroy has its own [y/N] prompt, which a piped or
        # scripted install cannot answer; the consent came from the explicit
        # replace question (or EXAKIT_REPLACE_DB=1) just above.
        if ((Invoke-ExakitLogged (Get-PersonalCli) destroy --remove --auto-approve) -ne 0) {
            Warn2 "Could not fully remove the old deployment; the launcher will deploy over it."
        }
    }

    if (Test-ExakitPortInUse (Get-PersonalDbPort)) {
        Warn2 "Port $(Get-PersonalDbPort) is in use by a process that is not a reachable Exasol Personal deployment.$(Get-PersonalForeignDbHint)"
        Info "Stop that application, then re-run the installer (EXAKIT_DB_PORT does not choose the port of a personal deployment): $(Get-ExakitInstallCommand)"
        Set-ExakitFailureReason "Port $(Get-PersonalDbPort) is held by something that is not an Exasol Personal deployment"
        $script:PersonalNoDatabase = $true
        return
    }

    # The progress bar narrates the deploy and the spinner narrates the health
    # probe, so the info/ok pairs underneath are the second telling. Twin of the
    # bracket in personal_deploy_local.
    $prevDeployQuiet = $script:ExakitQuietDetail
    if (Test-ExakitStdoutIsTerminal) { $script:ExakitQuietDetail = $true }

    # try/finally, not a plain restore at the end: Fail throws, this runs
    # inside a step that can be soft, and a caught throw would leave the flag
    # set and silence every step after it. Same shape mcp.ps1 uses, for the
    # same reason.
    try {

    Info "Exasol Personal is free to use and ships under Exasol's own licence terms, not the kit's MIT licence. The launcher shows them below."
    # PODMAN IS NAMED WHEN IT IS MISSING, not in a clause on every deploy.
    # Windows does not install it the way the sh side does - the LAUNCHER does,
    # through winget, as part of `install local` - so the kit's job here is to
    # say what is about to happen and what to do if the machine refuses it.
    # That refusal is real: an unelevated winget on a managed laptop fails, and
    # the first the user heard of it was the launcher's own error, mid-deploy,
    # with no mention of Podman at all. Twin of personal_install_podman, which
    # does the installing itself where the kit owns that job.
    if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        Warn2 "Podman is not installed on this machine, and the database runs through it."
        Info "The Exasol launcher installs it as part of this step, and Windows may ask for administrator approval."
        Info "If that is refused or fails: install it yourself with 'winget install RedHat.Podman' (a reboot may be needed), then re-run the installer."
    } elseif (-not (Test-PersonalPodmanRunning)) {
        # Installed, and still no database: same soft failure as a podman that
        # was never installed, because the user is in the same position - one
        # command away from a database, and better told now than after the
        # launcher has spent five minutes discovering it.
        Set-ExakitFailureReason "Podman is installed but not usable ('podman info' failed; its machine may be stopped)"
        $script:PersonalNoDatabase = $true
        return
    }
    Info "Deploying Exasol Personal locally - the database runs through Podman's default machine, which the launcher prepares."

    $installArgs = @("install", "local")
    $flag = Get-PersonalAutoApproveFlag "install"
    if ($flag) { $installArgs += $flag }
    $script:ExakitActiveLabel = "Deploying Exasol Personal locally"
    if ((Invoke-PersonalInstallLocal $installArgs) -ne 0) {
        # A DEPLOYMENT THAT EXISTS IS GIVEN THE KIT'S OWN BUDGET FIRST: the
        # launcher waits 27 seconds for a first boot, and a first boot in a
        # fresh Podman machine takes longer. Twin of the same branch in
        # personal_deploy_local; see Wait-PersonalSlowFirstBoot.
        if (-not ((Test-PersonalDeploymentExists) -and (Wait-PersonalSlowFirstBoot))) {
            # THE LIKELIEST CAUSE FIRST. A deploy that fails with Podman still
            # missing failed at installing Podman, and "Local deployment
            # failed" sends the reader to look at the database instead.
            if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
                # NOT Fail. This is the one deployment failure the install can
                # carry on from, and the twin of personal_deploy_local's single
                # non-zero return: nothing has been created, nothing is half
                # written, and the steps that do not need a database still have
                # value. The flag - not a return value - because this function
                # returns bare on four reuse paths, and an `if (Install-...)`
                # caller would read every one of them as a failure.
                Warn2 "Local deployment failed, and Podman is still not installed - that is what the launcher could not do."
                Info "Install it yourself with 'winget install RedHat.Podman' (a reboot may be needed), then re-run the installer: $(Get-ExakitInstallCommand)"
                Set-ExakitFailureReason "Podman is not installed and the launcher could not install it (winget install RedHat.Podman)"
                $script:PersonalNoDatabase = $true
                return
            }
            Warn2 "Local deployment failed.$(Get-PersonalForeignDbHint)"
            # The INSTALLER, not `exakit update`: update only moves components
            # that have a newer advertised version, so a deployment that never
            # happened is "already current" to it - and on the Nano-to-Personal
            # crossing the manifest still names nano, which it skips outright.
            # A re-run resumes at this step. Twin of personal_deploy_local.
            Info "Retry it by re-running the installer - completed steps are skipped: $(Get-ExakitInstallCommand)"
            Set-ExakitFailureReason "The launcher could not deploy the database locally"
            $script:PersonalNoDatabase = $true
            return
        }
    }

    if (-not (Wait-PersonalReadyOrDeploy)) {
        $script:PersonalNoDatabase = $true
        return
    }
    } finally {
        $script:ExakitQuietDetail = $prevDeployQuiet
    }
    Ok "Exasol Personal deployed and answering on 127.0.0.1:$(Get-PersonalDbPort)"
    Set-PersonalManifest "healthy"
}

# The launcher gave up on a first boot that was merely slow: wait with the kit's
# budget and reconcile the launcher's record with its own `deploy` retry. When
# the launcher records deployment_failed, its stop and start do nothing, so a
# database that came up ten seconds too late read as a failed install and every
# later `exakit start` waited 150 s for nothing. $false only when the database
# never answered. Twin of personal_recover_slow_first_boot.
function Wait-PersonalSlowFirstBoot {
    $budget = 150
    if ($env:EXAKIT_PERSONAL_READY_TIMEOUT) { $budget = [int]$env:EXAKIT_PERSONAL_READY_TIMEOUT }
    Info "The launcher stopped waiting after its own short budget, but the deployment exists - waiting up to ${budget}s for the database"
    $t0 = [DateTime]::UtcNow
    while (-not (Test-PersonalTlsAnswers)) {
        if (([DateTime]::UtcNow - $t0).TotalSeconds -ge $budget) { return $false }
        Start-Sleep -Seconds 5
    }
    Ok "The database answered after $([int]([DateTime]::UtcNow - $t0).TotalSeconds)s"
    # THE RECONCILE IS THE OWNERSHIP PROOF. A handshake says a database answers
    # on the port, not whose: with Windows and WSL sharing one network stack it
    # may be the other side's. The launcher's deploy connects with this
    # deployment's own credentials, so its success is the one signal that the
    # database that answered is this one - and its failure is a failure, not a
    # database "the kit can reach".
    $deployArgs = @("deploy")
    $flag = Get-PersonalAutoApproveFlag "deploy"
    if ($flag) { $deployArgs += $flag }
    $script:ExakitActiveLabel = "Reconciling the launcher's record"
    if ((Invoke-ExakitLogged (Get-PersonalCli) @deployArgs) -eq 0) {
        Ok "The launcher's record agrees with the running database"
        return $true
    }
    Warn2 "The launcher still records this deployment as failed although something answers on port $(Get-PersonalDbPort).$(Get-PersonalForeignDbHint)"
    return $false
}

# Start-Personal / Stop-Personal - launcher start/stop with the same say-what-
# to-do-next failure messages as the sh twins. Stop leaves Podman's machine
# alone by design: it is shared host-wide and not this kit's to manage.
function Start-Personal {
    if (-not (Test-PersonalLauncherSupports "start")) {
        Info "This launcher version has no explicit start command."
        Info "Check the database with: $(Get-PersonalCli) info"
        return
    }
    # In "deployment_failed" the launcher's start (and stop) do nothing and
    # exit 0, so this reported "Database started" over a database that was
    # never asked to start and then waited its whole budget for it. The
    # launcher's own retry for that state is its deploy.
    if ((Get-PersonalLauncherState) -eq "deployment_failed") {
        Info "The launcher records this deployment as failed - retrying its deploy instead of a start it would ignore."
        $deployArgs = @("deploy")
        $flag = Get-PersonalAutoApproveFlag "deploy"
        if ($flag) { $deployArgs += $flag }
        if ((Invoke-ExakitLogged (Get-PersonalCli) @deployArgs) -eq 0) {
            Ok "Database started"
            return
        }
        Fail "The deployment could not be brought up.$(Get-PersonalForeignDbHint) Check the log; if it fails the same way, repair with: exakit repair-runtime"
    }
    Show-PersonalGuestRebuildNote
    $startArgs = @("start")
    $flag = Get-PersonalAutoApproveFlag "start"
    if ($flag) { $startArgs += $flag }
    if ((Invoke-ExakitLogged (Get-PersonalCli) @startArgs) -ne 0) {
        if (Test-PersonalDeploymentWedged) {
            Fail "The database is interrupted and cannot be started - the launcher has to rebuild it. Repair it with: exakit repair-runtime (this rebuilds the database from empty; its data is not recoverable)."
        }
        if ((Get-PersonalStatus) -eq "conflict") {
            Fail "Port $(Get-PersonalDbPort) is held by another process, so the database cannot start. Stop that process, then: exakit start"
        }
        Fail "Failed to start the database. Check the log, then retry with 'exakit start'; if it fails the same way, repair with: exakit repair-runtime"
    }
    Ok "Database started"
}

function Stop-Personal {
    if (-not (Test-PersonalLauncherSupports "stop")) {
        Info "This launcher version has no explicit stop command."
        return
    }
    if ((Invoke-ExakitLogged (Get-PersonalCli) stop) -ne 0) {
        Fail "Failed to stop the database."
    }
    Set-ExakitManifestValue "runtime.status" "stopped"
    Ok "Database stopped"
}

# Remove-Personal - destroy the deployment and its data. The Podman machine is
# deliberately untouched: it is shared host-wide, the launcher never
# reconfigures an existing one, and it stays running after destroy - this
# module owns the deployment, nothing else. Twin of personal_teardown.
function Remove-Personal {
    if (Test-PersonalDeploymentExists) {
        Warn2 "An Exasol Personal deployment keeps the database software and your data together - removing it deletes every table you loaded."
        # --auto-approve: the launcher's destroy prompts for confirmation by
        # itself; the caller (uninstall) has already asked its own question.
        if ((Invoke-ExakitLogged (Get-PersonalCli) destroy --remove --auto-approve) -ne 0) {
            Warn2 "The launcher reported errors while destroying the deployment. What it said: exakit logs setup"
        }
    }
    Set-ExakitManifestValue "runtime.status" "removed"
}

# Update-Personal - bring the kit-managed launcher to the advertised version and
# leave the record telling the truth about the deployment's state afterwards.
# The update prompt upstream of this call explains the one-time guest rebuild;
# the note here fires again right before the start that performs it.
function Update-Personal {
    param([string]$Advertised = "")
    if (-not $Advertised) { $Advertised = Get-PersonalTargetVersion }
    $env:EXAKIT_PERSONAL_VERSION = $Advertised
    $env:EXAKIT_FORCE_COMPONENT_INSTALL = "1"
    try {
        Install-PersonalLauncher
    } finally {
        Remove-Item Env:EXAKIT_FORCE_COMPONENT_INSTALL -ErrorAction SilentlyContinue
    }
    # The launcher moved; the deployment did not. Status is PROBED, never
    # assumed healthy - updating a stopped database used to record it healthy
    # on the sh side, and anything reading the manifest was then simply wrong.
    Set-PersonalManifest
}
