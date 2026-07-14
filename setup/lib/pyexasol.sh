# pyexasol.sh — pyexasol (Exasol Python driver): managed install + validation.
#
# Installs the official Exasol Python driver (github.com/exasol/pyexasol)
# into a dedicated uv-managed virtual environment under $EXAKIT_HOME, so
# users can script against the local database from Python immediately —
# without touching the system interpreter or any of their own projects.
#
#   - PyPI package: pyexasol
#   - venv:         $EXAKIT_HOME/pyexasol-venv
#   - use it:       ~/.exasol-starter-kit/pyexasol-venv/bin/python
#                       >>> import pyexasol
#
# Requires common.sh sourced first. Safe to re-run: an existing venv with
# the desired version installed is kept as-is.

EXAKIT_PYEXASOL_PACKAGE="${EXAKIT_PYEXASOL_PACKAGE:-pyexasol}"
EXAKIT_PYEXASOL_VENV="${EXAKIT_PYEXASOL_VENV:-$EXAKIT_HOME/pyexasol-venv}"

pyexasol_venv_python() {
    printf '%s\n' "$EXAKIT_PYEXASOL_VENV/bin/python"
}

pyexasol_installed_version() {
    _pyx_python="$(pyexasol_venv_python)"
    [ -x "$_pyx_python" ] || return 1
    "$_pyx_python" -c 'import pyexasol; print(pyexasol.__version__)' 2>/dev/null
}

pyexasol_install() {
    # uv is normally present already (the MCP step installs it and it is a
    # hard dependency of the kit); bootstrap it here only if this step runs
    # in a build without the MCP module.
    if ! command -v uv >/dev/null 2>&1; then
        if command -v mcp_uv_install >/dev/null 2>&1; then
            mcp_uv_install
        else
            die "uv is required to install pyexasol but is not available. Install uv (https://docs.astral.sh/uv/) and re-run."
        fi
    fi

    _pyx_current="$(pyexasol_installed_version || true)"
    if [ -n "$_pyx_current" ] && [ "$_pyx_current" = "$EXAKIT_PYEXASOL_VERSION" ]; then
        ok "pyexasol $_pyx_current already installed: $EXAKIT_PYEXASOL_VENV"
    else
        info "Installing pyexasol $EXAKIT_PYEXASOL_VERSION (Exasol Python driver)"
        if [ ! -x "$(pyexasol_venv_python)" ]; then
            run_logged uv venv --python "$EXAKIT_MANAGED_PYTHON_VERSION" "$EXAKIT_PYEXASOL_VENV" || \
                die "Could not create the pyexasol virtual environment at $EXAKIT_PYEXASOL_VENV (see log)."
            push_rollback "rm -rf '$EXAKIT_PYEXASOL_VENV'"
        fi
        run_logged uv pip install --python "$(pyexasol_venv_python)" \
            "${EXAKIT_PYEXASOL_PACKAGE}==${EXAKIT_PYEXASOL_VERSION}" || \
            die "pyexasol installation failed (see log)."
        ok "pyexasol installed: $EXAKIT_PYEXASOL_VENV"
    fi

    manifest_set components.pyexasol.version "$EXAKIT_PYEXASOL_VERSION"
    manifest_set components.pyexasol.venv "$EXAKIT_PYEXASOL_VENV"
    manifest_set components.pyexasol.python "$(pyexasol_venv_python)"
}

# pyexasol_apply_sve_workaround <venv-python> — recognize and self-repair the
# faked-SVE crash. On aarch64 guests whose hypervisor advertises SVE the host
# CPU cannot execute (seen: VirtualBox on Apple Silicon), importing
# cryptography's native module dies with SIGILL inside OpenSSL's CPU
# detection, taking `import pyexasol` down with it. Confirm that exact
# signature (the import succeeds with OPENSSL_armcap=0), then pin the
# override into the venv via sitecustomize.py — it runs at interpreter
# startup, before any package can load OpenSSL — so every consumer of this
# venv works without callers having to know about the quirk. Returns 0 only
# when the plain import provably works afterwards.
pyexasol_apply_sve_workaround() {
    _sve_python="$1"
    detect_cpu_advertises_sve || return 1
    ( OPENSSL_armcap=0 "$_sve_python" -c 'import pyexasol' && : ) >/dev/null 2>&1 || return 1

    warn "pyexasol crashed inside OpenSSL's CPU detection: this guest advertises SVE its host CPU cannot execute."
    info "Self-repair: pinning OPENSSL_armcap=0 for this venv (disables OpenSSL's ARM fast paths, correctness unaffected)"
    _sve_site="$("$_sve_python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' 2>/dev/null)"
    [ -n "$_sve_site" ] && [ -d "$_sve_site" ] || return 1
    cat > "$_sve_site/sitecustomize.py" <<'EXAKIT_SVE_EOF'
# Written by the Exasol Personal Local Starter Kit.
# This virtualization guest advertises SVE support the host CPU cannot
# execute (seen with VirtualBox on Apple Silicon), which crashes OpenSSL's
# runtime CPU detection with SIGILL when cryptography loads. Pinning
# OPENSSL_armcap=0 here runs before any package import and disables the
# optimized paths. The pin applies only while the kernel still advertises
# SVE, so it deactivates itself once the guest boots with arm64.nosve
# (needs a kernel that honors it, e.g. the HWE kernel) — full crypto speed
# returns without touching this file.
import os


def _kernel_advertises_sve() -> bool:
    try:
        with open("/proc/cpuinfo") as handle:
            features = next(
                (line for line in handle if line.startswith("Features")), ""
            )
    except OSError:
        return False
    return " sve" in features


if _kernel_advertises_sve():
    os.environ.setdefault("OPENSSL_armcap", "0")
EXAKIT_SVE_EOF

    if ! ( "$_sve_python" -c 'import pyexasol' && : ) >/dev/null 2>&1; then
        rm -f "$_sve_site/sitecustomize.py"
        return 1
    fi
    manifest_set components.pyexasol.openssl_armcap_workaround true
    detect_sve_remedy_hint
    ok "pyexasol imports cleanly with the workaround in place"
    return 0
}

# pyexasol_validate — prove the driver imports, then run SELECT 1 against the
# local database with the runtime credentials. A failed live check records
# validated=false and warns rather than aborting the install: the database
# and every other component are unaffected, and a re-run retries this step.
pyexasol_validate() {
    _pyx_python="$(pyexasol_venv_python)"
    # Non-fatal, matching this step's stated contract (and the live-check path
    # below): pyexasol is the last, optional component, so a broken import
    # records validated=false and warns rather than turning an otherwise
    # complete install — database, exapump, MCP all working — into a hard fail.
    # The subshell keeps bash's job-status noise ("Illegal instruction (core
    # dumped)") out of the user-facing output when the probe dies on a
    # signal. The `&& :` matters: it defeats bash's single-command subshell
    # exec optimization, which would otherwise leave the OUTER shell (whose
    # stderr is the terminal) as the one reporting the signal death.
    if ! ( "$_pyx_python" -c 'import pyexasol' && : ) >/dev/null 2>&1; then
        if pyexasol_apply_sve_workaround "$_pyx_python"; then
            : # import fixed in place — fall through to the live check below
        else
            warn "pyexasol is installed but cannot be imported from $EXAKIT_PYEXASOL_VENV (see log). Recorded validated=false; remove the venv and re-run setup to retry."
            manifest_set components.pyexasol.validated false
            return 0
        fi
    fi

    _pyx_host="$(_exakit_parse_runtime_host)"
    _pyx_port="$(_exakit_parse_runtime_port)"
    _pyx_user="$(_exakit_manifest_runtime_value runtime.user)"
    _pyx_pwfile="$(_exakit_manifest_runtime_value runtime.password_file)"
    if [ -z "$_pyx_host" ] || [ -z "$_pyx_port" ] || [ -z "$_pyx_user" ] || \
       [ -z "$_pyx_pwfile" ] || [ ! -f "$_pyx_pwfile" ]; then
        warn "Runtime connection details are incomplete; skipping the pyexasol live check. Re-run setup to retry."
        manifest_set components.pyexasol.validated false
        return 0
    fi

    info "Validating pyexasol against the database (SELECT 1)"
    # The password travels via a file read inside python, never on a command
    # line. TLS mirrors the exapump profile posture (tls on, local cert not
    # validated); a plain connection is the fallback for non-TLS runtimes.
    if EXAKIT_PYX_DSN="${_pyx_host}:${_pyx_port}" \
       EXAKIT_PYX_USER="$_pyx_user" \
       EXAKIT_PYX_PWFILE="$_pyx_pwfile" \
       "$_pyx_python" - >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 <<'PY'
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
PY
    then
        ok "pyexasol works: SELECT 1 returned 1"
        manifest_set components.pyexasol.validated true
        info "Use it from Python:  $_pyx_python  (import pyexasol)"
    else
        warn "pyexasol could not complete SELECT 1 against the database (see log). Recorded validated=false; re-run setup to retry."
        manifest_set components.pyexasol.validated false
    fi
    return 0
}
