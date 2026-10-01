# pyexasol.ps1 - pyexasol (Exasol Python driver): managed install + validation.
#
# Windows counterpart of pyexasol.sh. Installs the official Exasol Python
# driver (github.com/exasol/pyexasol) into a dedicated uv-managed virtual
# environment under the kit home, so users can script against the local
# database from Python without touching the system interpreter.
#
#   - PyPI package: pyexasol
#   - venv:         ~\.exasol-starter-kit\pyexasol-venv
#   - use it:       ~\.exasol-starter-kit\pyexasol-venv\Scripts\python.exe
#                       >>> import pyexasol
#
# Requires exakit-common.ps1 dot-sourced first. Safe to re-run: an existing
# venv with the desired version installed is kept as-is.

$script:PyexasolVenv = if ($env:EXAKIT_PYEXASOL_VENV) { $env:EXAKIT_PYEXASOL_VENV } else { Join-Path $script:ExakitHome "pyexasol-venv" }

function Get-PyexasolVenvPython {
    return (Join-Path $script:PyexasolVenv "Scripts\python.exe")
}

function Get-PyexasolInstalledVersion {
    $python = Get-PyexasolVenvPython
    if (-not (Test-Path $python)) { return $null }
    # A venv whose pyexasol is broken prints a traceback to stderr, and under
    # $ErrorActionPreference = "Stop" that stderr terminates the run before
    # $LASTEXITCODE can be read - so `exakit version` would die reporting a
    # version rather than answer "not installed". Same defence as
    # Invoke-ExakitLogged.
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $version = & $python -c "import pyexasol; print(pyexasol.__version__)" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($version | Out-String -Width 4096).Trim()
    } catch {
        return $null
    } finally { $ErrorActionPreference = $prevEap }
}

# Write-PyexasolNotInstalled <reason> - report a soft failure and return $false.
# pyexasol is the last, optional Component, and the exakit helper is installed
# AFTER it: failing here would leave a user with a working database but no exakit
# command to manage it. So every failure in this step is explained, recorded as
# validated=false, and handed back to the caller as $false, which leaves the step
# unmarked so a re-run retries it. Mirrors _pyexasol_not_installed in pyexasol.sh.
function Write-PyexasolNotInstalled {
    param([Parameter(Mandatory)][string]$Reason)
    Warn2 "pyexasol was not installed: $Reason"
    Warn2 "Everything else in the kit is unaffected. Retry with: exakit update"
    # Hand the reason to the closing summary, which prints it next to the repair
    # command; without this the user is told only that pyexasol is missing.
    Set-ExakitFailureReason $Reason
    Set-ExakitManifestValue "components.pyexasol.validated" $false
    return $false
}

function Install-Pyexasol {
    # Install-ExakitUv fails hard on its own; this step may not end the run, so
    # the throw is caught and turned into a soft miss.
    try {
        $uv = Install-ExakitUv
    } catch {
        return (Write-PyexasolNotInstalled "uv (the Python tool runner) is not available - install it from https://docs.astral.sh/uv/ and re-run")
    }
    $python = Get-PyexasolVenvPython

    $current = Get-PyexasolInstalledVersion
    if ($current -and $current -eq $script:PyexasolVersion) {
        Ok "pyexasol $current already installed: $script:PyexasolVenv"
    } else {
        $script:ExakitActiveLabel = "Installing pyexasol $($script:PyexasolVersion)"
        Info "Installing pyexasol $($script:PyexasolVersion) (Exasol Python driver)"
        if (-not (Test-Path $python)) {
            # --seed puts pip in the venv (uv leaves it out). Twin of pyexasol.sh.
            $code = Invoke-ExakitLogged $uv "venv" "--seed" "--python" $script:ManagedPythonVersion $script:PyexasolVenv
            if ($code -ne 0) {
                return (Write-PyexasolNotInstalled "the virtual environment at $script:PyexasolVenv could not be created (see log)")
            }
        }
        $code = Invoke-ExakitLogged $uv "pip" "install" "--python" $python "$($script:PyexasolPackage)==$($script:PyexasolVersion)"
        if ($code -ne 0) {
            return (Write-PyexasolNotInstalled "installing $($script:PyexasolPackage)==$($script:PyexasolVersion) failed (see log)")
        }
        Ok "pyexasol installed: $script:PyexasolVenv"
    }

    Set-ExakitManifestValue "components.pyexasol.version" $script:PyexasolVersion
    Set-ExakitManifestValue "components.pyexasol.venv" $script:PyexasolVenv
    Set-ExakitManifestValue "components.pyexasol.python" $python
    return $true
}

# Update-Pyexasol - install the advertised version into the venv. Doubles as the
# repair command: the install step is soft-fail, so this is what a user runs after
# `exakit status` or `exakit version` reports pyexasol as missing. Asked for
# explicitly, so a failure here IS a failure. Twin of pyexasol_update.
function Update-Pyexasol {
    $available = Get-ExakitComponentAvailable "pyexasol"
    if (-not $available) { Fail "Could not resolve the advertised pyexasol version." }
    $current = Get-PyexasolInstalledVersion
    if ($current -and $current -eq $available) {
        Ok "pyexasol is already current ($current)"
        return
    }
    if ($current) { Info "Updating pyexasol $current -> $available" }
    else { Info "Installing pyexasol $available" }
    $script:PyexasolVersion = $available
    if (-not (Install-Pyexasol)) {
        Fail "pyexasol could not be installed - see the warning above and the log."
    }
    Test-PyexasolConnection
    Set-ExakitManifestValue "desired.pyexasol" $script:PyexasolVersion
    Ok "pyexasol updated; database data was not changed"
}

# Test-PyexasolConnection - prove the driver imports, then run SELECT 1
# against the local database with the runtime credentials. A failed live
# check records validated=false and warns rather than aborting the install:
# the database and every other component are unaffected, and a re-run
# retries this step.
function Test-PyexasolConnection {
    $python = Get-PyexasolVenvPython
    # Nothing to validate when the install did not get far enough to create the
    # venv: it is soft-fail by design and has already explained itself.
    if (-not (Test-Path $python)) { return }
    $code = Invoke-ExakitLogged $python "-c" "import pyexasol"
    if ($code -ne 0) {
        # Non-fatal, matching this step's contract and the bash path: pyexasol
        # is the last, optional component, so a broken import records
        # validated=false and warns rather than failing an otherwise complete
        # install (database, exapump, MCP all working).
        Warn2 "pyexasol is installed but cannot be imported from $script:PyexasolVenv. Why: exakit logs setup. Recorded validated=false; remove the venv and re-run setup to retry."
        Set-ExakitManifestValue "components.pyexasol.validated" $false
        return
    }

    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $user = Get-ExakitManifestValue "runtime.user"
    $passwordFile = Get-ExakitManifestValue "runtime.password_file"
    if (-not $dsn -or -not $user -or -not $passwordFile -or -not (Test-Path $passwordFile)) {
        Warn2 "Runtime connection details are incomplete; skipping the pyexasol live check. Re-run setup to retry."
        Set-ExakitManifestValue "components.pyexasol.validated" $false
        return
    }

    Info "Validating pyexasol against the database (SELECT 1)"
    $pyvT0 = Get-Date
    $script:ExakitActiveLabel = "Validating pyexasol against the database"
    # The probe script contains no secrets: the password travels via a file
    # read inside python, never on a command line. TLS mirrors the exapump
    # profile posture (tls on, local cert not validated); a plain connection
    # is the fallback for non-TLS runtimes.
    $probe = @'
import os, ssl, pyexasol
pw = open(os.environ["EXAKIT_PYX_PWFILE"]).read().strip()
kw = dict(dsn=os.environ["EXAKIT_PYX_DSN"], user=os.environ["EXAKIT_PYX_USER"], password=pw)
try:
    conn = pyexasol.connect(encryption=True, websocket_sslopt={"cert_reqs": ssl.CERT_NONE}, **kw)
except Exception:
    conn = pyexasol.connect(encryption=False, **kw)
try:
    value = conn.execute("SELECT 1").fetchval()
    raise SystemExit(0 if value == 1 else 1)
finally:
    conn.close()
'@
    $probeFile = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-pyexasol-probe-$PID.py"
    $env:EXAKIT_PYX_DSN = $dsn
    $env:EXAKIT_PYX_USER = $user
    $env:EXAKIT_PYX_PWFILE = $passwordFile
    try {
        Set-Content -Path $probeFile -Value $probe -Encoding ascii
        $code = Invoke-ExakitLogged $python $probeFile
    } finally {
        Remove-Item -Force $probeFile -ErrorAction SilentlyContinue
        Remove-Item Env:EXAKIT_PYX_DSN, Env:EXAKIT_PYX_USER, Env:EXAKIT_PYX_PWFILE -ErrorAction SilentlyContinue
    }

    if ($code -eq 0) {
        Ok "pyexasol works: SELECT 1 returned 1"
        Set-ExakitManifestValue "components.pyexasol.validated" $true
        # Two lines for the step: what happened, and the interpreter to run it
        # with. Installed-and-validated is one fact - an install that failed
        # validation says so through the Warn2 below, which is never gated.
        OkStep "pyexasol $($script:PyexasolVersion) installed and validated against the database ($([int]((Get-Date) - $pyvT0).TotalSeconds)s)"
        InfoStep "Use it from Python:  $(Get-ExakitTilde $python)  (import pyexasol)"
    } else {
        Warn2 "pyexasol could not complete SELECT 1 against the database. Why: exakit logs setup. Check the database is up with: exakit status, then re-run setup to retry."
        Set-ExakitManifestValue "components.pyexasol.validated" $false
    }
}
