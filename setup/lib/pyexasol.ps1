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
    $version = & $python -c "import pyexasol; print(pyexasol.__version__)" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($version | Out-String).Trim()
}

function Install-Pyexasol {
    $uv = Install-ExakitUv
    $python = Get-PyexasolVenvPython

    $current = Get-PyexasolInstalledVersion
    if ($current -and $current -eq $script:PyexasolVersion) {
        Ok "pyexasol $current already installed: $script:PyexasolVenv"
    } else {
        Info "Installing pyexasol $($script:PyexasolVersion) (Exasol Python driver)"
        if (-not (Test-Path $python)) {
            $code = Invoke-ExakitLogged $uv "venv" "--python" $script:ManagedPythonVersion $script:PyexasolVenv
            if ($code -ne 0) { Fail "Could not create the pyexasol virtual environment at $script:PyexasolVenv (see log)." }
        }
        $code = Invoke-ExakitLogged $uv "pip" "install" "--python" $python "$($script:PyexasolPackage)==$($script:PyexasolVersion)"
        if ($code -ne 0) { Fail "pyexasol installation failed (see log)." }
        Ok "pyexasol installed: $script:PyexasolVenv"
    }

    Set-ExakitManifestValue "components.pyexasol.version" $script:PyexasolVersion
    Set-ExakitManifestValue "components.pyexasol.venv" $script:PyexasolVenv
    Set-ExakitManifestValue "components.pyexasol.python" $python
}

# Test-PyexasolConnection - prove the driver imports, then run SELECT 1
# against the local database with the runtime credentials. A failed live
# check records validated=false and warns rather than aborting the install:
# the database and every other component are unaffected, and a re-run
# retries this step.
function Test-PyexasolConnection {
    $python = Get-PyexasolVenvPython
    $code = Invoke-ExakitLogged $python "-c" "import pyexasol"
    if ($code -ne 0) {
        # Non-fatal, matching this step's contract and the bash path: pyexasol
        # is the last, optional component, so a broken import records
        # validated=false and warns rather than failing an otherwise complete
        # install (database, exapump, MCP all working).
        Warn2 "pyexasol is installed but cannot be imported from $script:PyexasolVenv (see log). Recorded validated=false; remove the venv and re-run setup to retry."
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
        Info "Use it from Python:  $python  (import pyexasol)"
    } else {
        Warn2 "pyexasol could not complete SELECT 1 against the database (see log). Recorded validated=false; re-run setup to retry."
        Set-ExakitManifestValue "components.pyexasol.validated" $false
    }
}
