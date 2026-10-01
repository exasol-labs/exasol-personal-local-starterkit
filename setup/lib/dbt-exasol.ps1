# dbt-exasol.ps1 - dbt-exasol (the dbt adapter for Exasol): managed install +
# validation.
#
# Windows counterpart of dbt-exasol.sh. A MARKETPLACE ADD-ON: never installed
# by the setup scripts. The user picks it from `exakit marketplace`; once
# installed it joins `exakit update` like every other component.
#
# dbt-exasol facts:
#   - The dbt adapter for Exasol (github.com/exasol/dbt-exasol), published to
#     PyPI as dbt-exasol. It pulls dbt-core in with it, so installing this
#     add-on is what puts dbt on the machine.
#   - A CLI, not a service: nothing listens, nothing starts at boot. That is
#     why this module defines no status/start/stop/autostart/log functions -
#     the marketplace registry entry simply names none.
#   - PyPI is both the install source and the version authority, which is why
#     versions.json carries `package` and NO `repo` for it: the generic
#     upstream lookup prefers `repo`, and the GitHub tags are v-prefixed
#     (v1.12.1) while the PyPI versions are not (1.12.1).
#   - Nothing to checksum. A PyPI version is immutable - it can never be
#     re-uploaded - so dbt-exasol==<version> IS the pin, in the way a digest
#     is the pin for the add-ons that install a GitHub release asset.
#   - Requires Python >=3.11,<3.15; the kit's managed interpreter (3.12) sits
#     inside that range.
#
#   - venv:     ~\.exasol-starter-kit\dbt-exasol-venv
#   - profile:  ~\.exasol-starter-kit\dbt\profiles.yml  (NEVER ~\.dbt)
#   - launcher: ~\.local\bin\dbt-exasol.cmd
#
# Requires exakit-common.ps1 dot-sourced first. Safe to re-run: an existing
# venv with the desired version installed is kept as-is.

# The add-on's version constants live here, next to the code that uses them -
# the marketplace registry entry in exakit-common.ps1 names them, and the
# versions-bump workflow keeps the fallback in lockstep with versions.json
# (COUPLED table).
$script:DbtExasolPackage = "dbt-exasol"
$script:DbtExasolVersionFallback = if ($env:EXAKIT_DBT_EXASOL_VERSION_FALLBACK) { $env:EXAKIT_DBT_EXASOL_VERSION_FALLBACK } else { "1.12.1" }
$script:DbtExasolVersion = if ($env:EXAKIT_DBT_EXASOL_VERSION) { $env:EXAKIT_DBT_EXASOL_VERSION } else { "" }
$script:DbtExasolVenv = if ($env:EXAKIT_DBT_EXASOL_VENV) { $env:EXAKIT_DBT_EXASOL_VENV } else { Join-Path $script:ExakitHome "dbt-exasol-venv" }
$script:DbtExasolHome = if ($env:EXAKIT_DBT_EXASOL_HOME) { $env:EXAKIT_DBT_EXASOL_HOME } else { Join-Path $script:ExakitHome "dbt" }
$script:DbtExasolProfile = if ($env:EXAKIT_DBT_EXASOL_PROFILE) { $env:EXAKIT_DBT_EXASOL_PROFILE } else { "exasol_starter_kit" }
$script:DbtExasolSchema = if ($env:EXAKIT_DBT_EXASOL_SCHEMA) { $env:EXAKIT_DBT_EXASOL_SCHEMA } else { "DBT" }

function Get-DbtExasolVenvPython {
    return (Join-Path $script:DbtExasolVenv "Scripts\python.exe")
}

# The dbt console script inside the kit's venv. NOT the launcher: this one has
# no credentials and no profiles directory bootstrapped, which is exactly what
# the validation probe wants (it supplies both itself).
function Get-DbtExasolVenvDbt {
    return (Join-Path $script:DbtExasolVenv "Scripts\dbt.exe")
}

function Get-DbtExasolLauncherPath {
    return (Join-Path $script:BinDir "dbt-exasol.cmd")
}

function Get-DbtExasolProfilesPath {
    return (Join-Path $script:DbtExasolHome "profiles.yml")
}

# What the VENV alone says, with no opinion on whether the add-on is usable
# yet. The installer asks this immediately after pip, before the profile and
# launcher exist. Twin of dbt_exasol_package_version.
function Get-DbtExasolPackageVersion {
    $python = Get-DbtExasolVenvPython
    if (-not (Test-Path $python)) { return $null }
    # A venv whose adapter is broken prints a traceback to stderr, and under
    # $ErrorActionPreference = "Stop" that stderr terminates the run before
    # $LASTEXITCODE can be read - so this probe would crash `exakit version`
    # instead of answering "not installed".
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $version = & $python -c "from importlib.metadata import version; print(version('dbt-exasol'))" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($version | Out-String -Width 4096).Trim()
    } catch {
        return $null
    } finally { $ErrorActionPreference = $prevEap }
}

# The manifest RECORD as well as the venv. The record is written at the END of
# a successful install, so an install that died earlier leaves a venv and
# nothing else and no longer reports a version for something no command can
# run. Twin of dbt_exasol_installed_version.
function Get-DbtExasolInstalledVersion {
    if (-not (Get-ExakitManifestValue "components.dbt_exasol.version")) { return $null }
    return (Get-DbtExasolPackageVersion)
}

# Write-DbtExasolNotInstalled <reason> - report a soft failure and return
# $false. Marketplace add-ons follow the pyexasol contract: nothing here may
# end the caller's run. Twin of _dbt_exasol_not_installed.
function Write-DbtExasolNotInstalled {
    param([Parameter(Mandatory)][string]$Reason)
    Warn2 "dbt-exasol was not installed: $Reason"
    Warn2 "Everything else in the kit is unaffected. Retry with: exakit update"
    Set-ExakitFailureReason $Reason
    Set-ExakitManifestValue "components.dbt_exasol.validated" $false
    return $false
}

# A dbt the user installed themselves counts as "already on this machine" only
# when it carries the EXASOL adapter. dbt-snowflake or dbt-postgres on PATH is
# a different tool that merely shares a command name, and treating it as
# present would hide the marketplace row and leave the user no way to install
# the Exasol adapter at all. Twin of dbt_exasol_system_present.
function Test-DbtExasolSystemPresent {
    $cmd = Get-Command dbt -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and ($cmd.Source -notlike (Join-Path $script:ExakitHome "*"))) {
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $out = & $cmd.Source --version 2>&1 | Out-String -Width 4096
            if ($out -match "exasol") { return $true }
        } catch {
        } finally { $ErrorActionPreference = $prevEap }
    }
    # Only the ambient interpreter, never the kit's own venv: importing it
    # there is a KIT install, which is a different thing entirely.
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python -or -not $python.Source) { return $false }
    if ($python.Source -like (Join-Path $script:ExakitHome "*")) { return $false }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $python.Source -c "import dbt.adapters.exasol" 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally { $ErrorActionPreference = $prevEap }
}

# "user<TAB>password file path" for the generated profile. The RUNTIME ADMIN
# user, deliberately not the read-only mcp_readonly user that dash-server
# reuses: dbt's whole job is to CREATE tables and views, so a read-only grant
# would turn every `dbt run` into a permissions error. Twin of
# _dbt_exasol_credentials.
function Get-DbtExasolCredentials {
    return [pscustomobject]@{
        User         = Get-ExakitManifestValue "runtime.user"
        PasswordFile = Get-ExakitManifestValue "runtime.password_file"
    }
}

# Write-DbtExasolProfile - generate ~\.exasol-starter-kit\dbt\profiles.yml.
#
# A KIT-OWNED directory, never ~\.dbt\profiles.yml. That file belongs to the
# user and routinely holds their other warehouses; merging a block into YAML
# somebody else maintains is the destructive edit this kit avoids everywhere
# else. The launcher points dbt here with DBT_PROFILES_DIR instead, as a
# setdefault, so a user who sets their own still wins.
#
# The password is NOT in this file: it names an environment variable that the
# launcher fills from the credential file at run time. The DBT_ENV_SECRET_
# prefix is dbt's own convention for values it scrubs from its logs and
# artifacts. Twin of dbt_exasol_write_profile.
function Write-DbtExasolProfile {
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $creds = Get-DbtExasolCredentials

    try {
        New-Item -ItemType Directory -Force -Path $script:DbtExasolHome | Out-Null
    } catch {
        return (Write-DbtExasolNotInstalled "could not create $script:DbtExasolHome for the dbt profile")
    }
    $lines = @(
        "# profiles.yml - generated by the Exasol Personal Local Starter Kit."
        "#"
        "# Regenerated by ``exakit update dbt-exasol``, so edits here do not survive."
        "# Your own ~\.dbt\profiles.yml is never read or written by the kit; the"
        "# dbt-exasol launcher points dbt at THIS directory with DBT_PROFILES_DIR,"
        "# and setting your own DBT_PROFILES_DIR overrides that."
        "#"
        "# The password is not stored here. The launcher reads it from the kit's"
        "# credential file at run time into DBT_ENV_SECRET_EXASOL_PASSWORD, a name"
        "# dbt scrubs from its own logs and artifacts."
        "$($script:DbtExasolProfile):"
        "  target: dev"
        "  outputs:"
        "    dev:"
        "      type: exasol"
        "      threads: 1"
        "      dsn: $dsn"
        "      user: $($creds.User)"
        "      password: `"{{ env_var('DBT_ENV_SECRET_EXASOL_PASSWORD') }}`""
        "      # Required by dbt-core as a profile field; Exasol has no"
        "      # multi-database concept, so the value is not used for anything."
        "      dbname: DB"
        "      schema: $($script:DbtExasolSchema)"
        "      encryption: true"
        "      # The kit's local runtime speaks TLS with a self-signed certificate."
        "      validate_server_certificate: false"
    )
    try {
        # UTF-8 without a BOM: this is YAML read by dbt, not a batch file read by
        # cmd.exe, and `-Encoding Ascii` replaced any non-ASCII character in the
        # baked credential path with "?" - producing a profile that points
        # nowhere on a profile name carrying an accent. PS 5.1's `utf8` writes a
        # BOM, which PyYAML chokes on, so the encoding is constructed explicitly.
        [System.IO.File]::WriteAllText((Get-DbtExasolProfilesPath), ($lines -join "`r`n"),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        return (Write-DbtExasolNotInstalled "could not write the dbt profile at $(Get-DbtExasolProfilesPath)")
    }
    # No secret in it, but it names the admin user, so it gets the same
    # owner-only treatment the kit gives its other generated state.
    if (Get-Command Protect-ExakitFile -ErrorAction SilentlyContinue) {
        try { [void](Protect-ExakitFile (Get-DbtExasolProfilesPath)) } catch { }
    }
    if (-not $dsn) {
        Warn2 "No database DSN is recorded yet - the dbt profile has no address until the kit install completes."
    }
    return $true
}

# Write-DbtExasolLauncher - generate ~\.local\bin\dbt-exasol.cmd.
#
# Named dbt-exasol, NOT dbt. Shadowing `dbt` on PATH would hijack a
# dbt-snowflake or dbt-postgres the user already relies on, and the kit does
# not get to take over a command name it did not create.
# Twin of dbt_exasol_write_launcher.
function Write-DbtExasolLauncher {
    $creds = Get-DbtExasolCredentials
    $pwfile = $creds.PasswordFile
    $exe = Get-DbtExasolVenvDbt

    try {
        New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    } catch {
        return (Write-DbtExasolNotInstalled "could not create $script:BinDir for the dbt-exasol launcher")
    }
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
        "rem dbt-exasol launcher - generated by the Exasol Personal Local Starter Kit."
        "rem Runs dbt from its kit-managed venv against the kit's local Exasol database."
        "rem Variables you set yourself take precedence. Regenerated by:"
        "rem   exakit update dbt-exasol"
        "rem"
        "rem Usage is dbt's own, with this name in front of it:"
        "rem   dbt-exasol debug     dbt-exasol run     dbt-exasol test"
        "rem It is deliberately not called dbt: a dbt you installed for another"
        "rem warehouse keeps that name."
    )
    if ($pwfile) {
        $lines += @(
            "if not defined DBT_ENV_SECRET_EXASOL_PASSWORD if exist `"$pwfile`" set /p DBT_ENV_SECRET_EXASOL_PASSWORD=<`"$pwfile`""
        )
    }
    $lines += @(
        "if not defined DBT_PROFILES_DIR set `"DBT_PROFILES_DIR=$($script:DbtExasolHome)`""
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
    if ($oemEnc) { [System.IO.File]::WriteAllText((Get-DbtExasolLauncherPath), ($lines -join "`r`n"), $oemEnc) }
    else { Set-Content -Path (Get-DbtExasolLauncherPath) -Value ($lines -join "`r`n") -Encoding Ascii }
    } catch {
        return (Write-DbtExasolNotInstalled "could not write the launcher at $(Get-DbtExasolLauncherPath)")
    }
    Ok "dbt-exasol launcher written: $(Get-DbtExasolLauncherPath)"
    return $true
}

# Is there a database to connect to at all? A cheap TCP probe on the recorded
# DSN, two seconds, no driver and no credentials.
#
# This runs BEFORE the real connection check rather than letting `dbt debug`
# discover a stopped database by timing out: the driver's own timeout would
# hang a marketplace install for as long as it takes, and a hang during an
# install is precisely the "something is wrong" feeling a stopped database
# does not deserve to cause. Twin of _dbt_exasol_db_reachable.
function Test-DbtExasolDbReachable {
    $dsn = "" + (Get-ExakitManifestValue "runtime.dsn")
    if (-not $dsn) { return $false }
    $idx = $dsn.LastIndexOf(":")
    if ($idx -lt 0) { return $false }
    $dbHost = $dsn.Substring(0, $idx)
    $portText = $dsn.Substring($idx + 1)
    if (-not $dbHost) { $dbHost = "127.0.0.1" }
    if ($portText -notmatch '^[0-9]+$') { return $false }
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($dbHost, [int]$portText, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(2000, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

# The real thing: scaffold a throwaway dbt project in a temp directory and let
# `dbt debug` open a connection with the generated profile. Non-destructive -
# dbt debug connects and tests, it creates no schema and no tables. Everything
# it prints goes to the log, not to the user. Twin of _dbt_exasol_debug_ok.
function Test-DbtExasolDebug {
    $exe = Get-DbtExasolVenvDbt
    if (-not (Test-Path $exe)) { return $false }
    $creds = Get-DbtExasolCredentials
    if (-not $creds.PasswordFile -or -not (Test-Path $creds.PasswordFile)) { return $false }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("exakit-dbt-probe-" + [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $projectLines = @(
        "name: exakit_probe"
        "version: `"1.0.0`""
        "config-version: 2"
        "profile: $($script:DbtExasolProfile)"
    )
    Set-Content -Path (Join-Path $tmp "dbt_project.yml") -Value ($projectLines -join "`r`n") -Encoding Ascii

    # The password lives in this process's environment only for the length of
    # the probe: never a file, never an argument, and never the log (dbt
    # scrubs DBT_ENV_SECRET_*).
    $code = 1
    Push-Location $tmp
    try {
        $env:DBT_ENV_SECRET_EXASOL_PASSWORD = (Get-Content -Path $creds.PasswordFile -TotalCount 1).Trim()
        $env:DBT_PROFILES_DIR = $script:DbtExasolHome
        # `dbt debug` GRADES THE MACHINE, NOT THE CONNECTION. Its "Required
        # dependencies" check runs `git --help` and folds the result into the same
        # pass/fail as the connection test - and on a machine with no git on PATH it
        # does not merely fail, it raises before the connection is ever tried:
        #
        #     Required dependencies:
        #     [ERROR]: Encountered an error:
        #     Got a non-zero returncode running: ['git', '--help']
        #
        # Windows ships no git; macOS and Linux effectively always have one. So every
        # fresh Windows install reported "dbt-exasol is installed, but dbt could not
        # connect to the database" over a database dbt had never been asked about,
        # while the same kit passed on every developer machine. `--connection` is
        # dbt's own flag for exactly this - "test the connection to the target
        # database independent of dependency checks" - and it still loads the profile
        # and the project, which are the parts that belong to this probe. Verified
        # against dbt 1.12.5: without git `debug` exits 2 and `debug --connection`
        # exits 0 with "Connection test: [OK connection ok]".
        # Twin of the same call in _dbt_exasol_debug_ok.
        $code = Invoke-ExakitLogged $exe "debug" "--connection"
    } catch {
        $code = 1
    } finally {
        Pop-Location
        Remove-Item Env:DBT_ENV_SECRET_EXASOL_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:DBT_PROFILES_DIR -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    return ($code -eq 0)
}

# Test-DbtExasol - prove the adapter imports, then prove dbt can actually reach
# the database.
#
# The two-step shape is INTERNAL. From the marketplace the user chose a row and
# pressed Enter; the only thing they asked is whether dbt-exasol is on the
# machine. A stopped database is not a broken install, so it produces no
# warning and no question - the reachability probe decides which check runs,
# and only a database that IS reachable can produce a failure.
#
# What differs between the two paths is the RECORD, not the output:
# validated_by is `connection` when a connection was really opened and `import`
# when only the install was proved. Writing "connection" for a run that never
# connected would make `exakit doctor` report a check it never made, and it is
# what lets the next `exakit update dbt-exasol` finish the job once the
# database is up. Twin of dbt_exasol_validate.
function Test-DbtExasol {
    $python = Get-DbtExasolVenvPython
    # Nothing to validate when the install did not get far enough: it is
    # soft-fail by design and has already explained itself.
    if (-not (Test-Path $python)) { return }
    $code = Invoke-ExakitLogged $python "-c" "import dbt.adapters.exasol"
    if ($code -ne 0) {
        Warn2 "dbt-exasol is installed but the adapter cannot be imported from $script:DbtExasolVenv (see log). Recorded validated=false; retry with: exakit update"
        Set-ExakitManifestValue "components.dbt_exasol.validated" $false
        return
    }

    if (Test-DbtExasolDbReachable) {
        Info "Validating dbt-exasol against the local database"
        $script:ExakitActiveLabel = "Validating dbt-exasol against the database"
        if (Test-DbtExasolDebug) {
            Set-ExakitManifestValue "components.dbt_exasol.validated" $true
            Set-ExakitManifestValue "components.dbt_exasol.validated_by" "connection"
            Ok "dbt-exasol connects to the database (profile: $($script:DbtExasolProfile))"
            return
        }
        # The database answered and dbt still could not use it. That is a real
        # defect and the one case here that says so out loud.
        Warn2 "dbt-exasol is installed, but dbt could not connect to the database (see log). Retry with: exakit update dbt-exasol"
        Set-ExakitManifestValue "components.dbt_exasol.validated" $false
        Set-ExakitManifestValue "components.dbt_exasol.validated_by" "connection"
        return
    }

    # No database to reach, so the connection half cannot be judged. The
    # install itself is proven, which is what was asked for - so this is a
    # success, and a silent one. The install's own Ok line is the whole story
    # the user needs; only the record below remembers what was not checked.
    Set-ExakitManifestValue "components.dbt_exasol.validated" $true
    Set-ExakitManifestValue "components.dbt_exasol.validated_by" "import"
}

function Install-DbtExasol {
    # The marketplace path runs from the exakit CLI, where the installer's
    # version resolution has not run - resolve the advertised version here.
    if (-not $script:DbtExasolVersion) {
        $resolved = Get-ExakitComponentAvailable "dbt-exasol"
        if ($resolved) { $script:DbtExasolVersion = $resolved }
        else { $script:DbtExasolVersion = $script:DbtExasolVersionFallback }
    }

    # Install-ExakitUv fails hard on its own; this step may not end the run, so
    # the throw is caught and turned into a soft miss.
    try {
        $uv = Install-ExakitUv
    } catch {
        return (Write-DbtExasolNotInstalled "uv (the Python tool runner) is not available - install it from https://docs.astral.sh/uv/ and re-run")
    }
    $python = Get-DbtExasolVenvPython

    $current = Get-DbtExasolPackageVersion
    if ($current -and $current -eq $script:DbtExasolVersion -and $env:EXAKIT_FORCE_COMPONENT_INSTALL -ne "1") {
        Ok "dbt-exasol $current already installed: $script:DbtExasolVenv"
    } else {
        $script:ExakitActiveLabel = "Installing dbt-exasol $($script:DbtExasolVersion)"
        Info "Installing dbt-exasol $($script:DbtExasolVersion) (the dbt adapter for Exasol; dbt-core comes with it)"
        if (-not (Test-Path $python)) {
            $code = Invoke-ExakitLogged $uv "venv" "--python" $script:ManagedPythonVersion $script:DbtExasolVenv
            if ($code -ne 0) {
                return (Write-DbtExasolNotInstalled "the virtual environment at $script:DbtExasolVenv could not be created (see log)")
            }
        }
        # Version-pinned from PyPI over TLS. uv resolves dbt-core and the rest
        # of the tree the same way every other Python component here does.
        $code = Invoke-ExakitLogged $uv "pip" "install" "--python" $python "$($script:DbtExasolPackage)==$($script:DbtExasolVersion)"
        if ($code -ne 0) {
            return (Write-DbtExasolNotInstalled "installing $($script:DbtExasolPackage)==$($script:DbtExasolVersion) from PyPI failed (see log)")
        }
        # The install is not done until the venv can answer for the version: a
        # resolution that half-succeeded would otherwise be reported as
        # installed and only fail at the first dbt command.
        if (-not (Get-DbtExasolPackageVersion)) {
            return (Write-DbtExasolNotInstalled "the venv cannot report a dbt-exasol version after the install (see log)")
        }
        Ok "dbt-exasol installed: $script:DbtExasolVenv"
    }

    if (-not (Write-DbtExasolProfile)) { return $false }
    if (-not (Write-DbtExasolLauncher)) { return $false }

    Set-ExakitManifestValue "components.dbt_exasol.version" $script:DbtExasolVersion
    Set-ExakitManifestValue "components.dbt_exasol.venv" $script:DbtExasolVenv
    Set-ExakitManifestValue "components.dbt_exasol.python" $python
    Set-ExakitManifestValue "components.dbt_exasol.command" (Get-DbtExasolLauncherPath)
    Set-ExakitManifestValue "components.dbt_exasol.profiles_dir" $script:DbtExasolHome
    Set-ExakitManifestValue "components.dbt_exasol.profile" $script:DbtExasolProfile
    return $true
}

# Update-DbtExasol - install the advertised version into the venv. Doubles as
# the repair command after a failed marketplace install. Asked for explicitly,
# so a failure here IS a failure. Twin of dbt_exasol_update.
function Update-DbtExasol {
    $available = Get-ExakitComponentAvailable "dbt-exasol"
    if (-not $available) { Fail "Could not resolve the advertised dbt-exasol version." }
    $current = Get-DbtExasolInstalledVersion
    if ($current -and $current -eq $available) {
        # Same version can still need repair: regenerate the profile and the
        # launcher so a DSN or credential change since the install is picked
        # up, then re-run validation, which is how a check that fell back to
        # the import probe (database was down) finally gets its connection
        # proved.
        [void](Write-DbtExasolProfile)
        [void](Write-DbtExasolLauncher)
        Test-DbtExasol
        Ok "dbt-exasol is already current ($current)"
        return
    }
    if ($current) { Info "Updating dbt-exasol $current -> $available" }
    else { Info "Installing dbt-exasol $available" }
    $script:DbtExasolVersion = $available
    $env:EXAKIT_FORCE_COMPONENT_INSTALL = "1"
    try {
        if (-not (Install-DbtExasol)) {
            Fail "dbt-exasol could not be installed - see the warning above and the log."
        }
    } finally {
        Remove-Item Env:EXAKIT_FORCE_COMPONENT_INSTALL -ErrorAction SilentlyContinue
    }
    Test-DbtExasol
    Set-ExakitManifestValue "desired.dbt_exasol" $script:DbtExasolVersion
    Ok "dbt-exasol updated; database data was not changed"
}

# The one fact worth a place on the result line. Twin of dbt_exasol_summary.
function Get-DbtExasolSummary {
    # 30 characters: the finished cell truncates at 33 in the plain palette.
    return "build SQL models: dbt-exasol"
}

# Remove everything the dbt-exasol install put on this machine. -DryRun only
# narrates the plan. Best-effort and idempotent.
#
# The venv and the launcher are wholly ours and go. The profile directory is
# NOT: only the generated profiles.yml is removed, and the directory itself
# only if nothing else is in it. Anyone who kept a dbt project under it would
# otherwise lose their work to a command that promised to remove an adapter.
# Twin of dbt_exasol_uninstall.
function Uninstall-DbtExasol {
    param([switch]$DryRun)
    foreach ($path in @($script:DbtExasolVenv, (Get-DbtExasolLauncherPath))) {
        if (-not ($path -and (Test-Path $path))) { continue }
        if ($DryRun) { Info "  will remove: $path" }
        else {
            Info "Removing $path"
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $path
        }
    }
    $profilePath = Get-DbtExasolProfilesPath
    if (Test-Path $profilePath) {
        if ($DryRun) { Info "  will remove: $profilePath (anything else in that folder is left alone)" }
        else {
            Info "Removing $profilePath"
            Remove-Item -Force -ErrorAction SilentlyContinue $profilePath
        }
    }
    if (-not $DryRun) {
        # Fails harmlessly, and on purpose, when the user kept something there.
        if (Test-Path $script:DbtExasolHome) {
            if (-not @(Get-ChildItem -Force -Path $script:DbtExasolHome -ErrorAction SilentlyContinue).Count) {
                Remove-Item -Force -ErrorAction SilentlyContinue $script:DbtExasolHome
            }
        }
        Remove-ExakitManifestValue "components.dbt_exasol"
        Remove-ExakitManifestValue "desired.dbt_exasol"
        OkStep "dbt-exasol removed - reinstall any time with: exakit marketplace"
    }
    return $true
}
