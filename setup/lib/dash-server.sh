#!/usr/bin/env bash
# dash-server.sh — dash-server (AI dashboard host): managed install + validation.
#
# A MARKETPLACE ADD-ON: never installed by the setup scripts. The user picks it
# from `exakit marketplace`; once installed it joins `exakit update` like every
# other component. Sourced by the exakit CLI after common.sh.
#
# dash-server facts:
#   - Agent-operated Dash hosting server for Exasol-backed dashboards
#     (github.com/exasol-labs/dash-server): agents build/deploy dashboards
#     through its MCP control plane (Streamable HTTP at /mcp), users open a
#     browser URL.
#   - Pure-Python package with a `dash-server` console script; releases carry
#     no prebuilt binaries, so the install is `uv pip install` of the tag's
#     source tarball into a dedicated venv under the kit home — tag-pinned like
#     the mcp and pyexasol components, but with NO digest verification: the
#     release publishes no digest for the tarball, unlike the binary add-ons
#     components. (GitHub source tarballs have no stable published digest, so
#     there is nothing kit-side to pin a checksum against.)
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
#   - venv:     $EXAKIT_HOME/dash-server-venv
#   - state:    $EXAKIT_HOME/dash-server/instance (GitOps repo, apps, secrets)
#   - launcher: $EXAKIT_BIN_DIR/dash-server (bootstraps env, then execs the venv
#               console script)
#
# Safe to re-run: an existing venv with the desired version installed is kept.

# The add-on's version constants live here, next to the code that uses them —
# the generic registry arms in common.sh find them by the derived name
# convention (EXAKIT_<ID>_VERSION[_FALLBACK]), and the versions-bump workflow
# keeps the fallback in lockstep with versions.json (COUPLED table).
EXAKIT_DASH_SERVER_VERSION="${EXAKIT_DASH_SERVER_VERSION:-}"
EXAKIT_DASH_SERVER_VERSION_FALLBACK="${EXAKIT_DASH_SERVER_VERSION_FALLBACK:-0.1.1}"
EXAKIT_DASH_SERVER_REPO="${EXAKIT_DASH_SERVER_REPO:-exasol-labs/dash-server}"
EXAKIT_DASH_SERVER_PACKAGE="${EXAKIT_DASH_SERVER_PACKAGE:-dash-server}"
EXAKIT_DASH_SERVER_VENV="${EXAKIT_DASH_SERVER_VENV:-$EXAKIT_HOME/dash-server-venv}"
EXAKIT_DASH_SERVER_HOME="${EXAKIT_DASH_SERVER_HOME:-$EXAKIT_HOME/dash-server}"
EXAKIT_DASH_SERVER_BIN="${EXAKIT_DASH_SERVER_BIN:-$EXAKIT_BIN_DIR/dash-server}"
# An explicit choice outranks everything; otherwise the port this install
# actually settled on (it may have moved at install time to dodge a busy 5100)
# is read from the manifest the first time it is needed - lazily, because
# reading the manifest costs a Python start and every CLI run sources this.
if [ -n "${EXAKIT_DASH_SERVER_PORT:-}" ]; then
    _EXAKIT_DS_PORT_EXPLICIT=1
else
    _EXAKIT_DS_PORT_EXPLICIT=0
fi
EXAKIT_DASH_SERVER_PORT="${EXAKIT_DASH_SERVER_PORT:-5100}"
_EXAKIT_DS_PORT_RESOLVED=0

_dash_server_resolve_port() {
    [ "${_EXAKIT_DS_PORT_RESOLVED:-0}" = "1" ] && return 0
    _EXAKIT_DS_PORT_RESOLVED=1
    [ "$_EXAKIT_DS_PORT_EXPLICIT" = "1" ] && return 0
    [ -f "$EXAKIT_MANIFEST" ] || return 0
    _drp_recorded="$(manifest_get components.dash_server.port 2>/dev/null || true)"
    case "$_drp_recorded" in
        ''|*[!0-9]*) ;;
        *) EXAKIT_DASH_SERVER_PORT="$_drp_recorded" ;;
    esac
    return 0
}

# --- who holds the port -----------------------------------------------------
# "Something answers on 5100" is NOT "dash-server is running": any web server
# on that port would pass an HTTP probe, and the kit would report a healthy
# add-on that was never started. These three answer the real question.

_dash_server_port_pids() {
    # Through the shared probe, which tries ss, then lsof, then netstat. Asking
    # lsof alone meant a stock Fedora or Ubuntu Server -- neither ships it --
    # answered "nobody is listening" for every question below, and ownership
    # detection fell back to the bare HTTP probe: exactly the bug the two
    # functions under this one exist to prevent. Only when NONE of the three is
    # present is the answer unknown, and _dash_server_port_probe_degraded says
    # so once, so a wrong verdict is never silent.
    if command -v port_listener_pids >/dev/null 2>&1; then
        port_listener_pids "$EXAKIT_DASH_SERVER_PORT" 2>/dev/null
        return 0
    fi
    command -v lsof >/dev/null 2>&1 || return 0
    lsof -nP -iTCP:"$EXAKIT_DASH_SERVER_PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u
}

# True when no tool on this machine can name a listener, so "not ours" below is
# "cannot tell", not "checked and no". Callers that would otherwise report a
# confident verdict say which it was.
_dash_server_port_probe_degraded() {
    command -v ss >/dev/null 2>&1 && return 1
    command -v lsof >/dev/null 2>&1 && return 1
    command -v netstat >/dev/null 2>&1 && return 1
    return 0
}

# Is the listener one of OUR processes? Matched on the venv path, which is
# unique to this install, so an unrelated program never counts.
_dash_server_port_is_ours() {
    _dpo_pids="$(_dash_server_port_pids)"
    [ -n "$_dpo_pids" ] || return 1
    for _dpo_pid in $_dpo_pids; do
        case "$(ps -o command= -p "$_dpo_pid" 2>/dev/null)" in
            *"$EXAKIT_DASH_SERVER_VENV"*) return 0 ;;
        esac
    done
    return 1
}

# "pid N (name)" when someone ELSE holds the port; non-zero when it is free or
# ours.
_dash_server_port_foreign_desc() {
    _dpf_pids="$(_dash_server_port_pids)"
    [ -n "$_dpf_pids" ] || return 1
    _dash_server_port_is_ours && return 1
    for _dpf_pid in $_dpf_pids; do
        printf 'pid %s (%s)' "$_dpf_pid" \
            "$(ps -o comm= -p "$_dpf_pid" 2>/dev/null | sed 's|.*/||' | tr -d ' ')"
        return 0
    done
    return 1
}

# Is OUR server up? lsof answers precisely; without it fall back to the HTTP
# probe, which is the old behaviour and the best a machine without lsof allows.
_dash_server_running() {
    # Keyed on whether ANY listener probe exists, not on lsof specifically.
    # Gating this on lsof alone sent every machine without it (stock Fedora,
    # Ubuntu Server) to the HTTP probe, which any other program on the port
    # passes -- so the kit reported a healthy add-on it had never started.
    if ! _dash_server_port_probe_degraded; then
        _dash_server_port_is_ours
        return $?
    fi
    _dash_server_http_answers
}
EXAKIT_DASH_SERVER_PROFILE="${EXAKIT_DASH_SERVER_PROFILE:-starter-kit}"

dash_server_venv_python() {
    printf '%s\n' "$EXAKIT_DASH_SERVER_VENV/bin/python"
}

# dash_server_package_version — what the VENV alone says, with no opinion on
# whether the add-on is usable yet. The installer asks this immediately after
# pip, before the launcher exists; dash_server_installed_version below is the
# stricter question every other caller wants.
# ⇄ twin: Get-DashServerPackageVersion in dash-server.ps1.
dash_server_package_version() {
    _dsp_python="$(dash_server_venv_python)"
    [ -x "$_dsp_python" ] || return 1
    ( "$_dsp_python" -c 'from importlib.metadata import version; print(version("dash-server"))' && : ) 2>/dev/null
}

dash_server_installed_version() {
    # The manifest RECORD as well as the venv. The record is written at the END
    # of a successful install, so an install that died earlier leaves a venv and
    # nothing else, and no longer reports a version for something no command can
    # start. Every caller believed the old answer: the marketplace said "already
    # present - nothing to install", `exakit update dash-server` said
    # "everything is already current", and starting it said "not installed" -
    # with no documented command able to recover.
    #
    # Both halves, because neither alone is evidence. json_tables_installed_version
    # already takes exactly this line.
    _dsv_recorded="$(manifest_get components.dash_server.version 2>/dev/null || true)"
    [ -n "$_dsv_recorded" ] || return 1
    dash_server_package_version
}

# dash_server_release_url <version> — the source tarball of the tagged release.
# ⇄ twin: Get-DashServerReleaseUrl in dash-server.ps1.
dash_server_release_url() {
    printf 'https://github.com/%s/archive/refs/tags/v%s.tar.gz\n' \
        "$EXAKIT_DASH_SERVER_REPO" "$1"
}

# _dash_server_not_installed <reason> — report a soft failure and return 1.
# Marketplace add-ons follow the pyexasol contract: nothing here may end the
# caller's run; every failure is explained, recorded as validated=false, and
# handed back as a non-zero return so a re-run (or `exakit update dash-server`)
# retries it.
_dash_server_not_installed() {
    warn "dash-server was not installed: $1"
    # Explain the underlying fault BEFORE offering the retry. A corrupt uv
    # managed-Python cache makes the retry fail identically forever, so
    # "retry with" on its own is a loop, not a remedy.
    command -v exakit_explain_last_log_error >/dev/null 2>&1 && exakit_explain_last_log_error
    warn "Everything else in the kit is unaffected. Retry with: exakit update"
    # The reason has to outlive this subshell so the closing summary can print it
    # instead of a generic "did not finish" (see exakit_note_failure in common.sh).
    command -v exakit_note_failure >/dev/null 2>&1 && exakit_note_failure "$1"
    manifest_set components.dash_server.validated false
    return 1
}

dash_server_install() {
    # The marketplace path runs from the exakit CLI, where the installer's
    # exakit_resolve_install_versions has not run — resolve the advertised
    # version here (env override -> policy -> versions.json -> fallback).
    if [ -z "${EXAKIT_DASH_SERVER_VERSION:-}" ]; then
        EXAKIT_DASH_SERVER_VERSION="$(exakit_component_available dash-server 2>/dev/null || true)"
        [ -n "$EXAKIT_DASH_SERVER_VERSION" ] || EXAKIT_DASH_SERVER_VERSION="$EXAKIT_DASH_SERVER_VERSION_FALLBACK"
        export EXAKIT_DASH_SERVER_VERSION
    fi

    _dash_server_resolve_port
    _dash_server_settle_port || return 1

    _ds_uv=""
    if command -v uv >/dev/null 2>&1; then
        _ds_uv="uv"
    elif exakit_ensure_uv && [ -x "${EXAKIT_UV_BIN:-}" ]; then
        _ds_uv="$EXAKIT_UV_BIN"
    else
        _dash_server_not_installed "uv (the Python tool runner) is not available — install it from https://docs.astral.sh/uv/ and re-run"
        return 1
    fi

    _ds_current="$(dash_server_installed_version || true)"
    if [ -n "$_ds_current" ] && [ "$_ds_current" = "$EXAKIT_DASH_SERVER_VERSION" ] && \
       [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ]; then
        ok "dash-server $_ds_current already installed: $EXAKIT_DASH_SERVER_VENV"
        # An up-to-date venv can still be missing pip (created by a kit copy
        # from before the venv was seeded) — repair it in place rather than
        # leaving every app build broken until the next version bump.
        _dash_server_ensure_pip "$_ds_uv" || return 1
    else
        info "Installing dash-server $EXAKIT_DASH_SERVER_VERSION"
        if [ ! -x "$(dash_server_venv_python)" ]; then
            # --seed matters: dash-server installs each app's dependencies by
            # shelling out to `python -m pip`, and a bare uv venv has no pip —
            # every app build (including the built-in demo) would fail with
            # "Dependency install failed before import smoke check".
            if ! run_logged "$_ds_uv" venv --seed --python "$EXAKIT_MANAGED_PYTHON_VERSION" "$EXAKIT_DASH_SERVER_VENV"; then
                _dash_server_not_installed "the virtual environment at $EXAKIT_DASH_SERVER_VENV could not be created (see log)"
                return 1
            fi
            push_rollback "rm -rf '$EXAKIT_DASH_SERVER_VENV'"
        fi
        # The release's source tarball, pinned by tag. uv resolves and installs
        # it plus dependencies from PyPI over TLS.
        if ! run_logged "$_ds_uv" pip install --python "$(dash_server_venv_python)" \
                "$(dash_server_release_url "$EXAKIT_DASH_SERVER_VERSION")"; then
            _dash_server_not_installed "installing ${EXAKIT_DASH_SERVER_PACKAGE} v${EXAKIT_DASH_SERVER_VERSION} from its GitHub release failed (see log)"
            return 1
        fi
        # The install is not done until the venv can actually answer for the
        # version: a tarball that unpacked but failed to build would otherwise
        # be reported as installed and only fail at first launch.
        _ds_now="$(dash_server_package_version || true)"
        if [ -z "$_ds_now" ]; then
            _dash_server_not_installed "the venv cannot report a dash-server version after the install (see log)"
            return 1
        fi
        # Belt and braces even on a fresh venv: --seed above should have put
        # pip in place, but a pre-existing venv (EXAKIT_DASH_SERVER_VENV
        # pointed at one, or an interrupted earlier run) may lack it.
        _dash_server_ensure_pip "$_ds_uv" || return 1
        _dash_server_restore_package_data
        ok "dash-server installed: $EXAKIT_DASH_SERVER_VENV"
    fi

    mkdir -p "$EXAKIT_DASH_SERVER_HOME/instance" 2>/dev/null || {
        _dash_server_not_installed "could not create the state directory $EXAKIT_DASH_SERVER_HOME/instance"
        return 1
    }
    dash_server_write_launcher || return 1

    manifest_set components.dash_server.version "$EXAKIT_DASH_SERVER_VERSION"
    manifest_set components.dash_server.venv "$EXAKIT_DASH_SERVER_VENV"
    manifest_set components.dash_server.python "$(dash_server_venv_python)"
    manifest_set components.dash_server.command "$EXAKIT_DASH_SERVER_BIN"
    manifest_set components.dash_server.port "$EXAKIT_DASH_SERVER_PORT"
    manifest_set components.dash_server.instance "$EXAKIT_DASH_SERVER_HOME/instance"

    # AFTER the port is recorded, because that record is where the endpoint URL
    # comes from. Until this ran, dash-server's control plane was registered
    # nowhere: an agent had to hand-roll an HTTP transport against /mcp to reach
    # tools that every other MCP server on the machine offers by name.
    if command -v mcp_register_addon_servers >/dev/null 2>&1; then
        mcp_register_addon_servers "dash-server" || true
    fi
}

# _dash_server_restore_package_data — put back data files the release ships in
# its source tree but does NOT declare as package data, so pip never installs
# them.
#
# UPSTREAM BUG (dash-server 0.1.0): pyproject's [tool.setuptools.package-data]
# covers dash_server.exasol and dash_server.dash_apps but not dash_server
# itself, so all five Jinja templates under src/dash_server/templates are
# missing from every installed copy. The MCP control plane is unaffected (it
# renders nothing), which is why validation passed while the browser page
# answered 500 with TemplateNotFound: dashboard_catalog.html.
#
# Rather than ship a broken UI, the install re-downloads the same tag-pinned
# release tarball — NOT checksum-verified, because a GitHub source tarball
# publishes no digest to pin (see the module header) — and copies across any
# non-.py file that the source has and the installed package lacks. Nothing is overwritten, so a fixed release
# simply makes this a no-op — the day upstream declares the data, this quietly
# stops doing anything and can be deleted.
_dash_server_restore_package_data() {
    _drp_site="$("$(dash_server_venv_python)" -c 'import dash_server, os; print(os.path.dirname(dash_server.__file__))' 2>/dev/null)"
    [ -n "$_drp_site" ] && [ -d "$_drp_site" ] || return 0

    _drp_tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-ds-data.XXXXXX")" || return 0
    if ! fetch_quiet "$(dash_server_release_url "$EXAKIT_DASH_SERVER_VERSION")" \
            "$_drp_tmp/src.tar.gz"; then
        rm -rf "$_drp_tmp"
        return 0
    fi
    ( cd "$_drp_tmp" && tar xzf src.tar.gz ) >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || {
        rm -rf "$_drp_tmp"; return 0; }
    _drp_src="$_drp_tmp/dash-server-${EXAKIT_DASH_SERVER_VERSION}/src/dash_server"
    [ -d "$_drp_src" ] || { rm -rf "$_drp_tmp"; return 0; }

    _drp_restored=0
    for _drp_rel in $( cd "$_drp_src" && find . -type f ! -name '*.py' | sed 's|^\./||' ); do
        [ -f "$_drp_site/$_drp_rel" ] && continue
        mkdir -p "$_drp_site/$(dirname "$_drp_rel")" 2>/dev/null || continue
        cp "$_drp_src/$_drp_rel" "$_drp_site/$_drp_rel" 2>/dev/null && \
            _drp_restored=$((_drp_restored + 1))
    done
    rm -rf "$_drp_tmp"
    if [ "$_drp_restored" -gt 0 ]; then
        info "Restored $_drp_restored data file(s) the release does not declare as package data (upstream packaging gap; the browser UI needs them)"
    fi
    return 0
}

# _dash_server_settle_port — decide which port THIS install will use, before a
# launcher or a boot entry bakes one in.
#
# A port the user named is honoured or refused: silently moving an explicit
# choice would be worse than saying it is taken. An unnamed one defaults to
# 5100 and steps up when something else already holds it, so an install does
# not fail over a port collision the kit can simply avoid. Our own running
# server is not a collision.
_dash_server_settle_port() {
    _dsp_foreign="$(_dash_server_port_foreign_desc || true)"
    [ -n "$_dsp_foreign" ] || return 0

    if [ "$_EXAKIT_DS_PORT_EXPLICIT" = "1" ]; then
        _dash_server_not_installed "port $EXAKIT_DASH_SERVER_PORT is held by another process ($_dsp_foreign) — pick a free one with EXAKIT_DASH_SERVER_PORT=<port>"
        return 1
    fi

    _dsp_taken="$EXAKIT_DASH_SERVER_PORT"
    _dsp_try=$((EXAKIT_DASH_SERVER_PORT + 1))
    _dsp_tries=0
    while [ "$_dsp_tries" -lt 20 ]; do
        EXAKIT_DASH_SERVER_PORT="$_dsp_try"
        if ! _dash_server_port_foreign_desc >/dev/null 2>&1; then
            warn "Port $_dsp_taken is held by another process ($_dsp_foreign)."
            info "dash-server will use port $EXAKIT_DASH_SERVER_PORT instead (recorded, so every command agrees)."
            return 0
        fi
        _dsp_try=$((_dsp_try + 1))
        _dsp_tries=$((_dsp_tries + 1))
    done
    EXAKIT_DASH_SERVER_PORT="$_dsp_taken"
    _dash_server_not_installed "no free port found between $_dsp_taken and $((_dsp_taken + 20)) — free one, or name one with EXAKIT_DASH_SERVER_PORT=<port>"
    return 1
}

# _dash_server_ensure_pip <uv> — make sure the venv can run `python -m pip`.
# dash-server installs each app's dependencies (including the built-in demo's)
# by shelling out to exactly that, and a bare uv venv has no pip — without
# this, every app build fails with "Dependency install failed before import
# smoke check". New venvs are created with --seed; this is the self-repair for
# venvs that predate the seed or were provided by the user.
# ⇄ twin: Confirm-DashServerPip in dash-server.ps1.
_dash_server_ensure_pip() {
    _dep_python="$(dash_server_venv_python)"
    [ -x "$_dep_python" ] || return 0
    ( "$_dep_python" -m pip --version && : ) >/dev/null 2>&1 && return 0
    info "Adding pip to the dash-server venv (app builds install their dependencies with it)"
    if ! run_logged "$1" pip install --python "$_dep_python" pip; then
        _dash_server_not_installed "pip could not be added to $EXAKIT_DASH_SERVER_VENV (dash-server app builds need it; see log)"
        return 1
    fi
    ( "$_dep_python" -m pip --version && : ) >/dev/null 2>&1 || {
        _dash_server_not_installed "pip was installed into $EXAKIT_DASH_SERVER_VENV but python -m pip still does not run (see log)"
        return 1
    }
    ok "pip added to the dash-server venv"
}

# _dash_server_credentials — "user<TAB>password_file" for the launcher's
# profile bootstrap. Prefers the kit's dedicated read-only MCP user (dashboards
# read, they do not write — same least-privilege posture as the MCP server);
# falls back to the runtime admin user only when no read-only user exists yet.
_dash_server_credentials() {
    if command -v mcp_credentials >/dev/null 2>&1; then
        mcp_credentials
        return 0
    fi
    printf '%s\t%s\n' "$(manifest_get runtime.user 2>/dev/null)" \
        "$(manifest_get runtime.password_file 2>/dev/null)"
}

# dash_server_write_launcher — generate $EXAKIT_BIN_DIR/dash-server. The
# wrapper execs the venv's console script with the kit's Exasol profile
# bootstrapped from the environment (DASH_SERVER_EXASOL_*, read fresh at RUN
# time — the password never lands in the wrapper, only the path of the
# credential file the kit already guards with mode 600). Every variable is a
# setdefault: anything the user exports themselves wins. Re-running the
# installer or `exakit update dash-server` regenerates the wrapper.
dash_server_write_launcher() {
    _dash_server_resolve_port
    _dsl_dsn="$(manifest_get runtime.dsn 2>/dev/null || true)"
    _dsl_creds="$(_dash_server_credentials)"
    _dsl_user="$(printf '%s' "$_dsl_creds" | cut -f1)"
    _dsl_pwfile="$(printf '%s' "$_dsl_creds" | cut -f2)"

    mkdir -p "$EXAKIT_BIN_DIR" || {
        _dash_server_not_installed "could not create $EXAKIT_BIN_DIR for the dash-server launcher"
        return 1
    }
    # $@ and the credential read expand at RUN time (quoted heredoc); the
    # paths and connection facts are baked in with a safe substitution below.
    cat > "$EXAKIT_DASH_SERVER_BIN" <<'EXAKIT_DS_EOF'
#!/bin/sh
# dash-server launcher — generated by the Exasol Personal Local Starter Kit.
# Starts dash-server from its kit-managed venv with the kit's local Exasol
# database bootstrapped as a connection profile (DASH_SERVER_EXASOL_*). Any of
# these variables you export yourself take precedence. Re-running
# `exakit update dash-server` regenerates this wrapper.
# THE PORT IS NEVER BAKED INTO THIS FILE. It used to be, while the kit
# recorded its own choice separately - two copies of one fact, which drifted:
# a launcher written when the port was 5102 kept probing 5102 while the kit
# passed --port 5100 and waited on it. The launcher said "already running:
# 5102", the kit said "did not answer on 5100", and `exakit status` called a
# live add-on stopped.
#
# So this resolves the port the same way the kit does, in the same order, and
# holds no authoritative copy of its own:
#   1. --port on this command line     (how the kit and the boot entry call it)
#   2. the kit's record in manifest.json  (a bare hand-run, and the tiebreaker)
#   3. 5100, the plain default          (no record to read)
# Step 2 is a scoped read, not a JSON parser: components.dash_server.port is
# the only "port" key the manifest carries, and the kit's writer keeps it one
# per line.
_ds_default_port=5100
_ds_port=""
_ds_seen=""
for _ds_arg in "$@"; do
    if [ "$_ds_seen" = "port" ]; then _ds_port="$_ds_arg"; _ds_seen=""; continue; fi
    case "$_ds_arg" in
        --port) _ds_seen="port" ;;
        --port=*) _ds_port="${_ds_arg#--port=}" ;;
    esac
done
if [ -z "$_ds_port" ]; then
    _ds_manifest="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}/manifest.json"
    if [ -r "$_ds_manifest" ]; then
        _ds_port="$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_ds_manifest" 2>/dev/null | head -1)"
    fi
fi
case "$_ds_port" in ''|*[!0-9]*) _ds_port="$_ds_default_port" ;; esac
# Already up? dash-server's consumption coordinator is single-process, so a
# second copy dies on a RuntimeError traceback that reads like a crash. It is
# not one - the first copy (often started at login by the boot entry) is
# serving. Say that plainly and stop.
_ds_holder=""
if command -v lsof >/dev/null 2>&1; then
    for _ds_pid in $(lsof -nP -iTCP:"$_ds_port" -sTCP:LISTEN -t 2>/dev/null | sort -u); do
        case "$(ps -o command= -p "$_ds_pid" 2>/dev/null)" in
            *"@VENVDIR@"*) _ds_holder="ours" ;;
            *) [ -n "$_ds_holder" ] || _ds_holder="pid $_ds_pid ($(ps -o comm= -p "$_ds_pid" 2>/dev/null | sed 's|.*/||'))" ;;
        esac
    done
elif command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$_ds_port/mcp" 2>/dev/null && _ds_holder="ours"
fi
if [ "$_ds_holder" = "ours" ]; then
    printf 'dash-server is already running: http://127.0.0.1:%s (MCP: /mcp)\n' "$_ds_port"
    printf 'State: exakit status   Logs: exakit logs dash-server -f   Stop: exakit stop\n'
    exit 0
elif [ -n "$_ds_holder" ]; then
    printf 'Port %s is held by another process (%s), so dash-server cannot start.\n' "$_ds_port" "$_ds_holder"
    printf 'Move it: EXAKIT_DASH_SERVER_PORT=<port> exakit update\n'
    exit 1
fi
: "${DASH_SERVER_INSTANCE_PATH:=@INSTANCE@}"
export DASH_SERVER_INSTANCE_PATH
if [ -n "@DSN@" ] && [ -z "${DASH_SERVER_EXASOL_DSN:-}" ]; then
    if [ -z "${EXA_PASSWORD:-}" ] && [ -r "@PWFILE@" ]; then
        EXA_PASSWORD="$(cat "@PWFILE@")"
        export EXA_PASSWORD
    fi
    if [ -n "${EXA_PASSWORD:-}" ]; then
        export DASH_SERVER_EXASOL_PROFILE_NAME="@PROFILE@"
        export DASH_SERVER_EXASOL_DSN="@DSN@"
        export DASH_SERVER_EXASOL_USER="@USER@"
        export DASH_SERVER_EXASOL_SECRET_ENV_VAR="EXA_PASSWORD"
        # The kit's local runtime speaks TLS with a self-signed certificate.
        export DASH_SERVER_EXASOL_TLS_VERIFY="${DASH_SERVER_EXASOL_TLS_VERIFY:-false}"
    fi
fi
# Bind where the kit says, not where dash-server defaults. Without these the
# server binds its own built-in default, so an install that stepped up past a
# busy 5100 starts on the busy port - or, if the upstream default host is not
# loopback, exposes an unauthenticated control plane on the LAN. Setdefaults,
# like DASH_SERVER_INSTANCE_PATH above: a user who exports their own still wins.
#
# $_ds_port, not a baked number: the pre-flight above and the bind below have to
# be the same port, and a second baked copy is a second thing to drift - which
# is precisely how the probe checked one port while the server served another.
: "${DASH_SERVER_HOST:=127.0.0.1}"
: "${DASH_SERVER_PORT:=$_ds_port}"
export DASH_SERVER_HOST DASH_SERVER_PORT
exec "@VENVBIN@" "$@"
EXAKIT_DS_EOF
    # sed with | as the delimiter: the substituted values are paths, DSNs and
    # user names that can contain / but never |.
    sed -i.exakit-bak \
        -e "s|@INSTANCE@|$EXAKIT_DASH_SERVER_HOME/instance|" \
        -e "s|@DSN@|$_dsl_dsn|g" \
        -e "s|@PWFILE@|$_dsl_pwfile|g" \
        -e "s|@PROFILE@|$EXAKIT_DASH_SERVER_PROFILE|" \
        -e "s|@USER@|$_dsl_user|" \
        -e "s|@PORT@|$EXAKIT_DASH_SERVER_PORT|g" \
        -e "s|@VENVDIR@|$EXAKIT_DASH_SERVER_VENV|g" \
        -e "s|@VENVBIN@|$EXAKIT_DASH_SERVER_VENV/bin/dash-server|" \
        "$EXAKIT_DASH_SERVER_BIN" && rm -f "$EXAKIT_DASH_SERVER_BIN.exakit-bak"
    chmod 755 "$EXAKIT_DASH_SERVER_BIN"
    push_rollback "rm -f \"$EXAKIT_DASH_SERVER_BIN\""
    ensure_path_hint "$EXAKIT_BIN_DIR"
    if [ -z "$_dsl_dsn" ]; then
        warn "No database DSN is recorded yet — dash-server starts without a bootstrapped Exasol profile until the kit install completes."
    fi
    ok "dash-server launcher written: $EXAKIT_DASH_SERVER_BIN"
}

# dash_server_validate — prove the package imports, then start the server
# briefly and check the MCP control plane answers over HTTP. Both halves are
# soft: a failed live check records validated=false and warns rather than
# failing the marketplace install — the add-on is retried by the update path.
dash_server_validate() {
    _dsv_python="$(dash_server_venv_python)"
    # Nothing to validate when the install did not get far enough: it is
    # soft-fail by design and has already explained itself.
    [ -x "$_dsv_python" ] || return 0
    if ! ( "$_dsv_python" -c 'import dash_server' && : ) >/dev/null 2>&1; then
        warn "dash-server is installed but cannot be imported from $EXAKIT_DASH_SERVER_VENV (see log). Recorded validated=false; retry with: exakit update"
        manifest_set components.dash_server.validated false
        return 0
    fi

    _dash_server_resolve_port
    _dsv_foreign="$(_dash_server_port_foreign_desc || true)"
    if [ -n "$_dsv_foreign" ]; then
        warn "Port $EXAKIT_DASH_SERVER_PORT is held by another process ($_dsv_foreign) — dash-server was not validated."
        info "Move it with: EXAKIT_DASH_SERVER_PORT=<port> exakit update"
        manifest_set components.dash_server.validated false
        return 0
    fi
    info "Validating dash-server (MCP control plane on port $EXAKIT_DASH_SERVER_PORT)"
    # Something already answering on the port IS a running dash-server as far
    # as this check can tell (the kit's own launcher is the likely reason);
    # starting a second instance just to probe would fail on the bind.
    if _dash_server_http_answers; then
        ok "dash-server control plane answers on port $EXAKIT_DASH_SERVER_PORT"
        # A server that was already running can predate this very install:
        # autostart brings one up early, and the package-data restore above
        # then lands in site-packages that the stale process never re-reads —
        # so its pages 500 on templates that ARE on disk. When that happens to
        # OUR OWN instance, one restart is the repair; warning the user to
        # re-run the command they just ran would re-probe the same stale
        # process forever. A foreign holder is left alone as always.
        if ! _dash_server_ui_answers && _dash_server_port_is_ours; then
            info "The running dash-server predates this install — restarting it to pick up the restored files"
            dash_server_stop >/dev/null 2>&1 || true
            dash_server_start >/dev/null 2>&1 || true
        fi
        _dash_server_check_ui
        manifest_set components.dash_server.validated true
        _dash_server_print_usage
        return 0
    fi

    # ITS OWN FILE, not the whole install log: the failure line below is read
    # back out of it, and an install log carries a hundred other commands'
    # output to mistake for this server's. Separate from dash-server.log so it
    # cannot collide with a server still holding that handle. Twin of $probeLog
    # in Test-DashServer.
    _dsv_log="$EXAKIT_LOG_DIR/dash-server-validate.log"
    mkdir -p "$EXAKIT_LOG_DIR" 2>/dev/null || true
    : > "$_dsv_log" 2>/dev/null || _dsv_log=""
    "$EXAKIT_DASH_SERVER_BIN" --host 127.0.0.1 --port "$EXAKIT_DASH_SERVER_PORT" \
        >> "${_dsv_log:-${EXAKIT_LOG_FILE:-/dev/null}}" 2>&1 &
    _dsv_pid=$!
    # Out of the job table right away, or bash announces "Terminated" over the
    # user-facing output when the probe server is killed below.
    disown 2>/dev/null || true
    _dsv_ok=0
    _dsv_waited=0
    while [ "$_dsv_waited" -lt 60 ]; do
        if _dash_server_http_answers; then
            _dsv_ok=1
            break
        fi
        kill -0 "$_dsv_pid" 2>/dev/null || break
        sleep 2
        _dsv_waited=$((_dsv_waited + 2))
    done
    # The browser page is probed HERE, while the probe server is still up.
    # Checking it after the kill below asked a dead port whether it renders,
    # so a perfectly good install was reported as "the dashboards page does
    # not render" on every fresh install — the page then worked the moment
    # the user opened it, because by then the real service had started.
    _dsv_ui=0
    if [ "$_dsv_ok" -eq 1 ] && _dash_server_ui_answers; then
        _dsv_ui=1
    fi

    # The launcher execs the real server, so the recorded pid IS the server;
    # the child sweep covers any worker it spawned. Bounded, mirrors mcp.sh.
    pkill -P "$_dsv_pid" 2>/dev/null
    kill "$_dsv_pid" 2>/dev/null
    sleep 1
    pkill -9 -P "$_dsv_pid" 2>/dev/null
    kill -9 "$_dsv_pid" 2>/dev/null
    wait "$_dsv_pid" 2>/dev/null || true

    if [ "$_dsv_ok" -eq 1 ]; then
        ok "dash-server control plane answers on port $EXAKIT_DASH_SERVER_PORT"
        _dash_server_report_ui "$_dsv_ui"
        manifest_set components.dash_server.validated true
        _dash_server_print_usage
    else
        _dsv_why="$(_dash_server_failure_reason "$_dsv_log")"
        if [ -n "$_dsv_why" ]; then
            _dsv_hint="$(_dash_server_missing_tool_hint "$_dsv_why")"
            if [ -n "$_dsv_hint" ]; then
                # The remedy that can actually work, instead of the one that
                # cannot: a retry does not put a missing command on the machine.
                warn "dash-server did not answer on port $EXAKIT_DASH_SERVER_PORT — $_dsv_why"
                info "$_dsv_hint"
            else
                warn "dash-server did not answer on port $EXAKIT_DASH_SERVER_PORT — $_dsv_why. Recorded validated=false; retry with: exakit update"
            fi
        else
            warn "dash-server did not answer on port $EXAKIT_DASH_SERVER_PORT within ${_dsv_waited}s. Recorded validated=false; retry with: exakit update"
        fi
        manifest_set components.dash_server.validated false
    fi
    return 0
}

# _dash_server_missing_tool <reason> - the NAME of a command the server could
# not find, or nothing.
#
# "RETRY WITH: EXAKIT UPDATE" CANNOT INSTALL GIT. dash-server shells out to git
# when it starts, and on a machine without it the start dies with
# FileNotFoundError: [Errno 2] No such file or directory: 'git'. The reason line
# said exactly that - and then offered a retry that would fail the same way for
# ever, because nothing about re-running the installer puts git on the machine.
# A missing command is the one failure whose remedy is obvious the moment the
# name is read, so it is read.
_dash_server_missing_tool() {
    printf '%s' "$1" | sed -n "s/.*No such file or directory: '\\([^']*\\)'.*/\\1/p" | head -1
}

# _dash_server_missing_tool_hint <reason> - one sentence naming the command to
# install, or nothing. Only for a tool that really is absent: the same
# FileNotFoundError can name a data file, and telling someone to apt-get
# install a path would be worse than saying nothing.
_dash_server_missing_tool_hint() {
    _dsmth_tool="$(_dash_server_missing_tool "$1")"
    [ -n "$_dsmth_tool" ] || return 0
    case "$_dsmth_tool" in */*) return 0 ;; esac
    command -v "$_dsmth_tool" >/dev/null 2>&1 && return 0
    printf "dash-server needs '%s' on PATH and it is not installed. Install it (Debian/Ubuntu: sudo apt-get install -y %s), then: exakit marketplace" \
        "$_dsmth_tool" "$_dsmth_tool"
}

# _dash_server_failure_reason <log> [log...] — the line from a start log that
# says WHY the server is not answering, ready to put on screen.
#
# "see the log" IS NOT A DIAGNOSIS. A failed start printed a port and a file
# path and stopped there, so the only way to learn what happened was to open a
# file in the middle of an install. The reason is one line; it belongs on
# screen. Twin of Get-DashServerFailureReason.
_dash_server_failure_reason() {
    _dsfr_lines=""
    for _dsfr_log in "$@"; do
        [ -n "$_dsfr_log" ] && [ -r "$_dsfr_log" ] || continue
        _dsfr_lines="$_dsfr_lines
$(tail -n 40 "$_dsfr_log" 2>/dev/null | grep -v '^[[:space:]]*$')"
    done
    [ -n "$(printf '%s' "$_dsfr_lines" | tr -d '[:space:]')" ] || return 0
    # A traceback says what went wrong on its LAST line, not its first, and the
    # frames between are noise here. Prefer the deepest error line; fall back to
    # whatever the server said last.
    _dsfr_reason="$(printf '%s\n' "$_dsfr_lines" | grep -E 'Error|Exception|error:|ERROR|Errno|refused|denied|in use|already running' | tail -1)"
    [ -n "$_dsfr_reason" ] || _dsfr_reason="$(printf '%s\n' "$_dsfr_lines" | tail -1)"
    _dsfr_reason="$(printf '%s' "$_dsfr_reason" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
    if [ "${#_dsfr_reason}" -gt 150 ]; then
        _dsfr_reason="$(printf '%s' "$_dsfr_reason" | cut -c1-147)..."
    fi
    printf '%s' "$_dsfr_reason"
}

# _dash_server_http_answers — one bounded probe of the control plane. Any HTTP
# status counts: /mcp answering 4xx to a bare GET still proves the server is up.
_dash_server_http_answers() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://127.0.0.1:$EXAKIT_DASH_SERVER_PORT/mcp" 2>/dev/null | grep -qE '^(200|3..|4..)'
}

# _dash_server_ui_answers — the page a HUMAN opens. Checked separately because
# the control plane can be perfectly healthy while the browser UI is broken:
# that is exactly what the missing-templates packaging gap looked like, and
# probing only /mcp reported the add-on as ready anyway.
_dash_server_ui_answers() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://127.0.0.1:$EXAKIT_DASH_SERVER_PORT/" 2>/dev/null | grep -qE '^(200|3..)'
}

# _dash_server_check_ui — the browser page, reported separately. A broken UI
# does not fail the install (the MCP control plane is what agents use) but it
# must never pass silently: that is how a 500 on every dashboard page reached a
# user while the kit said "ready".
_dash_server_check_ui() {
    if _dash_server_ui_answers; then
        _dash_server_report_ui 1
    else
        _dash_server_report_ui 0
    fi
    return 0
}

# _dash_server_report_ui <1|0> — say what the UI probe found and record it.
# Separate from the probe so the fresh-start path can probe while its server
# is alive and report after killing it.
_dash_server_report_ui() {
    if [ "${1:-0}" = "1" ]; then
        ok "Dashboards page answers: http://127.0.0.1:$EXAKIT_DASH_SERVER_PORT"
        manifest_set components.dash_server.ui_validated true
        return 0
    fi
    warn "The control plane is up, but the dashboards page at http://127.0.0.1:$EXAKIT_DASH_SERVER_PORT does not render (see: exakit logs dash-server)."
    warn "Agents can still drive it over MCP. Retry the repair with: exakit update"
    manifest_set components.dash_server.ui_validated false
    return 0
}

# The panel is the add-on's reference card, and a marketplace install is not
# where a reference card belongs: three of them in a row is thirty lines a
# reader has to scroll past to reach "installed". Under EXAKIT_QUIET_DETAIL the
# rows go to the logfile and the one fact worth keeping reaches the result line
# through <id>_summary; `exakit help <id>` has all of it, and more, any time.
_dash_server_print_usage() {
    if [ "${EXAKIT_QUIET_DETAIL:-0}" = 1 ]; then
        _exakit_log_file "DATA  dash-server: http://127.0.0.1:$EXAKIT_DASH_SERVER_PORT (mcp: /mcp)"
        return 0
    fi
    ui_panel_begin "dash-server"
    ui_panel_line "Start it        dash-server"
    ui_panel_line "Dashboards      http://127.0.0.1:$EXAKIT_DASH_SERVER_PORT"
    ui_panel_line "MCP endpoint    http://127.0.0.1:$EXAKIT_DASH_SERVER_PORT/mcp"
    ui_panel_line "Update          exakit update"
    ui_panel_end
}

# dash_server_summary — the one fact worth a place on the result line. Optional
# hook, resolved generically by _exakit_addon_fn like install/validate/start.
dash_server_summary() {
    _dash_server_resolve_port 2>/dev/null || true
    # 33 characters at a four-digit port. The cell truncates anything
    # longer, and its room is 33 in the PLAIN palette, whose tick is the
    # four-character "[ok]" rather than a one-character glyph.
    printf 'dashboards: http://127.0.0.1:%s\n' "$EXAKIT_DASH_SERVER_PORT"
}

# ---------------------------------------------------------------------------
# Service lifecycle
# ---------------------------------------------------------------------------
# dash-server is a long-running HTTP process, so the kit treats it like the
# database: start it, stop it, ask whether it is up, and bring it back after a
# reboot. The generic hooks (<id>_start / _stop / _status / _autostart_*) are
# what fold ANY add-on into `exakit start|stop|status` and the autostart
# registration — a future add-on defines them and needs no other wiring.

EXAKIT_DASH_SERVER_PIDFILE="${EXAKIT_DASH_SERVER_PIDFILE:-$EXAKIT_DASH_SERVER_HOME/dash-server.pid}"
EXAKIT_DASH_SERVER_LOG="${EXAKIT_DASH_SERVER_LOG:-$EXAKIT_LOG_DIR/dash-server.log}"

# dash_server_log_path — what `exakit logs dash-server` shows.
dash_server_log_path() {
    printf '%s\n' "$EXAKIT_DASH_SERVER_LOG"
}

# dash_server_status — running | stopped | not installed. The HTTP probe is the
# truth: the process may have been started by launchd, by the user in a
# terminal, or by exakit, and only one of those leaves a pidfile.
# dash_server_url — the one address everything about this add-on hangs off.
# A convention hook (_exakit_addon_fn <id> url): status --json surfaces it, so
# an agent finally has a JSON key for the URL instead of parsing the human
# screen or guessing the port.
dash_server_url() {
    _dash_server_resolve_port
    printf 'http://127.0.0.1:%s\n' "$EXAKIT_DASH_SERVER_PORT"
}

dash_server_status() {
    _dash_server_resolve_port
    if [ ! -x "$EXAKIT_DASH_SERVER_BIN" ]; then
        printf '%s\n' "not installed"
        return 0
    fi
    if _dash_server_running; then
        printf '%s\n' "running"
        return 0
    fi
    _dss_foreign="$(_dash_server_port_foreign_desc || true)"
    if [ -n "$_dss_foreign" ]; then
        printf 'stopped (port %s is held by another process: %s)\n' \
            "$EXAKIT_DASH_SERVER_PORT" "$_dss_foreign"
        return 0
    fi
    printf '%s\n' "stopped"
}

# _dash_server_pids — the kit-managed dash-server processes: the recorded pid
# when it is still alive, plus anything running out of this venv (which covers
# a launchd-started copy, whose pid the kit never recorded). The venv path is
# unique to this install, so this never matches an unrelated process.
_dash_server_pids() {
    _dsp_out=""
    if [ -f "$EXAKIT_DASH_SERVER_PIDFILE" ]; then
        _dsp_pid="$(cat "$EXAKIT_DASH_SERVER_PIDFILE" 2>/dev/null)"
        case "$_dsp_pid" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$_dsp_pid" 2>/dev/null && _dsp_out="$_dsp_pid" ;;
        esac
    fi
    if command -v pgrep >/dev/null 2>&1; then
        for _dsp_extra in $(pgrep -f "$EXAKIT_DASH_SERVER_VENV" 2>/dev/null); do
            case " $_dsp_out " in
                *" $_dsp_extra "*) ;;
                *) _dsp_out="${_dsp_out:+$_dsp_out }$_dsp_extra" ;;
            esac
        done
    fi
    printf '%s' "$_dsp_out"
}

# dash_server_start — bring it up in the background and wait until the control
# plane answers. Idempotent: an already-running server is reported, not
# duplicated (a second one would fail on the port anyway).
dash_server_start() {
    [ -x "$EXAKIT_DASH_SERVER_BIN" ] || {
        warn "dash-server is not installed — add it with: exakit marketplace"
        return 1
    }
    _dash_server_resolve_port
    if _dash_server_running; then
        ok "dash-server is already running (http://127.0.0.1:$EXAKIT_DASH_SERVER_PORT)"
        return 0
    fi
    _dst_foreign="$(_dash_server_port_foreign_desc || true)"
    if [ -n "$_dst_foreign" ]; then
        warn "Port $EXAKIT_DASH_SERVER_PORT is held by another process ($_dst_foreign), so dash-server cannot bind it."
        info "Move dash-server to a free port with: EXAKIT_DASH_SERVER_PORT=<port> exakit update"
        return 1
    fi
    mkdir -p "$EXAKIT_DASH_SERVER_HOME" "$EXAKIT_LOG_DIR" 2>/dev/null || true
    info "Starting dash-server on port $EXAKIT_DASH_SERVER_PORT"
    # nohup + disown: it must outlive this command, and bash must not announce
    # its death later in the user's terminal.
    nohup "$EXAKIT_DASH_SERVER_BIN" --host 127.0.0.1 --port "$EXAKIT_DASH_SERVER_PORT" \
        >> "$EXAKIT_DASH_SERVER_LOG" 2>&1 &
    _dss_pid=$!
    disown 2>/dev/null || true
    printf '%s\n' "$_dss_pid" > "$EXAKIT_DASH_SERVER_PIDFILE" 2>/dev/null || true
    _dss_waited=0
    while [ "$_dss_waited" -lt 60 ]; do
        if _dash_server_http_answers; then
            # RECORD WHAT ACTUALLY BOUND. The record is what `exakit status`,
            # the endpoint URL and the launcher's own fallback all read, so it
            # follows reality rather than the intention this run started with.
            manifest_set components.dash_server.port "$EXAKIT_DASH_SERVER_PORT" 2>/dev/null || true
            ok "dash-server is running: http://127.0.0.1:$EXAKIT_DASH_SERVER_PORT (MCP: /mcp)"
            return 0
        fi
        kill -0 "$_dss_pid" 2>/dev/null || break
        sleep 2
        _dss_waited=$((_dss_waited + 2))
    done
    _dss_why="$(_dash_server_failure_reason "$EXAKIT_DASH_SERVER_LOG")"
    if [ -n "$_dss_why" ]; then
        warn "dash-server did not answer on port $EXAKIT_DASH_SERVER_PORT — $_dss_why"
        _dss_hint="$(_dash_server_missing_tool_hint "$_dss_why")"
        [ -n "$_dss_hint" ] && info "$_dss_hint"
    else
        warn "dash-server did not answer on port $EXAKIT_DASH_SERVER_PORT within ${_dss_waited}s — see $(ui_tilde "$EXAKIT_DASH_SERVER_LOG")"
    fi
    return 1
}

# dash_server_stop — stop every kit-managed dash-server process, bounded.
dash_server_stop() {
    _dash_server_resolve_port
    _dst_pids="$(_dash_server_pids)"
    if [ -z "$_dst_pids" ] && ! _dash_server_http_answers; then
        ok "dash-server is already stopped"
        rm -f "$EXAKIT_DASH_SERVER_PIDFILE" 2>/dev/null || true
        return 0
    fi
    info "Stopping dash-server"
    for _dst_pid in $_dst_pids; do
        pkill -P "$_dst_pid" 2>/dev/null
        kill "$_dst_pid" 2>/dev/null
    done
    sleep 1
    for _dst_pid in $(_dash_server_pids); do
        pkill -9 -P "$_dst_pid" 2>/dev/null
        kill -9 "$_dst_pid" 2>/dev/null
    done
    rm -f "$EXAKIT_DASH_SERVER_PIDFILE" 2>/dev/null || true
    if _dash_server_http_answers; then
        warn "Something is still answering on port $EXAKIT_DASH_SERVER_PORT (a dash-server the kit did not start?)"
        return 1
    fi
    ok "dash-server stopped"
}

# dash_server_autostart_command — what the boot entry runs. The launcher
# already bootstraps the database profile, so this is simply it.
dash_server_autostart_command() {
    _dash_server_resolve_port
    # One argument per line - see _exakit_service_autostart_command.
    printf '%s\n--host\n127.0.0.1\n--port\n%s\n' "$EXAKIT_DASH_SERVER_BIN" "$EXAKIT_DASH_SERVER_PORT"
}

# dash_server_uninstall [dry] — remove what the dash-server install put on this
# machine: the venv, the launcher, the pid file and the manifest record. With
# "1" it only narrates the plan. Best-effort and idempotent; safe to run when
# nothing is installed.
#
# THE INSTANCE IS KEPT. $EXAKIT_DASH_SERVER_HOME/instance is the user's work -
# the GitOps repo of every dashboard an agent built, and their secrets - and
# removing the add-on used to rm -rf it while the dry run promised "nothing
# else". The scheduler keeps its schema and dbt keeps its projects for the same
# reason. A reinstall adopts the directory again (dash_server_install only
# mkdir -p's it), so the dashboards come back with the add-on. A full kit
# uninstall still removes the kit home, and says so.
dash_server_uninstall() {
    _dsu_dry="${1:-0}"
    if [ "$_dsu_dry" != "1" ]; then
        # A running server holds its port and would outlive its own files.
        dash_server_stop >/dev/null 2>&1 || true
    fi
    _dsu_instance="$EXAKIT_DASH_SERVER_HOME/instance"
    for _dsu_path in "$EXAKIT_DASH_SERVER_VENV" "$EXAKIT_DASH_SERVER_PIDFILE" "$EXAKIT_DASH_SERVER_BIN"; do
        [ -e "$_dsu_path" ] || continue
        if [ "$_dsu_dry" = "1" ]; then
            info "  will remove: $_dsu_path"
        else
            info "Removing $_dsu_path"
            rm -rf "$_dsu_path"
        fi
    done
    if [ -d "$_dsu_instance" ] && [ "${EXAKIT_UNINSTALL_FULL:-0}" = "1" ]; then
        # A full kit uninstall removes the kit home next, and the instance with
        # it. Say so here rather than claim it is kept.
        info "  your dashboards in $_dsu_instance go with the kit home"
    elif [ -d "$_dsu_instance" ]; then
        info "  keeping your dashboards: $_dsu_instance (reinstalling the add-on picks them up again; delete the folder yourself if you no longer want them)"
    elif [ "$_dsu_dry" != "1" ]; then
        rmdir "$EXAKIT_DASH_SERVER_HOME" 2>/dev/null || true
    fi
    if [ "$_dsu_dry" != "1" ]; then
        # Before the manifest block goes: an entry pointing at a port nothing
        # answers on is worse than no entry at all, because a client reports it
        # as a broken server every time it starts.
        if command -v mcp_unregister_server_entry >/dev/null 2>&1; then
            mcp_unregister_server_entry "dash-server" "dash-server" || true
        fi
        manifest_del components.dash_server
        manifest_del desired.dash_server
        ok_step "dash-server removed — reinstall any time with: exakit marketplace"
    fi
    return 0
}

# dash_server_update — install the advertised version into the venv. Doubles as
# the repair command after a failed marketplace install. Asked for explicitly,
# so a failure here IS a failure.
dash_server_update() {
    _dsu_available="$(exakit_component_available dash-server 2>/dev/null || true)"
    [ -n "$_dsu_available" ] || die "Could not resolve the advertised dash-server version."
    _dsu_current="$(dash_server_installed_version 2>/dev/null || true)"
    if [ -n "$_dsu_current" ] && [ "$_dsu_current" = "$_dsu_available" ]; then
        # Same version can still need repair: regenerate the launcher so a
        # DSN/credential change since the install is picked up.
        dash_server_write_launcher >/dev/null 2>&1 || true
        ok "dash-server is already current ($_dsu_current)"
        return 0
    fi
    info "Updating dash-server ${_dsu_current:-not installed} -> $_dsu_available"
    EXAKIT_DASH_SERVER_VERSION="$_dsu_available"
    EXAKIT_FORCE_COMPONENT_INSTALL=1
    export EXAKIT_DASH_SERVER_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
    if ! dash_server_install; then
        die "dash-server could not be installed — see the warning above and ${EXAKIT_LOG_FILE:-the log}."
    fi
    dash_server_validate || true
    manifest_set desired.dash_server "$EXAKIT_DASH_SERVER_VERSION"
    ok "dash-server updated; database data was not changed"
}
