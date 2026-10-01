# dash-server.ps1 - dash-server (AI dashboard host): managed install + validation.
#
# Windows counterpart of dash-server.sh. A MARKETPLACE ADD-ON: never installed
# by the setup scripts. The user picks it from `exakit marketplace`; once
# installed it joins `exakit update` like every other component.
#
# dash-server facts:
#   - Agent-operated Dash hosting server for Exasol-backed dashboards
#     (github.com/exasol-labs/dash-server): agents build and deploy dashboards
#     through its MCP control plane (Streamable HTTP at /mcp).
#   - Pure-Python package with a dash-server console script; releases carry no
#     prebuilt binaries, so the install is `uv pip install` of the tag's source
#     tarball into a dedicated venv under the kit home - the same tag-pinned,
#     tag-pinned posture as mcp and pyexasol - but with NO digest
#     verification: the release publishes no digest for the tarball, unlike
#     the binary add-ons.
#   - Control plane: 127.0.0.1:5100. The PORT half is settable
#     (DASH_SERVER_PORT, and the kit records the port it chose). The HOST
#     half is NOT: every start below passes --host 127.0.0.1 explicitly,
#     which outranks DASH_SERVER_HOST. This control plane is
#     unauthenticated, so binding it off loopback would publish the
#     database to the LAN. The env setdefault in the launcher is a floor
#     for someone running that launcher by hand, not a knob the kit reads.
#   - Exasol profile bootstrap at startup via DASH_SERVER_EXASOL_* env vars;
#     the launcher below feeds it the kit's local database.
#
#   - venv:     ~\.exasol-starter-kit\dash-server-venv
#   - state:    ~\.exasol-starter-kit\dash-server\instance
#   - launcher: ~\.local\bin\dash-server.cmd
#
# Requires exakit-common.ps1 dot-sourced first. Safe to re-run: an existing
# venv with the desired version installed is kept as-is.

# The add-on's version constants live here, next to the code that uses them -
# the generic registry arms in exakit.ps1 find them through the marketplace
# registry entry, and the versions-bump workflow keeps the fallback in
# lockstep with versions.json (COUPLED table).
$script:DashServerRepo = "exasol-labs/dash-server"
$script:DashServerVersionFallback = if ($env:EXAKIT_DASH_SERVER_VERSION_FALLBACK) { $env:EXAKIT_DASH_SERVER_VERSION_FALLBACK } else { "0.1.1" }
$script:DashServerVersion = if ($env:EXAKIT_DASH_SERVER_VERSION) { $env:EXAKIT_DASH_SERVER_VERSION } else { "" }
$script:DashServerVenv = if ($env:EXAKIT_DASH_SERVER_VENV) { $env:EXAKIT_DASH_SERVER_VENV } else { Join-Path $script:ExakitHome "dash-server-venv" }
$script:DashServerHome = if ($env:EXAKIT_DASH_SERVER_HOME) { $env:EXAKIT_DASH_SERVER_HOME } else { Join-Path $script:ExakitHome "dash-server" }
$script:DashServerPort = if ($env:EXAKIT_DASH_SERVER_PORT) { $env:EXAKIT_DASH_SERVER_PORT } else { "5100" }
$script:DashServerPortExplicit = [bool]$env:EXAKIT_DASH_SERVER_PORT
$script:DashServerPortResolved = $false
$script:DashServerProfile = if ($env:EXAKIT_DASH_SERVER_PROFILE) { $env:EXAKIT_DASH_SERVER_PROFILE } else { "starter-kit" }

# Resolve-DashServerPort - the port the INSTALL recorded wins over this
# module's default, exactly as the shell half has always resolved it
# (_dash_server_resolve_port). Without this, an install on a non-default port
# printed "recorded, so every command agrees" and then every later Windows
# command talked to 5100 anyway. An explicit environment override still wins.
function Resolve-DashServerPort {
    if ($script:DashServerPortResolved) { return }
    $script:DashServerPortResolved = $true
    if ($script:DashServerPortExplicit) { return }
    $recorded = "" + (Get-ExakitManifestValue "components.dash_server.port")
    if ($recorded -match '^[0-9]+$') { $script:DashServerPort = $recorded }
}

function Get-DashServerVenvPython {
    return (Join-Path $script:DashServerVenv "Scripts\python.exe")
}

function Get-DashServerLauncherPath {
    return (Join-Path $script:BinDir "dash-server.cmd")
}

# dash-server exposes no __version__; the distribution metadata written by the
# install is the authority. Twin of dash_server_installed_version.
# Get-DashServerPackageVersion - what the VENV alone says, with no opinion on
# whether the add-on is usable yet. The installer asks this immediately after
# pip, before the launcher exists; Get-DashServerInstalledVersion below is the
# stricter question every other caller wants.
function Get-DashServerPackageVersion {
    $python = Get-DashServerVenvPython
    if (-not (Test-Path $python)) { return $null }
    # stderr from a broken venv is a TERMINATING error under the global
    # "Stop" preference, so this probe has to answer inside a Continue window
    # or it crashes `exakit version` and `exakit marketplace` instead of
    # reporting "not installed".
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $version = & $python -c "from importlib.metadata import version; print(version('dash-server'))" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($version | Out-String -Width 4096).Trim()
    } catch {
        return $null
    } finally { $ErrorActionPreference = $prevEap }
}

function Get-DashServerInstalledVersion {
    # The manifest RECORD as well as the venv. The record is written at the END
    # of a successful install, so an install that died earlier - the Windows tar
    # failure did exactly that, leaving a venv and nothing else - no longer
    # reports a version for something no command can start. Every caller
    # believed the old answer: `exakit marketplace` said "already present -
    # nothing to install", `exakit update dash-server` said "everything is
    # already current", and Start-DashServer said "not installed", with no
    # documented command able to recover it.
    #
    # Both halves, because neither alone is evidence: the record may have been
    # written by another machine, and the venv may be a half-install.
    # Get-JsonTablesInstalledVersion already takes exactly this line.
    if (-not (Get-ExakitManifestValue "components.dash_server.version")) { return $null }
    return (Get-DashServerPackageVersion)
}

# The source tarball of the tagged release. Twin of dash_server_release_url.
function Get-DashServerReleaseUrl {
    param([Parameter(Mandatory)][string]$Version)
    return "https://github.com/$($script:DashServerRepo)/archive/refs/tags/v$Version.tar.gz"
}

# Write-DashServerNotInstalled <reason> - report a soft failure and return
# $false. Marketplace add-ons follow the pyexasol contract: nothing here may
# end the caller's run. Mirrors _dash_server_not_installed in dash-server.sh.
function Write-DashServerNotInstalled {
    param([Parameter(Mandatory)][string]$Reason)
    Warn2 "dash-server was not installed: $Reason"
    Warn2 "Everything else in the kit is unaffected. Retry with: exakit update"
    if (Get-Command Set-ExakitFailureReason -ErrorAction SilentlyContinue) {
        Set-ExakitFailureReason $Reason
    }
    Set-ExakitManifestValue "components.dash_server.validated" $false
    return $false
}

function Install-DashServer {
    Resolve-DashServerPort
    # Resolve the advertised version here (env override -> policy ->
    # versions.json -> fallback): neither caller has one ready. The marketplace
    # path runs from the exakit CLI, where Resolve-ExakitInstallVersions has not
    # run; the setup script's closing offer does not load the CLI at all, so
    # Get-ExakitComponentAvailable is not even defined there.
    # Get-ExakitAddonAdvertisedVersion answers in both.
    if (-not $script:DashServerVersion) {
        $script:DashServerVersion = Get-ExakitAddonAdvertisedVersion -Id "dash-server" -Fallback $script:DashServerVersionFallback
    }

    if (-not (Confirm-DashServerPort)) { return $false }

    try {
        $uv = Install-ExakitUv
    } catch {
        return (Write-DashServerNotInstalled "uv (the Python tool runner) is not available - install it from https://docs.astral.sh/uv/ and re-run")
    }
    $python = Get-DashServerVenvPython

    $current = Get-DashServerInstalledVersion
    if ($current -and $current -eq $script:DashServerVersion -and $env:EXAKIT_FORCE_COMPONENT_INSTALL -ne "1") {
        Ok "dash-server $current already installed: $script:DashServerVenv"
        # An up-to-date venv can still be missing pip (created by a kit copy
        # from before the venv was seeded) - repair it in place.
        if (-not (Confirm-DashServerPip -Uv $uv)) { return $false }
    } else {
        Info "Installing dash-server $($script:DashServerVersion)"
        if (-not (Test-Path $python)) {
            # --seed matters: dash-server installs each app's dependencies by
            # shelling out to `python -m pip`, and a bare uv venv has no pip -
            # every app build (including the built-in demo) would fail.
            $code = Invoke-ExakitLogged $uv "venv" "--seed" "--python" $script:ManagedPythonVersion $script:DashServerVenv
            if ($code -ne 0) {
                return (Write-DashServerNotInstalled "the virtual environment at $script:DashServerVenv could not be created (see log)")
            }
        }
        # The release's source tarball, pinned by tag. uv resolves and installs
        # it plus dependencies from PyPI over TLS.
        $code = Invoke-ExakitLogged $uv "pip" "install" "--python" $python (Get-DashServerReleaseUrl -Version $script:DashServerVersion)
        if ($code -ne 0) {
            return (Write-DashServerNotInstalled "installing dash-server v$($script:DashServerVersion) from its GitHub release failed (see log)")
        }
        # The install is not done until the venv can answer for the version: a
        # tarball that unpacked but failed to build would otherwise be reported
        # as installed and only fail at first launch.
        if (-not (Get-DashServerPackageVersion)) {
            return (Write-DashServerNotInstalled "the venv cannot report a dash-server version after the install (see log)")
        }
        # Belt and braces even on a fresh venv: --seed above should have put
        # pip in place, but a pre-existing venv may lack it.
        if (-not (Confirm-DashServerPip -Uv $uv)) { return $false }
        Restore-DashServerPackageData
        Ok "dash-server installed: $script:DashServerVenv"
    }

    $instance = Join-Path $script:DashServerHome "instance"
    New-Item -ItemType Directory -Force -Path $instance | Out-Null
    if (-not (Write-DashServerLauncher)) { return $false }

    Set-ExakitManifestValue "components.dash_server.version" $script:DashServerVersion
    Set-ExakitManifestValue "components.dash_server.venv" $script:DashServerVenv
    Set-ExakitManifestValue "components.dash_server.python" $python
    Set-ExakitManifestValue "components.dash_server.command" (Get-DashServerLauncherPath)
    Set-ExakitManifestValue "components.dash_server.port" $script:DashServerPort
    Set-ExakitManifestValue "components.dash_server.instance" $instance

    # AFTER the port is recorded, because that record is where the endpoint
    # URL comes from. Until this ran, dash-server's control plane was
    # registered nowhere: an agent had to hand-roll an HTTP transport against
    # /mcp to reach tools that every other MCP server on the machine offers by
    # name. Twin of the same call in dash_server_install.
    if (Get-Command Register-ExakitAddonMcpServers -ErrorAction SilentlyContinue) {
        try { [void](Register-ExakitAddonMcpServers -Label "dash-server") } catch { }
    }
    return $true
}

# Confirm-DashServerPip - make sure the venv can run `python -m pip`.
# dash-server installs each app's dependencies (including the built-in demo's)
# by shelling out to exactly that, and a bare uv venv has no pip - without
# this, every app build fails with "Dependency install failed before import
# smoke check". New venvs are created with --seed; this is the self-repair for
# venvs that predate the seed or were provided by the user.
# Twin of _dash_server_ensure_pip in dash-server.sh.
function Confirm-DashServerPip {
    param([Parameter(Mandatory)][string]$Uv)
    $python = Get-DashServerVenvPython
    if (-not (Test-Path $python)) { return $true }
    $code = Invoke-ExakitLogged $python "-m" "pip" "--version"
    if ($code -eq 0) { return $true }
    Info "Adding pip to the dash-server venv (app builds install their dependencies with it)"
    $code = Invoke-ExakitLogged $Uv "pip" "install" "--python" $python "pip"
    if ($code -ne 0) {
        return (Write-DashServerNotInstalled "pip could not be added to $script:DashServerVenv (dash-server app builds need it; see log)")
    }
    $code = Invoke-ExakitLogged $python "-m" "pip" "--version"
    if ($code -ne 0) {
        return (Write-DashServerNotInstalled "pip was installed into $script:DashServerVenv but python -m pip still does not run (see log)")
    }
    Ok "pip added to the dash-server venv"
    return $true
}

# Write-DashServerLauncher - generate ~\.local\bin\dash-server.cmd. The wrapper
# starts the venv's console script with the kit's Exasol profile bootstrapped
# from the environment (DASH_SERVER_EXASOL_*, read fresh at RUN time - the
# password never lands in the wrapper, only the path of the credential file).
# Every variable yields to one the user set. Twin of dash_server_write_launcher.
function Write-DashServerLauncher {
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $user = Get-ExakitManifestValue "components.mcp_server.connection.user"
    $pwfile = Get-ExakitManifestValue "components.mcp_server.connection.password_file"
    if (-not $user -or -not $pwfile) {
        # Dashboards read, they do not write: prefer the dedicated read-only
        # user (same posture as the MCP server); the runtime admin user is the
        # fallback for installs made before the read-only user existed.
        $user = Get-ExakitManifestValue "runtime.user"
        $pwfile = Get-ExakitManifestValue "runtime.password_file"
    }
    $instance = Join-Path $script:DashServerHome "instance"
    $exe = Join-Path $script:DashServerVenv "Scripts\dash-server.exe"

    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    $lines = @(
        "@echo off"
        # setlocal, AND THAT IS NOT BOILERPLATE. A .cmd invoked from an
        # interactive cmd.exe runs in THAT process, so every `set` here escapes
        # into the user's console and is inherited by everything they run
        # afterwards. Without it this wrapper left the database password in
        # EXA_PASSWORD, contradicting the note above that the password "never
        # lands in the wrapper" - true of the file, false of the session - and
        # defeating the ACL on the credential file one step downstream.
        # endlocal is implicit when the script exits.
        "setlocal"
        "rem dash-server launcher - generated by the Exasol Personal Local Starter Kit."
        "rem Starts dash-server from its kit-managed venv with the kit's local Exasol"
        "rem database bootstrapped as a connection profile (DASH_SERVER_EXASOL_*)."
        "rem Variables you set yourself take precedence. Regenerated by:"
        "rem   exakit update"
        "rem Already up? dash-server's consumption coordinator is single-process, so"
        "rem a second copy dies on a traceback that reads like a crash. It is not one."
        # A JUMP, NOT A PARENTHESISED BLOCK - and that is the whole bug this
        # shape exists to avoid.
        #
        # cmd parses a bracketed `if ( ... )` body by scanning for the closing
        # paren, and it does not care that the one it finds is inside an echo.
        # The message below ends in "(MCP: /mcp)", so the ")" in it closed the
        # block early: the first echo was swallowed, and the two lines meant to
        # be conditional - the State line and `exit /b 0` - ran UNCONDITIONALLY.
        # The launcher therefore exited 0 every single time without ever
        # starting the server, on a fresh install and on `exakit start` alike.
        # The only trace was a dash-server.log holding exactly one line, the
        # State line, which reads like the server started and said nothing.
        #
        # Escaping the parens would fix today's message and leave the trap set
        # for whoever edits it next. `goto` has no body to terminate, so no
        # punctuation in any of these lines can break the control flow again.
        # THE PORT IS NEVER BAKED IN. It used to be written into the probe
        # below AND into the bind further down, while the kit records its own
        # choice separately - two copies of one fact, which drift: a launcher
        # written when the port was 5102 kept probing and binding 5102 while
        # the kit passed 5100 and waited on it. Resolved here in the same order
        # the kit uses - the kit's record, then the plain default - so there is
        # nothing left to disagree with. Twin of the same block in
        # dash_server_write_launcher (dash-server.sh), where argv is read too.
        # RESOLVED IN THE SAME ORDER THE KIT USES, and the first of those
        # orders is the one this side used to skip entirely:
        #   1. --port on this command line  (how the kit and the boot entry call it)
        #   2. components.dash_server.port in the manifest
        #   3. 5100
        # The kit starts the launcher as `dash-server.cmd --host 127.0.0.1
        # --port <n>` and then waits on <n>. With argv unread, the wrapper's
        # own pre-flight probed whatever the manifest scan turned up instead -
        # so the "already running?" check and the kit could be looking at two
        # different ports, and the answer to "did it come up on 5100" was
        # decided by a port nobody had asked about. The shell twin
        # (_dash_server_write_launcher) has always read argv first; this is
        # that same walk in cmd.
        #
        # GOTOs, NOT PARENTHESISED IF-BLOCKS - same reason as the jump below:
        # a ")" anywhere in a bracketed body closes it early. `shift` does not
        # touch %*, so the whole command line still reaches the server.
        "set `"EXAKIT_DS_PORT=`""
        "set `"EXAKIT_DS_WANT=`""
        ":exakit_ds_argv"
        "if `"%~1`"==`"`" goto exakit_ds_argv_done"
        "if defined EXAKIT_DS_WANT goto exakit_ds_argv_take"
        "if /i `"%~1`"==`"--port`" goto exakit_ds_argv_want"
        "set `"EXAKIT_DS_ARG=%~1`""
        "if `"%EXAKIT_DS_ARG:~0,7%`"==`"--port=`" goto exakit_ds_argv_eq"
        "shift"
        "goto exakit_ds_argv"
        ":exakit_ds_argv_want"
        "set `"EXAKIT_DS_WANT=1`""
        "shift"
        "goto exakit_ds_argv"
        ":exakit_ds_argv_take"
        "set `"EXAKIT_DS_PORT=%~1`""
        "set `"EXAKIT_DS_WANT=`""
        "shift"
        "goto exakit_ds_argv"
        ":exakit_ds_argv_eq"
        "set `"EXAKIT_DS_PORT=%EXAKIT_DS_ARG:~7%`""
        "shift"
        "goto exakit_ds_argv"
        ":exakit_ds_argv_done"
        "if not defined EXAKIT_HOME set `"EXAKIT_DS_MANIFEST=%USERPROFILE%\.exasol-starter-kit\manifest.json`""
        "if defined EXAKIT_HOME set `"EXAKIT_DS_MANIFEST=%EXAKIT_HOME%\manifest.json`""
        # FIRST match, not last. `for /f ... do set` runs its body once per
        # matching line and the last one wins, so the moment the manifest grows
        # a second `"port"` key anywhere - the database's, say - the launcher
        # would start binding it. `head -1` is what the shell twin does; this
        # `if not defined` is head -1 in cmd.
        "if exist `"%EXAKIT_DS_MANIFEST%`" if not defined EXAKIT_DS_PORT for /f `"tokens=2 delims=:,`" %%P in ('findstr /r /c:`"\`"port\`"[ ]*:`" `"%EXAKIT_DS_MANIFEST%`"') do if not defined EXAKIT_DS_PORT set `"EXAKIT_DS_PORT=%%P`""
        "for /f `"tokens=* delims= `" %%Q in (`"%EXAKIT_DS_PORT%`") do set `"EXAKIT_DS_PORT=%%Q`""
        # Anything that is not all digits is not a port. A findstr that matched
        # the wrong line, or a --port someone typed wrong, would otherwise be
        # handed to the bind as-is. The shell twin's `case *[!0-9]*` in cmd:
        # the for only yields a token when a non-digit is present.
        "for /f `"delims=0123456789`" %%R in (`"%EXAKIT_DS_PORT%`") do set `"EXAKIT_DS_PORT=`""
        "if not defined EXAKIT_DS_PORT set `"EXAKIT_DS_PORT=5100`""
        "curl -s -o NUL -m 2 http://127.0.0.1:%EXAKIT_DS_PORT%/mcp >NUL 2>&1"
        "if errorlevel 1 goto exakit_dash_start"
        "echo dash-server is already running: http://127.0.0.1:%EXAKIT_DS_PORT% (MCP: /mcp)"
        "echo State: exakit status   Logs: exakit logs dash-server -f   Stop: exakit stop"
        "exit /b 0"
        ":exakit_dash_start"
        "if not defined DASH_SERVER_INSTANCE_PATH set `"DASH_SERVER_INSTANCE_PATH=$instance`""
    )
    if ($dsn -and $user -and $pwfile) {
        $lines += @(
            "if defined DASH_SERVER_EXASOL_DSN goto run"
            "if not defined EXA_PASSWORD if exist `"$pwfile`" set /p EXA_PASSWORD=<`"$pwfile`""
            "if not defined EXA_PASSWORD goto run"
            "set `"DASH_SERVER_EXASOL_PROFILE_NAME=$($script:DashServerProfile)`""
            "set `"DASH_SERVER_EXASOL_DSN=$dsn`""
            "set `"DASH_SERVER_EXASOL_USER=$user`""
            "set `"DASH_SERVER_EXASOL_SECRET_ENV_VAR=EXA_PASSWORD`""
            "rem The kit's local runtime speaks TLS with a self-signed certificate."
            "if not defined DASH_SERVER_EXASOL_TLS_VERIFY set `"DASH_SERVER_EXASOL_TLS_VERIFY=false`""
        )
    } else {
        Warn2 "No database connection is recorded yet - dash-server starts without a bootstrapped Exasol profile until the kit install completes."
    }
    $lines += @(
        ":run"
        # Bind where the kit says, not where dash-server defaults. Without
        # these the pre-flight check above verdicts one port and the server
        # binds its own built-in default, so an install that stepped up past a
        # busy 5100 starts on the busy port - or, if the upstream default host
        # is not loopback, exposes an unauthenticated control plane on the LAN.
        # Setdefaults, like DASH_SERVER_INSTANCE_PATH above: a user who set
        # their own still wins. Twin of the same block in
        # dash_server_write_launcher.
        "if not defined DASH_SERVER_HOST set `"DASH_SERVER_HOST=127.0.0.1`""
        "if not defined DASH_SERVER_PORT set `"DASH_SERVER_PORT=%EXAKIT_DS_PORT%`""
        "`"$exe`" %*"
    )
    try {
        # In the code page cmd.exe reads a batch file in, not ASCII. `-Encoding Ascii`
    # turns every byte above 0x7F into a literal "?", so a profile path like
    # C:\Users\Wojcik with an accent silently produced a launcher pointing at a
    # directory that does not exist - while the install printed "launcher
    # written". Same approach as Set-ExakitCmdShim, including its fallback: a
    # machine whose OEM code page cannot be resolved keeps the old behaviour
    # rather than losing the file.
    $oemEnc = Get-ExakitOemEncoding
    if ($oemEnc) { [System.IO.File]::WriteAllText((Get-DashServerLauncherPath), ($lines -join "`r`n"), $oemEnc) }
    else { Set-Content -Path (Get-DashServerLauncherPath) -Value ($lines -join "`r`n") -Encoding Ascii }
    } catch {
        return (Write-DashServerNotInstalled "could not write the launcher at $(Get-DashServerLauncherPath)")
    }
    Ok "dash-server launcher written: $(Get-DashServerLauncherPath)"
    return $true
}

# Test-DashServer - prove the package imports, then start the server briefly
# and check the MCP control plane answers over HTTP. Both halves are soft: a
# failed live check records validated=false and warns rather than failing the
# marketplace install. Twin of dash_server_validate.
# Decide which port THIS install uses, before a launcher or a Startup entry
# bakes one in. A port the user named is honoured or refused - silently moving
# an explicit choice would be worse than saying it is taken. An unnamed one
# steps up past a collision. Twin of _dash_server_settle_port.
function Confirm-DashServerPort {
    $foreign = Get-DashServerPortForeignDescription
    if (-not $foreign) { return $true }
    if ($env:EXAKIT_DASH_SERVER_PORT) {
        [void](Write-DashServerNotInstalled "port $($script:DashServerPort) is held by another process ($foreign) - pick a free one with EXAKIT_DASH_SERVER_PORT=<port>")
        return $false
    }
    $taken = $script:DashServerPort
    for ($i = 1; $i -le 20; $i++) {
        $script:DashServerPort = [string]([int]$taken + $i)
        if (-not (Get-DashServerPortForeignDescription)) {
            Warn2 "Port $taken is held by another process ($foreign)."
            Info "dash-server will use port $($script:DashServerPort) instead (recorded, so every command agrees)."
            return $true
        }
    }
    $script:DashServerPort = $taken
    [void](Write-DashServerNotInstalled "no free port found between $taken and $([int]$taken + 20) - free one, or name one with EXAKIT_DASH_SERVER_PORT=<port>")
    return $false
}

function Test-DashServer {
    Resolve-DashServerPort
    $python = Get-DashServerVenvPython
    # Nothing to validate when the install did not get far enough: it is
    # soft-fail by design and has already explained itself.
    if (-not (Test-Path $python)) { return }
    $code = Invoke-ExakitLogged $python "-c" "import dash_server"
    if ($code -ne 0) {
        Warn2 "dash-server is installed but cannot be imported from $script:DashServerVenv (see log). Recorded validated=false; retry with: exakit update"
        Set-ExakitManifestValue "components.dash_server.validated" $false
        return
    }

    $foreign = Get-DashServerPortForeignDescription
    if ($foreign) {
        Warn2 "Port $($script:DashServerPort) is held by another process ($foreign) - dash-server was not validated."
        Info "Move it with: EXAKIT_DASH_SERVER_PORT=<port> exakit update"
        Set-ExakitManifestValue "components.dash_server.validated" $false
        return
    }
    Info "Validating dash-server (MCP control plane on port $($script:DashServerPort))"
    # Something already answering on the port IS a running dash-server as far
    # as this check can tell; starting a second instance would fail on the bind.
    if (Test-DashServerHttpAnswers) {
        Ok "dash-server control plane answers on port $($script:DashServerPort)"
        # An already-running server can predate this very install (autostart
        # brings one up early), so the restored package data never reached it:
        # its pages 500 on templates that ARE on disk. On OUR OWN instance one
        # restart is the repair; a foreign holder is left alone as always.
        # Twin of the same branch in dash_server_validate.
        if (-not (Test-DashServerUiAnswers) -and (Test-DashServerPortIsOurs)) {
            Info "The running dash-server predates this install - restarting it to pick up the restored files"
            Stop-DashServer | Out-Null
            Start-DashServer | Out-Null
        }
        Invoke-DashServerUiCheck
        Set-ExakitManifestValue "components.dash_server.validated" $true
        Write-DashServerUsagePanel
        return
    }

    $proc = $null
    # ITS OWN FILE, and redirected at all. This probe used to start the server
    # with no redirection whatsoever and then tell the reader to "see log" - a
    # log this attempt had never written a byte to. Separate from
    # dash-server.log so it cannot collide with a server that is still holding
    # that handle, and so the reason below is this attempt's.
    $probeLog = Join-Path $script:LogDir "dash-server-validate.log"
    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    try {
        $proc = Start-Process -FilePath (Get-DashServerLauncherPath) `
            -ArgumentList @("--host", "127.0.0.1", "--port", $script:DashServerPort) `
            -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $probeLog -RedirectStandardError "$probeLog.err"
    } catch {
        Warn2 "dash-server could not be started for validation (see log). Recorded validated=false; retry with: exakit update"
        Set-ExakitManifestValue "components.dash_server.validated" $false
        return
    }
    $answered = $false
    $waited = 0
    while ($waited -lt 60) {
        if (Test-DashServerHttpAnswers) { $answered = $true; break }
        if ($proc.HasExited) { break }
        Start-Sleep -Seconds 2
        $waited += 2
    }
    # The browser page is probed HERE, while the probe server is still up:
    # asking a dead port whether it renders reported every fresh install as
    # "the dashboards page does not render". Twin of the same ordering fix in
    # dash_server_validate.
    $uiOk = $false
    if ($answered) { $uiOk = Test-DashServerUiAnswers }

    # The launcher is a cmd wrapper: stop the whole tree, or the python server
    # it spawned keeps the port. Bounded and best-effort.
    try {
        & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
    } catch { }

    if ($answered) {
        Ok "dash-server control plane answers on port $($script:DashServerPort)"
        Write-DashServerUiResult $uiOk
        Set-ExakitManifestValue "components.dash_server.validated" $true
        Write-DashServerUsagePanel
    } else {
        $reason = Get-DashServerFailureReason $probeLog
        if ($reason) {
            Warn2 "dash-server did not answer on port $($script:DashServerPort) - $reason. Recorded validated=false; retry with: exakit update"
        } else {
            Warn2 "dash-server did not answer on port $($script:DashServerPort) within $waited s. Recorded validated=false; retry with: exakit update"
        }
        Set-ExakitManifestValue "components.dash_server.validated" $false
    }
}

# Get-DashServerFailureReason - the line from a start log that says WHY the
# server is not answering, ready to put on screen.
#
# "see the log" IS NOT A DIAGNOSIS. A failed start printed a port and a file
# path and stopped there, so the only way to learn what happened was to open a
# file in the middle of an install - and the validation attempt did not even
# redirect its output, so for that half the named file held nothing from the
# attempt being reported. The reason is one line; it belongs on screen.
# Twin of _dash_server_failure_reason.
function Get-DashServerFailureReason {
    param([string]$Path)
    $paths = @()
    if ($Path) { $paths += $Path; $paths += "$Path.err" }
    $lines = @()
    foreach ($candidate in $paths) {
        if (-not (Test-Path $candidate)) { continue }
        try {
            $lines += @(Get-Content -Path $candidate -Tail 40 -ErrorAction Stop |
                        Where-Object { "$_".Trim() })
        } catch { }
    }
    if ($lines.Count -eq 0) { return "" }
    # A traceback says what went wrong on its LAST line, not its first, and the
    # frames between are noise here. Prefer the deepest error line; fall back to
    # whatever the server said last.
    $reason = "$($lines[-1])".Trim()
    foreach ($line in $lines) {
        if ("$line" -match '(Error|Exception|error:|ERROR|Errno|refused|denied|in use|already running)') {
            $reason = "$line".Trim()
        }
    }
    $reason = ($reason -replace '\s+', ' ')
    if ($reason.Length -gt 150) { $reason = $reason.Substring(0, 147) + "..." }
    return $reason
}

# One bounded probe of the control plane. Any HTTP status counts: /mcp
# answering 4xx to a bare GET still proves the server is up.
# Restore-DashServerPackageData - put back data files the release ships in its
# source tree but does NOT declare as package data, so pip never installs them.
# UPSTREAM BUG (dash-server 0.1.0): the templates under src/dash_server are
# missing from every installed copy, so the browser UI answers 500 while the
# MCP control plane looks healthy. Nothing is overwritten, so a fixed release
# makes this a no-op. Twin of _dash_server_restore_package_data.
function Restore-DashServerPackageData {
    $python = Get-DashServerVenvPython
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $site = & $python -c 'import dash_server, os; print(os.path.dirname(dash_server.__file__))' 2>$null
    } catch {
        $site = $null
    } finally { $ErrorActionPreference = $prevEap }
    if (-not $site -or -not (Test-Path $site)) { return }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("exakit-ds-data-" + [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $tarball = Join-Path $tmp "src.tar.gz"
        try {
            # Animated: this fetch runs after "Installing dash-server" with
            # nothing else on screen. Twin of fetch_quiet on the shell side.
            [void](Invoke-ExakitWithSpinner -Label "Fetching the dash-server release files" -Body {
                Invoke-WebRequest -Uri (Get-DashServerReleaseUrl -Version $script:DashServerVersion) `
                    -OutFile $tarball -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            })
        } catch { return }
        # tar, resolved deliberately rather than taken off PATH. Two hazards
        # here, and they stack:
        #
        # 1. PATH ORDER. On a machine with Git for Windows, its GNU tar
        #    (Git\usr\bin\tar.exe) comes BEFORE Windows' own bsdtar
        #    (System32\tar.exe). GNU tar reads a "C:\..." argument as host:path
        #    rsh syntax and dies with
        #    "tar (child): Cannot connect to C: resolve failed".
        #    bsdtar understands drive letters, so it is asked for by name.
        #
        # 2. $ErrorActionPreference is Stop module-wide, and a native command's
        #    FIRST stderr write becomes a TERMINATING error under it - which
        #    2>$null does not prevent. So this best-effort repair did not "fail
        #    and return" as written: it threw, and the caller reported the whole
        #    dash-server install as failed, over a data-file top-up that is
        #    allowed to be skipped. Same fix as Invoke-ExakitLogged uses.
        $tarExe = "tar"
        if ($env:SystemRoot) {
            $systemTar = Join-Path $env:SystemRoot "System32\tar.exe"
            if (Test-Path $systemTar) { $tarExe = $systemTar }
        }
        $tarCode = 1
        $prevTarEAP = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $tarExe -xzf $tarball -C $tmp 2>$null
            $tarCode = $LASTEXITCODE
        } catch {
            $tarCode = 1
        } finally {
            $ErrorActionPreference = $prevTarEAP
        }
        if ($tarCode -ne 0) { return }
        $src = Join-Path $tmp "dash-server-$($script:DashServerVersion)\src\dash_server"
        if (-not (Test-Path $src)) { return }

        $restored = 0
        Get-ChildItem -Path $src -Recurse -File | Where-Object { $_.Extension -ne ".py" } | ForEach-Object {
            $rel = $_.FullName.Substring($src.Length).TrimStart("\", "/")
            $dest = Join-Path $site $rel
            if (-not (Test-Path $dest)) {
                New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
                Copy-Item $_.FullName $dest -ErrorAction SilentlyContinue
                if (Test-Path $dest) { $restored++ }
            }
        }
        if ($restored -gt 0) {
            Info "Restored $restored data file(s) the release does not declare as package data (upstream packaging gap; the browser UI needs them)"
        }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

# Test-DashServerUiAnswers - the page a HUMAN opens, checked separately from
# /mcp: the control plane can be healthy while the browser UI is broken.
# Twin of _dash_server_ui_answers.
function Test-DashServerUiAnswers {
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$($script:DashServerPort)/" `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400)
    } catch {
        return $false
    }
}

# Invoke-DashServerUiCheck - report the browser page separately. A broken UI
# does not fail the install, but it must never pass silently.
# Twin of _dash_server_check_ui.
function Invoke-DashServerUiCheck {
    Write-DashServerUiResult (Test-DashServerUiAnswers)
}

# Write-DashServerUiResult <bool> - say what the UI probe found and record it.
# Separate from the probe so the fresh-start path can probe while its server is
# alive and report after killing it. Twin of _dash_server_report_ui.
function Write-DashServerUiResult {
    param([bool]$Ok)
    if ($Ok) {
        Ok "Dashboards page answers: http://127.0.0.1:$($script:DashServerPort)"
        Set-ExakitManifestValue "components.dash_server.ui_validated" $true
        return
    }
    Warn2 "The control plane is up, but the dashboards page at http://127.0.0.1:$($script:DashServerPort) does not render (see: exakit logs dash-server)."
    Warn2 "Agents can still drive it over MCP. Retry the repair with: exakit update"
    Set-ExakitManifestValue "components.dash_server.ui_validated" $false
}

function Test-DashServerHttpAnswers {
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$($script:DashServerPort)/mcp" `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return ($null -ne $response)
    } catch [System.Net.WebException] {
        # A 4xx/3xx reply still proves a listener; only a connect failure
        # (no response object) means nothing answered.
        return ($null -ne $_.Exception.Response)
    } catch {
        return $false
    }
}

# The panel is the add-on's reference card, and a marketplace install is not
# where a reference card belongs: three of them in a row is thirty lines a reader
# has to scroll past to reach "installed". Under ExakitQuietDetail the rows go to
# the logfile and the one fact worth keeping reaches the result line through
# SummaryFn; `exakit help <id>` has all of it, and more, any time.
# Twin of _dash_server_print_usage in dash-server.sh.
function Write-DashServerUsagePanel {
    if ($script:ExakitQuietDetail) {
        Write-ExakitLog "DATA" "dash-server: http://127.0.0.1:$($script:DashServerPort) (mcp: /mcp)"
        return
    }
    Start-ExakitPanel "dash-server"
    Write-ExakitPanelLine "Start it        dash-server"
    Write-ExakitPanelLine "Dashboards      http://127.0.0.1:$($script:DashServerPort)"
    Write-ExakitPanelLine "MCP endpoint    http://127.0.0.1:$($script:DashServerPort)/mcp"
    Write-ExakitPanelLine "Update          exakit update"
    Complete-ExakitPanel
}

# Get-DashServerUrl - the one address everything about this add-on hangs off.
# Optional registry hook (UrlFn); twin of dash_server_url. `status --json`
# surfaces it under `urls`, so an agent finally has a JSON key for the URL
# instead of parsing the human screen or guessing the port.
function Get-DashServerUrl {
    Resolve-DashServerPort
    return "http://127.0.0.1:$($script:DashServerPort)"
}

# Get-DashServerSummary - the one fact worth a place on the result line.
# Optional registry hook (SummaryFn); twin of dash_server_summary.
function Get-DashServerSummary {
    Resolve-DashServerPort
    # 33 characters at a four-digit port. The cell truncates anything longer,
    # and its room is 33 in the PLAIN palette, whose tick is the four-character
    # "[ok]" rather than a one-character glyph.
    return "dashboards: http://127.0.0.1:$($script:DashServerPort)"
}

# ---------------------------------------------------------------------------
# Service lifecycle (twin of the dash_server_start/_stop/_status set)
# ---------------------------------------------------------------------------
$script:DashServerPidFile = Join-Path $script:DashServerHome "dash-server.pid"
$script:DashServerLog = Join-Path $script:LogDir "dash-server.log"

# What `exakit logs dash-server` shows. Twin of dash_server_log_path.
function Get-DashServerLogPath {
    return $script:DashServerLog
}

# --- who holds the port -----------------------------------------------------
# "Something answers on 5100" is NOT "dash-server is running": any web server
# there would pass an HTTP probe and the kit would report a healthy add-on it
# never started. Ownership is matched on the venv path, which is unique to this
# install. Twins of the _dash_server_port_* set in dash-server.sh.
function Get-DashServerPortPids {
    try {
        return @(Get-NetTCPConnection -LocalPort ([int]$script:DashServerPort) -State Listen -ErrorAction Stop |
                 Select-Object -ExpandProperty OwningProcess -Unique)
    } catch {
        return @()
    }
}

function Test-DashServerPortIsOurs {
    foreach ($procId in (Get-DashServerPortPids)) {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop).CommandLine
            if ($cmd -and $cmd.Contains($script:DashServerVenv)) { return $true }
        } catch { }
    }
    return $false
}

# "pid N (name)" when someone ELSE holds the port; $null when free or ours.
function Get-DashServerPortForeignDescription {
    $procIds = Get-DashServerPortPids
    if ($procIds.Count -eq 0) { return $null }
    if (Test-DashServerPortIsOurs) { return $null }
    foreach ($procId in $procIds) {
        $name = try { (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { "unknown" }
        return "pid $procId ($name)"
    }
    return $null
}

# Is OUR server up? Get-NetTCPConnection answers precisely; without it fall
# back to the HTTP probe, which is the best a session without it allows.
function Test-DashServerRunning {
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        return (Test-DashServerPortIsOurs)
    }
    return (Test-DashServerHttpAnswers)
}

# running | stopped | not installed. The HTTP probe is the truth: the process
# may have been started by the Startup entry, by the user, or by exakit.
function Get-DashServerStatus {
    Resolve-DashServerPort
    if (-not (Test-Path (Get-DashServerLauncherPath))) { return "not installed" }
    if (Test-DashServerRunning) { return "running" }
    $foreign = Get-DashServerPortForeignDescription
    if ($foreign) { return "stopped (port $($script:DashServerPort) is held by another process: $foreign)" }
    return "stopped"
}

# The kit-managed dash-server processes: anything running out of this venv,
# which covers a Startup-started copy whose pid the kit never recorded.
function Get-DashServerProcessIds {
    $ids = @()
    if (Test-Path $script:DashServerPidFile) {
        $recorded = (Get-Content $script:DashServerPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($recorded -match '^\d+$' -and (Get-Process -Id ([int]$recorded) -ErrorAction SilentlyContinue)) {
            $ids += [int]$recorded
        }
    }
    try {
        foreach ($proc in (Get-CimInstance Win32_Process -ErrorAction Stop |
                           Where-Object { $_.CommandLine -and $_.CommandLine.Contains($script:DashServerVenv) })) {
            if ($ids -notcontains [int]$proc.ProcessId) { $ids += [int]$proc.ProcessId }
        }
    } catch { }
    return $ids
}

# Bring it up in the background and wait until the control plane answers.
# Idempotent: an already-running server is reported, not duplicated.
function Start-DashServer {
    Resolve-DashServerPort
    if (-not (Test-Path (Get-DashServerLauncherPath))) {
        Warn2 "dash-server is not installed - add it with: exakit marketplace"
        return $false
    }
    if (Test-DashServerRunning) {
        Ok "dash-server is already running (http://127.0.0.1:$($script:DashServerPort))"
        return $true
    }
    $foreign = Get-DashServerPortForeignDescription
    if ($foreign) {
        Warn2 "Port $($script:DashServerPort) is held by another process ($foreign), so dash-server cannot bind it."
        Info "Move dash-server to a free port with: EXAKIT_DASH_SERVER_PORT=<port> exakit update"
        return $false
    }
    New-Item -ItemType Directory -Force -Path $script:DashServerHome, $script:LogDir | Out-Null
    Info "Starting dash-server on port $($script:DashServerPort)"
    try {
        $proc = Start-Process -FilePath (Get-DashServerLauncherPath) `
            -ArgumentList @("--host", "127.0.0.1", "--port", $script:DashServerPort) `
            -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $script:DashServerLog -RedirectStandardError "$($script:DashServerLog).err"
    } catch {
        Warn2 "dash-server could not be started: $_"
        return $false
    }
    Set-Content -Path $script:DashServerPidFile -Value $proc.Id -Encoding Ascii
    $waited = 0
    while ($waited -lt 60) {
        if (Test-DashServerHttpAnswers) {
            Ok "dash-server is running: http://127.0.0.1:$($script:DashServerPort) (MCP: /mcp)"
            return $true
        }
        if ($proc.HasExited) { break }
        Start-Sleep -Seconds 2
        $waited += 2
    }
    $reason = Get-DashServerFailureReason $script:DashServerLog
    if ($reason) {
        Warn2 "dash-server did not answer on port $($script:DashServerPort) - $reason"
    } else {
        Warn2 "dash-server did not answer on port $($script:DashServerPort) within $waited s - see $($script:DashServerLog)"
    }
    return $false
}

# Stop every kit-managed dash-server process, bounded.
function Stop-DashServer {
    Resolve-DashServerPort
    $ids = Get-DashServerProcessIds
    if ($ids.Count -eq 0 -and -not (Test-DashServerHttpAnswers)) {
        Ok "dash-server is already stopped"
        Remove-Item -Force -ErrorAction SilentlyContinue $script:DashServerPidFile
        return $true
    }
    Info "Stopping dash-server"
    foreach ($id in $ids) {
        try { & taskkill.exe /PID $id /T /F 2>$null | Out-Null } catch { }
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $script:DashServerPidFile
    if (Test-DashServerHttpAnswers) {
        Warn2 "Something is still answering on port $($script:DashServerPort) (a dash-server the kit did not start?)"
        return $false
    }
    Ok "dash-server stopped"
    return $true
}

# What the boot entry runs. The launcher already bootstraps the database
# profile, so this is simply it.
function Get-DashServerAutostartCommand {
    Resolve-DashServerPort
    return ('"{0}" --host 127.0.0.1 --port {1}' -f (Get-DashServerLauncherPath), $script:DashServerPort)
}

# Remove what the dash-server install put on this machine: the venv, the
# launcher, the pid file and the manifest record. -DryRun only narrates the
# plan. Best-effort and idempotent. Twin of dash_server_uninstall.
#
# THE INSTANCE IS KEPT: it is the user's dashboards (GitOps repo, apps,
# secrets), and a reinstall adopts it again. See dash_server_uninstall.
function Uninstall-DashServer {
    param([switch]$DryRun)
    Resolve-DashServerPort
    # A running server holds its port and would outlive its own files.
    if (-not $DryRun) { [void](Stop-DashServer) }
    $instance = Join-Path $script:DashServerHome "instance"
    foreach ($path in @($script:DashServerVenv, $script:DashServerPidFile, (Get-DashServerLauncherPath))) {
        if (-not ($path -and (Test-Path $path))) { continue }
        if ($DryRun) { Info "  will remove: $path" }
        else {
            Info "Removing $path"
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $path
        }
    }
    if ((Test-Path -LiteralPath $instance) -and $script:ExakitUninstallFull) {
        # A full kit uninstall removes the kit home next, and the instance with it.
        Info "  your dashboards in $instance go with the kit home"
    } elseif (Test-Path -LiteralPath $instance) {
        Info "  keeping your dashboards: $instance (reinstalling the add-on picks them up again; delete the folder yourself if you no longer want them)"
    } elseif (-not $DryRun -and (Test-Path -LiteralPath $script:DashServerHome)) {
        if (-not (Get-ChildItem -LiteralPath $script:DashServerHome -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            Remove-Item -Force -ErrorAction SilentlyContinue $script:DashServerHome
        }
    }
    if (-not $DryRun) {
        # Before the manifest block goes: an entry pointing at a port nothing
        # answers on is worse than no entry at all, because a client reports it
        # as a broken server every time it starts.
        if (Get-Command Unregister-ExakitMcpServerEntry -ErrorAction SilentlyContinue) {
            try { [void](Unregister-ExakitMcpServerEntry -ServerName "dash-server" -Label "dash-server") } catch { }
        }
        Remove-ExakitManifestValue "components.dash_server"
        Remove-ExakitManifestValue "desired.dash_server"
        OkStep "dash-server removed - reinstall any time with: exakit marketplace"
    }
    return $true
}

# Update-DashServer - install the advertised version into the venv. Doubles as
# the repair command after a failed marketplace install. Asked for explicitly,
# so a failure here IS a failure. Twin of dash_server_update.
function Update-DashServer {
    Resolve-DashServerPort
    $available = Get-ExakitComponentAvailable "dash-server"
    if (-not $available) { Fail "Could not resolve the advertised dash-server version." }
    $current = Get-DashServerInstalledVersion
    if ($current -and $current -eq $available) {
        # Same version can still need repair: regenerate the launcher so a
        # DSN/credential change since the install is picked up.
        [void](Write-DashServerLauncher)
        Ok "dash-server is already current ($current)"
        return
    }
    if ($current) { Info "Updating dash-server $current -> $available" }
    else { Info "Installing dash-server $available" }
    $script:DashServerVersion = $available
    $env:EXAKIT_FORCE_COMPONENT_INSTALL = "1"
    try {
        if (-not (Install-DashServer)) {
            Fail "dash-server could not be installed - see the warning above and the log."
        }
    } finally {
        Remove-Item Env:EXAKIT_FORCE_COMPONENT_INSTALL -ErrorAction SilentlyContinue
    }
    Test-DashServer
    Set-ExakitManifestValue "desired.dash_server" $script:DashServerVersion
    Ok "dash-server updated; database data was not changed"
}
