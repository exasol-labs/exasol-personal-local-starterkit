# nano.ps1 - Exasol Nano container runtime module (Windows / PowerShell path,
# Docker Desktop only).
#
# Dot-sourced by setup-windows-docker.ps1 and setup/exakit.ps1 after
# exakit-common.ps1. Mirrors setup/lib/runtime-nano.sh function-for-function.
#
# Container contract (from the image documentation):
#   - readiness: logs print "Database is now up and running!"
#   - connection: 127.0.0.1:8563, user sys, TLS (self-signed certificate)
#   - recommended limits: --shm-size=512mb --pids-limit=-1

$script:NanoContainer = if ($env:EXAKIT_NANO_CONTAINER) { $env:EXAKIT_NANO_CONTAINER } else { "exasol-nano" }
$script:NanoVolume    = if ($env:EXAKIT_NANO_VOLUME) { $env:EXAKIT_NANO_VOLUME } else { "exasol-nano-data" }
$script:NanoMinRamGb  = if ($env:EXAKIT_NANO_MIN_RAM_GB) { [int]$env:EXAKIT_NANO_MIN_RAM_GB } else { 4 }
$script:NanoReadyTimeout = if ($env:EXAKIT_NANO_READY_TIMEOUT) { [int]$env:EXAKIT_NANO_READY_TIMEOUT } else { 600 }

# Get-NanoEngine - the usable container engine (Docker only on Windows),
# cached after first call.
#
# `docker info` fails loudly (writes to stderr) when Docker Desktop is
# installed but not running - exactly the case Test-NanoRequirements exists
# to give a friendly message for. Under $ErrorActionPreference = 'Stop'
# (set globally by every entry point) a native command's stderr write can
# surface as an uncaught exception instead of a plain non-zero exit code, so
# this is wrapped: a thrown error here means "docker isn't usable", not "the
# whole script should die with a raw stack trace".
function Get-NanoEngine {
    if ($script:NanoEngineCache) { return $script:NanoEngineCache }
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $previousEAP = $ErrorActionPreference
        try {
            # Docker Desktop writes harmless warnings to stderr on 'docker info'.
            # Under the global ErrorActionPreference='Stop', Windows PowerShell
            # 5.1 turns that stderr write into a TERMINATING error before we can
            # read the exit code - so a perfectly healthy Docker was reported as
            # "not running". Switch to Continue (exactly what Invoke-ExakitLogged
            # does) so the exit code, not incidental stderr, decides.
            $ErrorActionPreference = "Continue"
            & docker info *> $null
            if ($LASTEXITCODE -eq 0) { $script:NanoEngineCache = "docker"; return "docker" }
        } catch {
            Write-ExakitLog "WARN" "docker info failed: $_"
        } finally {
            $ErrorActionPreference = $previousEAP
        }
    }
    return $null
}

# Resolve-NanoNames - lifecycle commands must act on the names the install
# actually used (recorded in the manifest), not this shell's defaults. An
# explicit environment override still wins.
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

function Test-NanoRequirements {
    $engine = Get-NanoEngine
    if (-not $engine) {
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            Fail "Docker is installed but not running. Start Docker Desktop and re-run."
        }
        Fail "No container runtime found. Install Docker Desktop (https://docs.docker.com/desktop/), then re-run."
    }
    Ok "Container runtime: $engine"

    # Memory - fail closed if it cannot be read (mirrors the bash detect_ram_gb
    # contract: never let an unreadable value silently skip the guard).
    $ramGb = -1
    try { $ramGb = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB) } catch { $ramGb = -1 }
    if ($env:EXAKIT_FORCE -ne "1") {
        if ($ramGb -lt 0) {
            Fail "Could not determine this machine's memory. Set EXAKIT_FORCE=1 to install anyway."
        } elseif ($ramGb -lt $script:NanoMinRamGb) {
            # On-grid outcome line (6-space cross), mirroring bash's error() + die() pair.
            Write-Host ("      {0}{1}{2} This machine is not compatible: Exasol Nano needs at least {3} GB RAM and this machine has {4} GB." -f $script:UiErr, $script:UiCross, $script:UiReset, $script:NanoMinRamGb, $ramGb)
            Info "Nothing was installed. Re-run on a machine with $($script:NanoMinRamGb)+ GB RAM (or force at your own risk with EXAKIT_FORCE=1)."
            Fail "Insufficient memory: $ramGb GB."
        }
    }

    # Free disk on the system drive (mirrors the bash 10 GB check, which the
    # Windows path was missing).
    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
    $freeGb = -1
    try { $freeGb = [math]::Floor((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'").FreeSpace / 1GB) } catch { $freeGb = -1 }
    if ($env:EXAKIT_FORCE -ne "1") {
        if ($freeGb -lt 0) {
            Fail "Could not determine free disk space on $sysDrive. Free up space or set EXAKIT_FORCE=1 to install anyway."
        } elseif ($freeGb -lt 10) {
            # On-grid outcome line (6-space cross), mirroring bash's error() + die() pair.
            Write-Host ("      {0}{1}{2} This machine is not compatible right now: the database image and data need at least 10 GB free on {3} and it has {4} GB." -f $script:UiErr, $script:UiCross, $script:UiReset, $sysDrive, $freeGb)
            Info "Nothing was installed. Free up disk space and re-run (or force at your own risk with EXAKIT_FORCE=1)."
            Fail "Insufficient free disk space: $freeGb GB."
        }
    }

    # Bare minimum: run, but say what to expect.
    if ($ramGb -ge 0 -and $ramGb -lt ($script:NanoMinRamGb + 2)) {
        Warn2 "Memory is at the bare minimum ($ramGb GB) - the database will run, but expect slower queries and keep other heavy apps closed."
    }
    if ($freeGb -ge 0 -and $freeGb -lt 20) {
        Warn2 "Free disk is tight ($freeGb GB) - fine for the bundled datasets, but watch space before loading large files."
    }
    Ok "Compatibility check passed ($ramGb GB RAM, $freeGb GB free)"
}

function Get-NanoImageRef { return "docker.io/$($script:NanoImage):$($script:NanoTag)" }

function Test-NanoContainerExists {
    try {
        & (Get-NanoEngine) container inspect $script:NanoContainer *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-NanoContainerRunning {
    try {
        $state = & (Get-NanoEngine) container inspect -f "{{.State.Running}}" $script:NanoContainer 2>$null
        return ($state -eq "true")
    } catch {
        return $false
    }
}

# Test-NanoReadyInLogs - ready marker from the CURRENT boot only. Container
# logs survive stop/start, so scanning the full history would match a stale
# line from a previous boot; scoping to StartedAt also keeps each poll cheap.
function Test-NanoReadyInLogs {
    $engine = Get-NanoEngine
    try {
        $started = & $engine container inspect -f "{{.State.StartedAt}}" $script:NanoContainer 2>$null
        if (-not $started) { $started = "1970-01-01T00:00:00Z" }
        $logs = & $engine logs --since $started $script:NanoContainer 2>&1
        return (($logs -join "`n") -match "Database is now up and running!")
    } catch {
        return $false
    }
}

# The container was created with the first-deploy-only
# 'init sys_password_file=...' arguments. Nano refuses to boot with them
# once /exa is initialized, so such a container cannot simply be restarted.
function Test-NanoFirstDeployArgs {
    # Use '{{.Config.Cmd}}' (Go renders the []string as "[a b c]") rather than
    # '{{join .Config.Cmd " "}}': the embedded double-quotes in the join
    # template get mangled when PowerShell builds the native command line for
    # docker.exe on Windows, breaking the template. We only test for a token's
    # presence, so the bracketed form works and needs no embedded quotes.
    $cmd = & (Get-NanoEngine) container inspect -f '{{.Config.Cmd}}' $script:NanoContainer 2>$null
    return ("$cmd" -match "sys_password_file")
}

# Bring a stopped container back up, recreating it first when it still
# carries the single-use first-deploy arguments (the data volume carries
# the database and its password forward).
function Start-NanoExisting {
    $engine = Get-NanoEngine
    if (Test-NanoFirstDeployArgs) {
        $image = & $engine container inspect -f "{{.Config.Image}}" $script:NanoContainer 2>$null
        if (-not $image) { $image = Get-NanoImageRef }
        Info "Recreating the Nano container (first-deploy options are single-use; the data volume is kept)"
        $code = Invoke-ExakitLogged $engine "rm" "-f" $script:NanoContainer
        if ($code -ne 0) { Fail "Could not replace the old container (see log)" }
        $code = Invoke-ExakitLogged $engine "run" "-d" "--name" $script:NanoContainer `
            "--shm-size=512mb" "--pids-limit=-1" `
            "-p" "127.0.0.1:$($script:DbPort):8563" `
            "-v" "$($script:NanoVolume):/exa" `
            $image
        if ($code -ne 0) { Fail "Container failed to start (see log)" }
    } else {
        $code = Invoke-ExakitLogged $engine "start" $script:NanoContainer
        if ($code -ne 0) { Fail "Could not start existing container $($script:NanoContainer) (see log)" }
    }
    Wait-NanoReady
}

# Install-Nano - pull the pinned image and start the container (first run
# deploys the database with a generated SYS password). Idempotent.
function Install-Nano {
    $engine = Get-NanoEngine
    $image = Get-NanoImageRef

    if ((Test-NanoContainerRunning) -and (Test-NanoReadyInLogs)) {
        Ok "Nano container already running and healthy"
        Set-NanoManifest
        return
    }

    if ((Test-NanoContainerExists) -and -not (Test-NanoContainerRunning)) {
        Info "Found existing Nano container - starting it"
        Start-NanoExisting
        Set-NanoManifest
        return
    }

    if (-not (Test-NanoContainerExists)) {
        $portBusy = Test-ExakitPortInUse -Port ([int]$script:DbPort)
        if ($portBusy) {
            Fail "Port $($script:DbPort) is already in use by another application. Stop it or set EXAKIT_DB_PORT, then re-run."
        }
        Info "Pulling image $image"
        $pulled = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $code = Invoke-ExakitLogged $engine "pull" $image
            if ($code -eq 0) { $pulled = $true; break }
            if ($attempt -lt 3) { Warn2 "Pull attempt $attempt failed - retrying in $($attempt * 10)s"; Start-Sleep -Seconds ($attempt * 10) }
        }
        if (-not $pulled) { Fail "Image pull failed after 3 attempts: $image (network/Docker Hub issue - see log)" }
        Ok "Image pulled"

        $password = Get-ExakitCredential "nano_sys_password"
        if (-not $password) {
            $password = New-ExakitPassword
            Set-ExakitCredential "nano_sys_password" $password
        }
        $pwFile = Join-Path $script:CredsDir "nano_sys_password"
        # Docker's bind-mount source parsing on Windows is picky about
        # backslashes (Join-Path produces "C:\Users\...\nano_sys_password",
        # and mixing that with the ":/run/secrets/...:ro" suffix can mis-parse
        # or silently mount the wrong thing) - forward slashes are the
        # documented, reliable form for a -v source path on Windows.
        $pwFileMount = $pwFile -replace '\\', '/'

        Info "Starting Nano container ($($script:NanoContainer))"
        $code = Invoke-ExakitLogged $engine "run" "-d" "--name" $script:NanoContainer `
            "--shm-size=512mb" "--pids-limit=-1" `
            "-p" "127.0.0.1:$($script:DbPort):8563" `
            "-v" "$($script:NanoVolume):/exa" `
            "-v" "${pwFileMount}:/run/secrets/sys_password:ro" `
            $image "init" "sys_password_file=/run/secrets/sys_password"
        if ($code -ne 0) { Fail "Container failed to start (see log)" }

        # Verify the secret actually landed in the container instead of
        # silently trusting the bind mount. If it didn't, the database ends
        # up with a different (or no) password than the one written to
        # ~\.exasol-starter-kit\credentials\nano_sys_password, and every
        # later SQL connection attempt fails with no obvious cause - this
        # catches that here, immediately, with a specific fix.
        try {
            Start-Sleep -Seconds 2
            $mountedSize = & $engine exec $script:NanoContainer sh -c "wc -c < /run/secrets/sys_password 2>/dev/null || echo 0" 2>$null
            $expectedSize = (Get-Item $pwFile).Length
            if (($mountedSize | Select-Object -Last 1).Trim() -ne "$expectedSize") {
                Warn2 "The generated password file did not mount into the container as expected (this is a known Docker Desktop on Windows bind-mount issue). The database may be using a different password than the one recorded locally."
                Warn2 "If the connection check below fails, try: Settings > Resources > File sharing in Docker Desktop, ensure your user profile drive is shared, then run 'exakit uninstall' and re-install."
            }
        } catch {
            # Diagnostic-only: if we can't even check (container not exec-able
            # yet, no `sh`, etc.), don't let that abort the install.
            Write-ExakitLog "WARN" "Could not verify the secret mount: $_"
        }
    }

    Wait-NanoReady
    Set-NanoManifest
}

# Wait-NanoReady - poll container logs until the database reports ready.
function Wait-NanoReady {
    Info "Waiting for the database to come up (timeout: $($script:NanoReadyTimeout)s)"
    $engine = Get-NanoEngine
    $waited = 0
    while ($waited -lt $script:NanoReadyTimeout) {
        if (-not (Test-NanoContainerRunning)) {
            try {
                $tail = & $engine logs --tail 30 $script:NanoContainer 2>&1
                if ($script:LogFile) { $tail | Add-Content -Path $script:LogFile }
            } catch {
                if ($script:LogFile) { "Could not read container logs: $_" | Add-Content -Path $script:LogFile }
            }
            Fail "Nano container stopped unexpectedly (see log)"
        }
        if (Test-NanoReadyInLogs) { Ok "Database is up (took ~${waited}s)"; return }
        Start-Sleep -Seconds 5
        $waited += 5
        if ($waited % 30 -eq 0) { Info "Still starting... (${waited}s)" }
    }
    Write-Host "  x Database did not become ready within $($script:NanoReadyTimeout)s." -ForegroundColor Red
    Write-Host "    Inspect the logs:   $engine logs $($script:NanoContainer)"
    Write-Host "    If a first install was interrupted, the data volume may be half-initialized."
    Write-Host "    Reset and retry:    $engine rm -f $($script:NanoContainer) && $engine volume rm $($script:NanoVolume)"
    Fail "Nano startup timed out"
}

function Set-NanoManifest {
    Set-ExakitManifestValue "runtime.type" "nano"
    Set-ExakitManifestValue "runtime.engine" (Get-NanoEngine)
    Set-ExakitManifestValue "runtime.image" (Get-NanoImageRef)
    Set-ExakitManifestValue "runtime.container" $script:NanoContainer
    Set-ExakitManifestValue "runtime.volume" $script:NanoVolume
    Set-ExakitManifestValue "runtime.dsn" "127.0.0.1:$($script:DbPort)"
    Set-ExakitManifestValue "runtime.user" "sys"
    Set-ExakitManifestValue "runtime.password_file" (Join-Path $script:CredsDir "nano_sys_password")
    Set-ExakitManifestValue "runtime.tls" "self-signed"
    Set-ExakitManifestValue "runtime.status" "healthy"
}

# --- lifecycle (used by exakit) ---------------------------------------------
function Get-NanoStatus {
    Resolve-NanoNames
    if (-not (Test-NanoContainerExists)) { return "not installed" }
    if (-not (Test-NanoContainerRunning)) { return "stopped" }
    if (Test-NanoReadyInLogs) { return "running" }
    return "starting"
}

function Start-Nano {
    Resolve-NanoNames
    if (-not (Test-NanoContainerExists)) { Fail "No Nano container found. Run the installer first." }
    if (Test-NanoContainerRunning) { Ok "Nano container is already running"; return }
    Start-NanoExisting
    Ok "Nano started"
}

function Stop-Nano {
    Resolve-NanoNames
    if (-not (Test-NanoContainerRunning)) { Ok "Nano container is not running"; return }
    Info "Stopping Nano container (waiting up to 60s for a clean shutdown)"
    $code = Invoke-ExakitLogged (Get-NanoEngine) "stop" "-t" "60" $script:NanoContainer
    if ($code -ne 0) { Fail "Failed to stop container" }
    Set-ExakitManifestValue "runtime.status" "stopped"
    Ok "Nano stopped"
}

# Remove-Nano [-Data] - remove the container; -Data also removes the
# persistent volume (all database content).
function Remove-Nano {
    param([switch]$Data)
    Resolve-NanoNames
    $engine = Get-NanoEngine
    if (Test-NanoContainerExists) {
        Info "Removing Nano container"
        $code = Invoke-ExakitLogged $engine "rm" "-f" $script:NanoContainer
        if ($code -ne 0) { Warn2 "Container removal failed" }
    } else {
        Warn2 "No container named '$($script:NanoContainer)' found - nothing to remove (was it created under a different name?)"
    }
    if ($Data) {
        $volumeExists = $false
        try {
            & $engine volume inspect $script:NanoVolume *> $null
            $volumeExists = ($LASTEXITCODE -eq 0)
        } catch { }
        if ($volumeExists) {
            Info "Removing data volume $($script:NanoVolume)"
            $code = Invoke-ExakitLogged $engine "volume" "rm" $script:NanoVolume
            if ($code -ne 0) { Warn2 "Volume removal failed" }
        }
    } else {
        Info "Data volume $($script:NanoVolume) kept (pass -Data to remove it)"
    }
    Set-ExakitManifestValue "runtime.status" "removed"
}

function Update-Nano {
    param([Parameter(Mandatory)][string]$LatestTag)
    Resolve-NanoNames
    $currentImage = Get-ExakitManifestValue "runtime.image"
    $currentTag = if ($currentImage -and $currentImage.Contains(":")) { ($currentImage -split ":")[-1] } else { "" }
    if ($currentTag -eq $LatestTag) { Ok "Exasol Nano is already current ($currentTag)"; return }

    $engine = Get-NanoEngine
    $image = "docker.io/$($script:NanoImage):$LatestTag"
    $oldImage = if ($currentTag) { "docker.io/$($script:NanoImage):$currentTag" } else { "" }
    $snapshot = New-NanoUpdateSnapshot -CurrentTag $currentTag -LatestTag $LatestTag
    Info "Updating Exasol Nano $currentTag -> $LatestTag"
    Info "The container will be recreated; the data volume '$($script:NanoVolume)' is kept."
    Info "Pre-update runtime snapshot: $snapshot"
    $code = Invoke-ExakitLogged $engine "pull" $image
    if ($code -ne 0) { Fail "Could not pull $image" }

    if (Test-NanoContainerExists) {
        if (Test-NanoContainerRunning) {
            $code = Invoke-ExakitLogged $engine "stop" "-t" "60" $script:NanoContainer
            if ($code -ne 0) { Fail "Could not stop $($script:NanoContainer)" }
        }
        $code = Invoke-ExakitLogged $engine "rm" "-f" $script:NanoContainer
        if ($code -ne 0) { Fail "Could not remove old Nano container" }
    }

    $code = Invoke-ExakitLogged $engine "run" "-d" "--name" $script:NanoContainer `
        "--shm-size=512mb" "--pids-limit=-1" `
        "-p" "127.0.0.1:$($script:DbPort):8563" `
        "-v" "$($script:NanoVolume):/exa" `
        $image
    if ($code -ne 0) {
        Restore-PreviousNanoContainer -Image $oldImage
        Fail "Could not start updated Nano container; attempted to restore the previous image."
    }
    $script:NanoTag = $LatestTag
    try {
        Wait-NanoReady
    } catch [ExakitFailException] {
        Restore-PreviousNanoContainer -Image $oldImage
        Fail "Updated Nano container did not become ready; attempted to restore the previous image."
    }
    Set-NanoManifest
    Set-ExakitManifestValue "desired.runtime.nano" $script:NanoTag
    Set-ExakitManifestValue "backups.nano_update.latest" $snapshot
    Ok "Nano updated; data volume kept: $($script:NanoVolume)"
}

function New-NanoUpdateSnapshot {
    param([string]$CurrentTag, [Parameter(Mandatory)][string]$LatestTag)
    $backupDir = Join-Path $script:ExakitHome "backups\nano-update"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $safeCurrent = if ($CurrentTag) { $CurrentTag } else { "unknown" }
    $snapshot = Join-Path $backupDir "$stamp-$safeCurrent-to-$LatestTag.json"
    $record = [pscustomobject]@{
        created_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        operation = "nano_update"
        from = $safeCurrent
        to = $LatestTag
        container = $script:NanoContainer
        volume = $script:NanoVolume
        image = Get-ExakitManifestValue "runtime.image"
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
    Invoke-ExakitLogged $engine "rm" "-f" $script:NanoContainer | Out-Null
    $code = Invoke-ExakitLogged $engine "run" "-d" "--name" $script:NanoContainer `
        "--shm-size=512mb" "--pids-limit=-1" `
        "-p" "127.0.0.1:$($script:DbPort):8563" `
        "-v" "$($script:NanoVolume):/exa" `
        $Image
    if ($code -ne 0) { Warn2 "Could not restore the previous Nano container automatically." }
}
