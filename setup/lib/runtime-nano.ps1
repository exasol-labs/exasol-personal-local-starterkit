# runtime-nano.ps1 - Exasol Nano container runtime module (Windows, Docker Desktop).
#
# THIS FILE EXISTS ONLY ON THE exasol-starterkit-docker BRANCH. On that branch
# the Windows database is an Exasol Nano container in Docker Desktop instead of
# an Exasol Personal deployment through Podman; macOS, Linux and WSL keep
# Personal exactly as on main. It is dot-sourced by setup-windows.ps1 and
# setup/exakit.ps1 after exakit-common.ps1, beside runtime-personal.ps1, and it
# offers the same function contract under the Nano name: requirements, install,
# exists/running/status, ready-wait, start, stop, remove, update, manifest.
#
# Container contract (from the image documentation, unchanged since 0.1.0):
#   - image: docker.io/exasol/nano:<tag>, multi-arch (amd64 and arm64)
#   - readiness: the logs print "Database is now up and running!", and the
#     database completes a TLS handshake on its port once it is up
#   - connection: 127.0.0.1:8563 (published on the loopback only), user sys,
#     TLS with a self-signed certificate
#   - first deploy only: `init sys_password_file=<path>` reads the SYS password
#     from a file mounted into the container; a container created with those
#     arguments cannot simply be restarted once /exa is initialised, so a
#     restart recreates it over the same data volume
#   - recommended limits: --shm-size=512mb --pids-limit=-1
#
# The image is PINNED. versions.json names the tag and the manifest-list digest
# Docker Hub serves for it; after the pull the local image's RepoDigests must
# carry that digest, or the image is removed and the install stops. A tag
# chosen by hand (EXAKIT_NANO_TAG) has no pin and is pulled unverified, said so.

$script:NanoImage          = "exasol/nano"
# The last-known-good tag: what a machine with no network, no cache and no kit
# copy installs. Moved by the versions-bump workflow together with the manifest.
$script:NanoTagFallback    = "2026.2.0-nano.6"
$script:NanoPort           = 8563
$script:NanoContainer      = if ($env:EXAKIT_NANO_CONTAINER) { $env:EXAKIT_NANO_CONTAINER } else { "exasol-nano" }
$script:NanoVolume         = if ($env:EXAKIT_NANO_VOLUME) { $env:EXAKIT_NANO_VOLUME } else { "exasol-nano-data" }
$script:NanoMinRamGb       = if ($env:EXAKIT_NANO_MIN_RAM_GB) { [int]$env:EXAKIT_NANO_MIN_RAM_GB } else { 4 }
$script:NanoMinDiskGb      = if ($env:EXAKIT_NANO_MIN_DISK_GB) { [int]$env:EXAKIT_NANO_MIN_DISK_GB } else { 10 }
$script:NanoReadyTimeout   = if ($env:EXAKIT_NANO_READY_TIMEOUT) { [int]$env:EXAKIT_NANO_READY_TIMEOUT } else { 600 }
$script:NanoProbeTimeout   = if ($env:EXAKIT_NANO_PROBE_TIMEOUT) { [int]$env:EXAKIT_NANO_PROBE_TIMEOUT } else { 10 }
$script:NanoEngineTimeout  = if ($env:EXAKIT_NANO_ENGINE_TIMEOUT) { [int]$env:EXAKIT_NANO_ENGINE_TIMEOUT } else { 30 }
# Seconds between pull attempts, times the attempt number; the test suite sets
# it to zero.
$script:NanoPullRetryDelay = 10
# The soft path the installer reads, twin of PersonalNoDatabase: Install-Nano
# sets it and returns when the database cannot be had, having said why, so
# the rest of the install carries on and the summary names the repair.
$script:NanoNoDatabase     = $false
$script:NanoEngineCache    = $null
$script:NanoReadySpent     = 0

# --- which image ---------------------------------------------------------------

# Get-NanoTargetTag - the image tag this kit installs or updates to: the env
# override, the advertised manifest, the fallback - the same order the Personal
# module resolves its launcher version in.
function Get-NanoTargetTag {
    if ($env:EXAKIT_NANO_TAG) { return $env:EXAKIT_NANO_TAG }
    $advertised = ""
    if (Get-Command Get-ExakitComponentAvailable -ErrorAction SilentlyContinue) {
        try { $advertised = "" + (Get-ExakitComponentAvailable "nano") } catch { $advertised = "" }
    }
    if ($advertised) { return $advertised }
    return $script:NanoTagFallback
}

# Get-NanoPinnedDigest - the 64-hex manifest-list digest versions.json pins for
# a tag, or "" when it pins none (another tag was asked for by hand, or the
# manifest carries no nano block). Only the advertised tag has a pin: a pin
# for one tag says nothing about another.
function Get-NanoPinnedDigest {
    param([Parameter(Mandatory)][string]$Tag)
    if (-not (Get-Command Get-ExakitVersionsValue -ErrorAction SilentlyContinue)) { return "" }
    $advertised = ""
    $digest = ""
    try {
        $advertised = "" + (Get-ExakitVersionsValue -Path "components.nano.version")
        $digest = "" + (Get-ExakitVersionsValue -Path "components.nano.digest")
    } catch { return "" }
    if (-not $advertised -or $advertised -ne $Tag) { return "" }
    if ($digest -notmatch '^[0-9a-f]{64}$') { return "" }
    return $digest
}

function Get-NanoImageRef {
    param([string]$Tag = "")
    if (-not $Tag) { $Tag = Get-NanoTargetTag }
    return "docker.io/$($script:NanoImage):$Tag"
}

# Get-NanoDbPort - the port the container publishes: the record first (a
# lifecycle command must act on the port the install used), then the caller's
# EXAKIT_DB_PORT, then the constant. Twin of Get-PersonalDbPort.
function Get-NanoDbPort {
    $dsn = "" + (Get-ExakitManifestValue "runtime.dsn")
    if ($dsn -match ':(\d+)$') { return [int]$Matches[1] }
    if ($script:DbPort) { return [int]$script:DbPort }
    return $script:NanoPort
}

# --- the engine ----------------------------------------------------------------

# Get-NanoEngine - "docker" when Docker Desktop answers, $null otherwise.
# Cached after the first answer.
#
# `docker info` writes warnings to stderr even when it is healthy, and under
# the global ErrorActionPreference=Stop that stderr write becomes a terminating
# error on Windows PowerShell 5.1 before the exit code can be read - so a
# perfectly healthy Docker was reported as "not running". The exit code
# decides, read through the bounded runner that the rest of the kit probes
# with (a Docker Desktop that is starting can block `docker info` for a
# minute; the probe gives up after NanoEngineTimeout seconds).
function Get-NanoEngine {
    if ($script:NanoEngineCache) { return $script:NanoEngineCache }
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) { return $null }
    $out = Invoke-ExakitBounded -FilePath $docker.Source -Arguments @("info", "--format", "{{.ServerVersion}}") -TimeoutSeconds $script:NanoEngineTimeout
    if ($null -ne $out -and ("" + $out).Trim() -ne "" -and ("" + $out) -notmatch 'error during connect|Cannot connect|cannot connect|not running|ERROR') {
        $script:NanoEngineCache = "docker"
        return "docker"
    }
    return $null
}

# Reset-NanoEngineCache - after Docker Desktop was asked to start, so the next
# question is asked of the engine rather than answered from memory.
function Reset-NanoEngineCache { $script:NanoEngineCache = $null }

# Get-NanoEngineCommand - the docker executable's full path for a Startup entry,
# where PATH is not the user's shell PATH.
function Get-NanoEngineCommand {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($docker) { return $docker.Source }
    return "docker"
}

# Invoke-NanoEngine <args...> - a docker command whose output is the answer
# (inspect, logs), bounded, "" when it fails. For commands whose EXIT CODE is
# the answer (pull, run, start, stop, rm) use Invoke-ExakitLogged, which also
# animates the spinner and keeps the output in the log.
function Invoke-NanoEngine {
    param([Parameter(ValueFromRemainingArguments)][string[]]$EngineArgs)
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) { return "" }
    $out = Invoke-ExakitBounded -FilePath $docker.Source -Arguments $EngineArgs -TimeoutSeconds $script:NanoEngineTimeout
    if ($null -eq $out) { return "" }
    return ("" + $out)
}

# Resolve-NanoNames - lifecycle commands act on the names the install recorded
# in the manifest, not this shell's defaults. An explicit environment override
# still wins. A 0.1.0 install recorded the same keys, so its container is
# simply adopted.
function Resolve-NanoNames {
    if ($script:NanoContainer -eq "exasol-nano") {
        $mc = Get-ExakitManifestValue "runtime.container"
        if ($mc) { $script:NanoContainer = $mc }
    }
    if ($script:NanoVolume -eq "exasol-nano-data") {
        $mv = Get-ExakitManifestValue "runtime.volume"
        if ($mv) { $script:NanoVolume = $mv }
    }
}

# --- requirements --------------------------------------------------------------

# Test-NanoRequirements - Docker Desktop answering, memory, free disk. Twin of
# Test-PersonalRequirements in shape; the thresholds are the Nano image's own
# (4 GB RAM, 10 GB disk), lower than Personal's. The Nano image is published
# for amd64 and arm64, so Windows on ARM is NOT refused here: the database
# runs, and the installer skips the pieces that have no arm64 build.
function Test-NanoRequirements {
    $engine = Get-NanoEngine
    if (-not $engine) {
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            Fail "Docker is installed but not running. Start Docker Desktop, wait for it to say it is running, then re-run. Nothing was installed."
        }
        Fail "Docker Desktop was not found. Install it from https://docs.docker.com/desktop/setup/install/windows-install/ (it needs a sign-in on larger company networks), start it, then re-run. Nothing was installed."
    }
    $arch = Get-ExakitHostArch
    $ramGb = 0
    try {
        $ramGb = [int][math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB)
    } catch { }
    if ($env:EXAKIT_FORCE -ne "1") {
        if ($ramGb -gt 0 -and $ramGb -lt $script:NanoMinRamGb) {
            Fail "This machine is not compatible: Exasol Nano needs at least $($script:NanoMinRamGb) GB RAM and this machine has ${ramGb} GB. Nothing was installed (or force at your own risk with EXAKIT_FORCE=1)."
        }
        $freeGb = 0
        try {
            $drive = (Get-Item (Get-ExakitProfileHome)).PSDrive
            if ($drive -and $drive.Free) { $freeGb = [int][math]::Round($drive.Free / 1GB) }
        } catch { }
        if ($freeGb -gt 0 -and $freeGb -lt $script:NanoMinDiskGb) {
            Fail "This machine is not compatible right now: the database image and its data need at least $($script:NanoMinDiskGb) GB free disk and the home drive has ${freeGb} GB. Free up space and re-run (or force at your own risk with EXAKIT_FORCE=1)."
        }
    }
    if ($ramGb -gt 0 -and $ramGb -lt ($script:NanoMinRamGb + 2)) {
        Warn2 "Memory is at the bare minimum (${ramGb} GB) - the database will run, but expect slower queries and keep other heavy apps closed."
    }
    Ok "Compatibility check passed (windows $arch, ${ramGb} GB RAM, Docker Desktop running)"
}

# --- state ---------------------------------------------------------------------

function Test-NanoContainerExists {
    Resolve-NanoNames
    if (-not (Get-NanoEngine)) { return $false }
    $out = Invoke-NanoEngine container inspect -f "{{.Id}}" $script:NanoContainer
    return ($out.Trim() -match '^[0-9a-f]{12,}$')
}

function Test-NanoContainerRunning {
    Resolve-NanoNames
    if (-not (Get-NanoEngine)) { return $false }
    $out = Invoke-NanoEngine container inspect -f "{{.State.Running}}" $script:NanoContainer
    return ($out.Trim() -eq "true")
}

# Test-NanoTlsAnswers - does the database complete a TLS handshake on its port?
# The one probe that tells a database apart from the process publishing its
# port: Docker's proxy accepts the TCP connection the moment the container
# starts, a minute or more before the database inside answers. The certificate
# is self-signed by design, so it is accepted, not validated. Twin of
# Test-PersonalTlsAnswers.
function Test-NanoTlsAnswers {
    $port = Get-NanoDbPort
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect("127.0.0.1", $port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(700, $false)) { return $false }
        $client.EndConnect($async)
        $ms = $script:NanoProbeTimeout * 1000
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

# Test-NanoReadyInLogs - the ready marker from the CURRENT boot only. Container
# logs survive stop/start, so the whole history would match a stale line from
# an earlier boot; scoping to StartedAt also keeps each poll cheap.
function Test-NanoReadyInLogs {
    Resolve-NanoNames
    $started = (Invoke-NanoEngine container inspect -f "{{.State.StartedAt}}" $script:NanoContainer).Trim()
    if (-not $started) { $started = "1970-01-01T00:00:00Z" }
    $logs = Invoke-NanoEngine logs --since $started $script:NanoContainer
    return ($logs -match "Database is now up and running")
}

# Test-NanoDeploymentExists / Test-NanoDeploymentRunning - the two questions the
# installer and the CLI ask, under the names the Personal module answers them
# by. "Running" is the database answering, not the container state alone.
function Test-NanoDeploymentExists { return (Test-NanoContainerExists) }

function Test-NanoDeploymentRunning {
    if (-not (Test-NanoContainerRunning)) { return $false }
    if (Test-NanoTlsAnswers) { return $true }
    return (Test-NanoReadyInLogs)
}

# Get-NanoStatus - the kit's documented status vocabulary, one word.
#   not installed  no Docker, or no container by the recorded name
#   stopped        the container exists and is not running
#   starting       the container runs but the database does not answer yet
#   running        the database completes a handshake
#   conflict       no container of ours runs, and another process holds the port
function Get-NanoStatus {
    Resolve-NanoNames
    if (-not (Get-NanoEngine)) { return "not installed" }
    if (-not (Test-NanoContainerExists)) {
        if (Test-ExakitPortInUse (Get-NanoDbPort)) { return "conflict" }
        return "not installed"
    }
    if (-not (Test-NanoContainerRunning)) {
        if (Test-ExakitPortInUse (Get-NanoDbPort)) { return "conflict" }
        return "stopped"
    }
    if (Test-NanoTlsAnswers) { return "running" }
    if (Test-NanoReadyInLogs) { return "running" }
    return "starting"
}

# --- waiting -------------------------------------------------------------------

# Wait-NanoReady - poll until the database answers, $true/$false. Ends the run
# through Fail only when -Fatal is passed (the CLI's start); the installer
# asks for the plain answer and records a soft failure itself.
function Wait-NanoReady {
    param([switch]$Fatal)
    Resolve-NanoNames
    Info "Waiting for the database to come up (timeout: $($script:NanoReadyTimeout)s)"
    $t0 = [DateTime]::UtcNow
    $told = 0
    while (([DateTime]::UtcNow - $t0).TotalSeconds -lt $script:NanoReadyTimeout) {
        if (-not (Test-NanoContainerRunning)) {
            $tail = Invoke-NanoEngine logs --tail 30 $script:NanoContainer
            if ($tail) { Write-ExakitLog "INFO" "container log tail: $tail" }
            if ($Fatal) { Fail "The Nano container stopped unexpectedly (its last log lines are in the kit log: exakit logs setup)." }
            return $false
        }
        if (Test-NanoTlsAnswers) {
            $script:NanoReadySpent = [int]([DateTime]::UtcNow - $t0).TotalSeconds
            Ok "Database is up (took ~$($script:NanoReadySpent)s)"
            return $true
        }
        Start-Sleep -Seconds 5
        $spent = [int]([DateTime]::UtcNow - $t0).TotalSeconds
        if ($spent - $told -ge 60) { Info "Still starting... (${spent}s)"; $told = $spent }
    }
    $script:NanoReadySpent = [int]([DateTime]::UtcNow - $t0).TotalSeconds
    Warn2 "The database did not become ready within $($script:NanoReadyTimeout)s."
    Info "Inspect the logs:   docker logs $($script:NanoContainer)"
    Info "If a first install was interrupted, the data volume may be half-initialised. Reset and retry: docker rm -f $($script:NanoContainer); docker volume rm $($script:NanoVolume); then re-run the installer."
    if ($Fatal) { Fail "Nano startup timed out (raise EXAKIT_NANO_READY_TIMEOUT for a slow machine)." }
    return $false
}

# Wait-NanoReadyOrDeploy - the installer's and the self-heal's wait: a
# container that is gone is recreated over its data volume, then waited for.
# $true/$false, never a Fail. Twin of Wait-PersonalReadyOrDeploy.
function Wait-NanoReadyOrDeploy {
    if (Test-NanoDeploymentRunning) { return $true }
    if (-not (Test-NanoContainerExists)) {
        Info "No container by the recorded name - recreating it over the data volume"
        $script:NanoNoDatabase = $false
        Install-Nano
        return (-not $script:NanoNoDatabase)
    }
    if (-not (Test-NanoContainerRunning)) {
        try { Start-NanoExisting } catch [ExakitFailException] { return $false }
    }
    return (Wait-NanoReady)
}

# --- the container -------------------------------------------------------------

# Get-NanoRunArgs - the `docker run` arguments every creation shares. The
# restart policy follows the manifest's autostart answer, because recreating a
# container drops whatever policy the old one had.
function Get-NanoRunArgs {
    $runArgs = @("run", "-d", "--name", $script:NanoContainer,
                 "--shm-size=512mb", "--pids-limit=-1",
                 "-p", "127.0.0.1:$(Get-NanoDbPort):8563",
                 "-v", "$($script:NanoVolume):/exa")
    $auto = Get-ExakitManifestValue "autostart.enabled"
    if ($auto -is [bool] -and $auto) { $runArgs += @("--restart", "unless-stopped") }
    return $runArgs
}

# Test-NanoFirstDeployArgs - was the container created with the single-use
# `init sys_password_file=...` arguments? Nano refuses to boot with them once
# /exa is initialised, so such a container is recreated, never restarted.
# '{{.Config.Cmd}}' renders the []string as "[a b c]", which is enough for a
# token test and needs no embedded quotes in the template.
function Test-NanoFirstDeployArgs {
    $cmd = Invoke-NanoEngine container inspect -f "{{.Config.Cmd}}" $script:NanoContainer
    return ($cmd -match "sys_password_file")
}

# Start-NanoExisting - bring a stopped container back, recreating it first when
# it still carries the first-deploy arguments (the data volume carries the
# database and its password forward). Fails loudly; callers that must not end
# the run catch ExakitFailException.
function Start-NanoExisting {
    $engine = Get-NanoEngine
    if (Test-NanoFirstDeployArgs) {
        $image = (Invoke-NanoEngine container inspect -f "{{.Config.Image}}" $script:NanoContainer).Trim()
        if (-not $image) { $image = Get-NanoImageRef }
        Info "Recreating the Nano container (first-deploy options are single-use; the data volume is kept)"
        if ((Invoke-ExakitLogged $engine "rm" "-f" $script:NanoContainer) -ne 0) { Fail "Could not replace the old container (see the log: exakit logs setup)" }
        $runArgs = Get-NanoRunArgs
        if ((Invoke-ExakitLogged $engine @runArgs $image) -ne 0) { Fail "The Nano container failed to start (see the log: exakit logs setup)" }
        return
    }
    if ((Invoke-ExakitLogged $engine "start" $script:NanoContainer) -ne 0) {
        if ((Get-NanoStatus) -eq "conflict") {
            Fail "Port $(Get-NanoDbPort) is held by another process, so the database cannot start. Stop that process, then: exakit start"
        }
        Fail "Could not start the existing container $($script:NanoContainer) (see the log: exakit logs setup)"
    }
}

# Invoke-NanoPull <tag> - pull the image and prove it is the pinned one.
# $true when the image is usable, $false after saying why it is not.
function Invoke-NanoPull {
    param([Parameter(Mandatory)][string]$Tag)
    $engine = Get-NanoEngine
    $image = Get-NanoImageRef -Tag $Tag
    $pin = Get-NanoPinnedDigest -Tag $Tag
    Info "Pulling image $image"
    $pulled = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ((Invoke-ExakitLogged $engine "pull" $image) -eq 0) { $pulled = $true; break }
        if ($attempt -lt 3) { Warn2 "Pull attempt $attempt failed - retrying in $($attempt * $script:NanoPullRetryDelay)s"; Start-Sleep -Seconds ($attempt * $script:NanoPullRetryDelay) }
    }
    if (-not $pulled) {
        Warn2 "The image could not be pulled after 3 attempts: $image (Docker Hub unreachable, or a proxy in the way - see the log: exakit logs setup)."
        return $false
    }
    if (-not $pin) {
        if ($env:EXAKIT_NANO_TAG) {
            Warn2 "Tag $Tag was chosen by hand (EXAKIT_NANO_TAG), so versions.json has no digest for it: the image is used as Docker Hub served it, unverified."
        } else {
            Warn2 "versions.json carries no digest for tag ${Tag}: the image is used as Docker Hub served it, unverified."
        }
        Ok "Image pulled"
        return $true
    }
    $digests = (Invoke-NanoEngine image inspect -f "{{range .RepoDigests}}{{.}} {{end}}" $image).Trim()
    if ($digests -match [regex]::Escape("@sha256:$pin")) {
        Ok "Image pulled and verified (sha256:$($pin.Substring(0, 12))...)"
        return $true
    }
    Warn2 "The pulled image does not match the digest versions.json pins for tag $Tag."
    Info "Pinned:  sha256:$pin"
    Info "Pulled:  $(if ($digests) { $digests } else { '(no digest recorded)' })"
    Info "The image was removed and nothing was started. Either Docker Hub now serves different bytes under that tag, or the pin is stale: re-run with a current kit (exakit update), or check the tag at https://hub.docker.com/r/exasol/nano/tags"
    [void](Invoke-ExakitLogged $engine "image" "rm" "-f" $image)
    return $false
}

# Install-Nano - pull the pinned image and start the container; the first run
# deploys the database with a generated SYS password. Idempotent: a running
# container is adopted, a stopped one started, a missing one created. On the
# soft path it sets NanoNoDatabase and returns, having said why. Twin of
# Install-PersonalDeployment in the installer's eyes.
function Install-Nano {
    $script:NanoNoDatabase = $false
    Resolve-NanoNames
    $engine = Get-NanoEngine
    if (-not $engine) {
        Set-ExakitFailureReason "Docker Desktop is not running."
        Warn2 "Docker Desktop is not running, so the database cannot be installed. Start it, then re-run the installer."
        $script:NanoNoDatabase = $true
        return
    }
    $tag = Get-NanoTargetTag

    if ((Test-NanoContainerRunning) -and (Test-NanoDeploymentRunning)) {
        Ok "Nano container already running and healthy"
        Set-NanoManifest -Status "running"
        return
    }
    if ((Test-NanoContainerExists) -and -not (Test-NanoContainerRunning)) {
        Info "Found the existing Nano container - starting it"
        try {
            Start-NanoExisting
        } catch [ExakitFailException] {
            Set-ExakitFailureReason "The existing Nano container could not be started."
            $script:NanoNoDatabase = $true
            return
        }
        if (-not (Wait-NanoReady)) {
            Set-ExakitFailureReason "The Nano container did not become ready."
            $script:NanoNoDatabase = $true
            return
        }
        Set-NanoManifest -Status "running"
        return
    }
    if (Test-NanoContainerRunning) {
        # Running, not yet answering: a container started moments ago.
        if (-not (Wait-NanoReady)) {
            Set-ExakitFailureReason "The Nano container did not become ready."
            $script:NanoNoDatabase = $true
            return
        }
        Set-NanoManifest -Status "running"
        return
    }

    # No container: the port must be free, the image pinned and pulled, the
    # password generated, the container created.
    $port = Get-NanoDbPort
    if (Test-ExakitPortInUse $port) {
        Set-ExakitFailureReason "Port $port is already in use."
        Warn2 "Port $port is already in use by another application, so the database cannot be published there. Stop that application (or set EXAKIT_DB_PORT to another port), then re-run the installer."
        $script:NanoNoDatabase = $true
        return
    }
    if (-not (Invoke-NanoPull -Tag $tag)) {
        Set-ExakitFailureReason "The Nano image could not be pulled or verified."
        $script:NanoNoDatabase = $true
        return
    }
    $image = Get-NanoImageRef -Tag $tag

    $password = Get-ExakitCredential "nano_sys_password"
    if (-not $password) {
        $password = New-ExakitPassword
        Set-ExakitCredential "nano_sys_password" $password
    }
    $pwFile = Join-Path $script:CredsDir "nano_sys_password"
    # Forward slashes: Docker's bind-mount parsing on Windows is picky about
    # backslashes in the source half of "C:\...:/run/secrets/...:ro".
    $pwFileMount = $pwFile -replace '\\', '/'

    Info "Starting the Nano container ($($script:NanoContainer))"
    $runArgs = Get-NanoRunArgs
    $runArgs += @("-v", "${pwFileMount}:/run/secrets/sys_password:ro")
    if ((Invoke-ExakitLogged $engine @runArgs $image "init" "sys_password_file=/run/secrets/sys_password") -ne 0) {
        Set-ExakitFailureReason "The Nano container failed to start."
        Warn2 "The Nano container failed to start (see the log: exakit logs setup)."
        $script:NanoNoDatabase = $true
        return
    }

    # Prove the engine mounted the secret rather than trusting the bind mount.
    # The image has no shell and no coreutils (its entrypoint is the one
    # /controller binary), so nothing can be run inside it to read the file;
    # what the engine records for the container is the next best witness, and
    # a Docker Desktop that refuses the path (file sharing) fails the run above
    # outright. The check never ends the install.
    try {
        $mounts = Invoke-NanoEngine container inspect -f "{{range .Mounts}}{{.Destination}} {{end}}" $script:NanoContainer
        if ($mounts -notmatch "/run/secrets/sys_password") {
            Warn2 "The generated password file does not appear among the container's mounts (a Docker Desktop file-sharing issue on Windows). The database may be using a different password from the one recorded locally."
            Warn2 "If the connection check below fails: Docker Desktop > Settings > Resources > File sharing must include your user profile drive; then run 'exakit uninstall' and re-install."
        }
    } catch {
        Write-ExakitLog "WARN" "Could not verify the secret mount: $_"
    }

    if (-not (Wait-NanoReady)) {
        Set-ExakitFailureReason "The Nano container did not become ready."
        $script:NanoNoDatabase = $true
        return
    }
    Set-NanoManifest -Status "running"
}

# Set-NanoManifest - the runtime record, under the same keys the Personal
# module writes so exapump, the AI bridge and pyexasol read one shape.
function Set-NanoManifest {
    param([string]$Status = "")
    Resolve-NanoNames
    Set-ExakitManifestValue "runtime.type" "nano"
    Set-ExakitManifestValue "runtime.engine" "docker"
    $image = (Invoke-NanoEngine container inspect -f "{{.Config.Image}}" $script:NanoContainer).Trim()
    if (-not $image) { $image = Get-NanoImageRef }
    Set-ExakitManifestValue "runtime.image" $image
    # runtime.version is the COMPONENT the kit compares against versions.json:
    # the image tag.
    $tag = ""
    if ($image -match ':([^:/]+)$') { $tag = $Matches[1] }
    if (-not $tag) { $tag = Get-NanoTargetTag }
    Set-ExakitManifestValue "runtime.version" $tag
    Set-ExakitManifestValue "runtime.container" $script:NanoContainer
    Set-ExakitManifestValue "runtime.volume" $script:NanoVolume
    Set-ExakitManifestValue "runtime.dsn" "127.0.0.1:$(Get-NanoDbPort)"
    Set-ExakitManifestValue "runtime.user" "sys"
    Set-ExakitManifestValue "runtime.password_file" (Join-Path $script:CredsDir "nano_sys_password")
    Set-ExakitManifestValue "runtime.tls" "self-signed"
    # Keys a Personal record carries and a Nano one must not: a stale launcher
    # path would send `exakit update` after a binary that is not there.
    foreach ($stale in @("runtime.launcher", "runtime.deployment_dir", "runtime.deployment_version", "runtime.guest_rebuilt_for")) {
        try { Remove-ExakitManifestValue $stale } catch { }
    }
    if (-not $Status) { $Status = Get-NanoStatus }
    Set-ExakitManifestValue "runtime.status" $Status
}

# --- lifecycle (used by exakit) ---------------------------------------------------

function Start-Nano {
    Resolve-NanoNames
    if (-not (Get-NanoEngine)) {
        Fail "Docker Desktop is not running, so the database cannot start. Start Docker Desktop, then: exakit start"
    }
    if (-not (Test-NanoContainerExists)) { Fail "No Nano container found. Re-run the installer: $(Get-ExakitInstallCommand)" }
    if (Test-NanoContainerRunning) { Ok "Nano container is already running"; return }
    Start-NanoExisting
    Ok "Database started"
}

function Stop-Nano {
    Resolve-NanoNames
    if (-not (Get-NanoEngine)) {
        # Nothing to stop when the engine is down: the container is down with it.
        Set-ExakitManifestValue "runtime.status" "stopped"
        Ok "Docker Desktop is not running, so the database is already stopped"
        return
    }
    if (-not (Test-NanoContainerRunning)) { Ok "Nano container is not running"; Set-ExakitManifestValue "runtime.status" "stopped"; return }
    Info "Stopping the Nano container (waiting up to 60s for a clean shutdown)"
    if ((Invoke-ExakitLogged (Get-NanoEngine) "stop" "-t" "60" $script:NanoContainer) -ne 0) { Fail "Failed to stop the database." }
    Set-ExakitManifestValue "runtime.status" "stopped"
    Ok "Database stopped"
}

# Remove-Nano [-Data] - remove the container; -Data also removes the data
# volume (every table you loaded). Docker Desktop itself is untouched.
function Remove-Nano {
    param([switch]$Data)
    Resolve-NanoNames
    $engine = Get-NanoEngine
    if (-not $engine) {
        Warn2 "Docker Desktop is not running, so the container '$($script:NanoContainer)' and its volume were left in place. Remove them by hand once it runs: docker rm -f $($script:NanoContainer); docker volume rm $($script:NanoVolume)"
        Set-ExakitManifestValue "runtime.status" "removed"
        return
    }
    if (Test-NanoContainerExists) {
        Info "Removing the Nano container"
        if ((Invoke-ExakitLogged $engine "rm" "-f" $script:NanoContainer) -ne 0) { Warn2 "Container removal reported errors" }
    } else {
        Warn2 "No container named '$($script:NanoContainer)' found - nothing to remove"
    }
    if ($Data) {
        $vol = (Invoke-NanoEngine volume inspect -f "{{.Name}}" $script:NanoVolume).Trim()
        if ($vol -eq $script:NanoVolume) {
            Info "Removing the data volume $($script:NanoVolume)"
            if ((Invoke-ExakitLogged $engine "volume" "rm" $script:NanoVolume) -ne 0) { Warn2 "Volume removal reported errors" }
        }
    } else {
        Info "Data volume $($script:NanoVolume) kept (an uninstall removes it)"
    }
    Set-ExakitManifestValue "runtime.status" "removed"
}

# Update-Nano - move the container to the advertised tag over the same data
# volume. The old image is restored when the new one does not come up.
function Update-Nano {
    param([string]$Advertised = "")
    Resolve-NanoNames
    if (-not $Advertised) { $Advertised = Get-NanoTargetTag }
    $engine = Get-NanoEngine
    if (-not $engine) { Fail "Docker Desktop is not running, so the database cannot be updated. Start it, then: exakit update" }
    $currentImage = "" + (Get-ExakitManifestValue "runtime.image")
    $currentTag = ""
    if ($currentImage -match ':([^:/]+)$') { $currentTag = $Matches[1] }
    if ($currentTag -eq $Advertised) { Ok "Exasol Nano is already current ($currentTag)"; return }
    if (-not (Invoke-NanoPull -Tag $Advertised)) { Fail "The update was not applied; the running database is untouched." }
    $image = Get-NanoImageRef -Tag $Advertised
    $snapshot = New-NanoUpdateSnapshot -CurrentTag $currentTag -LatestTag $Advertised
    Info "Updating Exasol Nano $(if ($currentTag) { $currentTag } else { 'unknown' }) -> $Advertised"
    Info "The container is recreated; the data volume '$($script:NanoVolume)' is kept. Record: $snapshot"
    if (Test-NanoContainerExists) {
        if (Test-NanoContainerRunning) {
            if ((Invoke-ExakitLogged $engine "stop" "-t" "60" $script:NanoContainer) -ne 0) { Fail "Could not stop $($script:NanoContainer); the update was not applied." }
        }
        if ((Invoke-ExakitLogged $engine "rm" "-f" $script:NanoContainer) -ne 0) { Fail "Could not remove the old Nano container; the update was not applied." }
    }
    $runArgs = Get-NanoRunArgs
    if ((Invoke-ExakitLogged $engine @runArgs $image) -ne 0) {
        Restore-PreviousNanoContainer -Image $currentImage
        Fail "The updated Nano container did not start; the previous image was restored."
    }
    if (-not (Wait-NanoReady)) {
        Restore-PreviousNanoContainer -Image $currentImage
        Fail "The updated Nano container did not become ready; the previous image was restored."
    }
    Set-NanoManifest -Status "running"
    Set-ExakitManifestValue "desired.nano" $Advertised
    Ok "Exasol Nano updated to $Advertised; data volume kept: $($script:NanoVolume)"
}

function New-NanoUpdateSnapshot {
    param([string]$CurrentTag, [Parameter(Mandatory)][string]$LatestTag)
    $backupDir = Join-Path $script:ExakitHome "backups\nano-update"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $safeCurrent = if ($CurrentTag) { $CurrentTag } else { "unknown" }
    $snapshot = Join-Path $backupDir "$stamp-$safeCurrent-to-$LatestTag.json"
    $record = [ordered]@{
        created_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        operation = "nano_update"
        from = $safeCurrent
        to = $LatestTag
        container = $script:NanoContainer
        volume = $script:NanoVolume
        image = "" + (Get-ExakitManifestValue "runtime.image")
    }
    $record | ConvertTo-Json -Depth 6 | Set-Content -Path $snapshot
    try { Protect-ExakitFile $snapshot } catch { }
    return $snapshot
}

function Restore-PreviousNanoContainer {
    param([string]$Image)
    if (-not $Image) { return }
    Warn2 "Restoring the previous Nano container image ($Image)"
    $engine = Get-NanoEngine
    [void](Invoke-ExakitLogged $engine "rm" "-f" $script:NanoContainer)
    $runArgs = Get-NanoRunArgs
    if ((Invoke-ExakitLogged $engine @runArgs $Image) -ne 0) { Warn2 "Could not restore the previous Nano container automatically: docker run ... $Image" }
}

# --- autostart -----------------------------------------------------------------

# Set-NanoRestartPolicy - Docker Desktop brings the container back at login by
# itself when its restart policy says so (and Docker Desktop is set to start
# at sign-in). "unless-stopped" keeps an `exakit stop` stopped across a reboot,
# which is what the stop promised.
function Set-NanoRestartPolicy {
    param([Parameter(Mandatory)][bool]$Enabled)
    Resolve-NanoNames
    $engine = Get-NanoEngine
    if (-not $engine -or -not (Test-NanoContainerExists)) { return $false }
    $policy = if ($Enabled) { "unless-stopped" } else { "no" }
    return ((Invoke-ExakitLogged $engine "update" "--restart" $policy $script:NanoContainer) -eq 0)
}

# Get-NanoAutostartCommand - the Startup-entry command, beside the restart
# policy: a `docker start` is harmless when the policy already did the work,
# and it covers an engine whose policy was dropped by a recreate.
function Get-NanoAutostartCommand {
    Resolve-NanoNames
    return ('"' + (Get-NanoEngineCommand) + '" start ' + $script:NanoContainer)
}

# --- upstream ------------------------------------------------------------------

# Get-NanoLatestTag - the newest stable tag Docker Hub lists for the image,
# of the shape YYYY.M.P-nano.N (the per-architecture and .run tags are
# skipped). "" when the registry does not answer. Used by the `latest`
# policy and by `exakit version` under it.
function Get-NanoLatestTag {
    $uri = "https://hub.docker.com/v2/repositories/$($script:NanoImage)/tags?page_size=100&ordering=last_updated"
    try {
        $doc = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 15
    } catch { return "" }
    $best = ""
    $bestKey = @()
    foreach ($entry in @($doc.results)) {
        $name = "" + $entry.name
        if ($name -notmatch '^(\d+)\.(\d+)\.(\d+)-nano\.(\d+)$') { continue }
        $key = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
        $newer = $false
        if ($bestKey.Count -eq 0) { $newer = $true }
        else {
            for ($i = 0; $i -lt 4; $i++) {
                if ($key[$i] -gt $bestKey[$i]) { $newer = $true; break }
                if ($key[$i] -lt $bestKey[$i]) { break }
            }
        }
        if ($newer) { $best = $name; $bestKey = $key }
    }
    return $best
}
