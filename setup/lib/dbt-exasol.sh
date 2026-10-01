#!/usr/bin/env bash
# dbt-exasol.sh — dbt-exasol (the dbt adapter for Exasol): managed install +
# validation.
#
# A MARKETPLACE ADD-ON: never installed by the setup scripts. The user picks it
# from `exakit marketplace`; once installed it joins `exakit update` like every
# other component. Sourced by the exakit CLI after common.sh.
#
# dbt-exasol facts:
#   - The dbt adapter for Exasol (github.com/exasol/dbt-exasol), published to
#     PyPI as `dbt-exasol`. It pulls dbt-core in with it, so installing this
#     add-on is what puts dbt on the machine.
#   - A CLI, not a service: nothing listens, nothing starts at boot. That is why
#     this module defines no status/start/stop/autostart/log hooks — the generic
#     registry arms simply leave those surfaces out for an add-on that does not
#     run.
#   - PyPI is both the install source and the version authority, which is why
#     versions.json carries `package` and NO `repo` for it: the generic upstream
#     lookup prefers `repo`, and the GitHub tags are v-prefixed (v1.12.1) while
#     the PyPI versions are not (1.12.1).
#   - Nothing to checksum. A PyPI version is immutable — it can never be
#     re-uploaded — so `dbt-exasol==<version>` IS the pin, in the way a digest is
#     the pin for the add-ons that install a GitHub release asset (those can be
#     deleted and re-uploaded under the same tag; this cannot).
#   - Requires Python >=3.11,<3.15. The kit's managed interpreter
#     (EXAKIT_MANAGED_PYTHON_VERSION, 3.12) sits inside that range, so there is
#     no version gate here — if that constant ever moves outside it, the install
#     fails loudly at pip rather than silently producing a broken venv.
#
#   - venv:     $EXAKIT_HOME/dbt-exasol-venv
#   - profile:  $EXAKIT_HOME/dbt/profiles.yml  (NEVER ~/.dbt/profiles.yml)
#   - launcher: $EXAKIT_BIN_DIR/dbt-exasol
#
# Safe to re-run: an existing venv with the desired version installed is kept,
# and the profile and launcher are regenerated so a DSN or credential change
# since the install is picked up.

# The add-on's version constants live here, next to the code that uses them —
# the generic registry arms in common.sh find them by the derived name
# convention (EXAKIT_<ID>_VERSION[_FALLBACK]), and the versions-bump workflow
# keeps the fallback in lockstep with versions.json (COUPLED table).
EXAKIT_DBT_EXASOL_VERSION="${EXAKIT_DBT_EXASOL_VERSION:-}"
EXAKIT_DBT_EXASOL_VERSION_FALLBACK="${EXAKIT_DBT_EXASOL_VERSION_FALLBACK:-1.12.1}"
EXAKIT_DBT_EXASOL_PACKAGE="${EXAKIT_DBT_EXASOL_PACKAGE:-dbt-exasol}"
EXAKIT_DBT_EXASOL_VENV="${EXAKIT_DBT_EXASOL_VENV:-$EXAKIT_HOME/dbt-exasol-venv}"
EXAKIT_DBT_EXASOL_HOME="${EXAKIT_DBT_EXASOL_HOME:-$EXAKIT_HOME/dbt}"
EXAKIT_DBT_EXASOL_BIN="${EXAKIT_DBT_EXASOL_BIN:-$EXAKIT_BIN_DIR/dbt-exasol}"
# The profile name the generated profiles.yml declares, and the schema dbt
# builds into. dbt creates the schema on first run, so it need not exist yet.
EXAKIT_DBT_EXASOL_PROFILE="${EXAKIT_DBT_EXASOL_PROFILE:-exasol_starter_kit}"
EXAKIT_DBT_EXASOL_SCHEMA="${EXAKIT_DBT_EXASOL_SCHEMA:-DBT}"

dbt_exasol_venv_python() {
    printf '%s\n' "$EXAKIT_DBT_EXASOL_VENV/bin/python"
}

# dbt_exasol_venv_dbt — the dbt console script inside the kit's venv. NOT the
# launcher: this one has no credentials and no profiles dir bootstrapped, which
# is exactly what the validation probe wants (it supplies both itself).
dbt_exasol_venv_dbt() {
    printf '%s\n' "$EXAKIT_DBT_EXASOL_VENV/bin/dbt"
}

# dbt_exasol_package_version — what the VENV alone says, with no opinion on
# whether the add-on is usable yet. The installer asks this immediately after
# pip, before the profile and launcher exist; dbt_exasol_installed_version below
# is the stricter question every other caller wants.
# ⇄ twin: Get-DbtExasolPackageVersion in dbt-exasol.ps1.
dbt_exasol_package_version() {
    _dep_python="$(dbt_exasol_venv_python)"
    [ -x "$_dep_python" ] || return 1
    ( "$_dep_python" -c 'from importlib.metadata import version; print(version("dbt-exasol"))' && : ) 2>/dev/null
}

# dbt_exasol_installed_version — the manifest RECORD as well as the venv. The
# record is written at the END of a successful install, so an install that died
# earlier leaves a venv and nothing else and no longer reports a version for
# something no command can run. Both halves, because neither alone is evidence
# (dash_server_installed_version and json_tables_installed_version take the same
# line).
dbt_exasol_installed_version() {
    _dev_recorded="$(manifest_get components.dbt_exasol.version 2>/dev/null || true)"
    [ -n "$_dev_recorded" ] || return 1
    dbt_exasol_package_version
}

# _dbt_exasol_not_installed <reason> — report a soft failure and return 1.
# Marketplace add-ons follow the pyexasol contract: nothing here may end the
# caller's run; every failure is explained, recorded as validated=false, and
# handed back as a non-zero return so a re-run (or `exakit update dbt-exasol`)
# retries it.
_dbt_exasol_not_installed() {
    warn "dbt-exasol was not installed: $1"
    command -v exakit_explain_last_log_error >/dev/null 2>&1 && exakit_explain_last_log_error
    warn "Everything else in the kit is unaffected. Retry with: exakit update"
    command -v exakit_note_failure >/dev/null 2>&1 && exakit_note_failure "$1"
    manifest_set components.dbt_exasol.validated false
    return 1
}

# dbt_exasol_system_present — a dbt the user installed themselves counts as
# "already on this machine" only when it carries the EXASOL adapter. This is
# sharper than the generic probe on purpose: the generic one looks for the
# launcher's basename (dbt-exasol) on PATH, and would never see a plain `dbt`.
# Being sharper in the other direction would be worse — dbt-snowflake or
# dbt-postgres on PATH is a different tool that merely shares a command name,
# and treating it as "already present" would hide the marketplace row and leave
# the user no way to install the Exasol adapter at all.
dbt_exasol_system_present() {
    _dsp_path="$(command -v dbt 2>/dev/null || true)"
    if [ -n "$_dsp_path" ]; then
        case "$_dsp_path" in
            "$EXAKIT_DBT_EXASOL_VENV"/*|"$EXAKIT_HOME"/*) : ;;
            *)
                if ( "$_dsp_path" --version && : ) 2>/dev/null | grep -qi 'exasol'; then
                    return 0
                fi
                ;;
        esac
    fi
    # Only the ambient interpreter, never the kit's own venv: importing it there
    # is a KIT install, which is a different thing entirely.
    _dsp_python="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
    [ -n "$_dsp_python" ] || return 1
    case "$_dsp_python" in
        "$EXAKIT_DBT_EXASOL_VENV"/*|"$EXAKIT_HOME"/*) return 1 ;;
    esac
    ( "$_dsp_python" -c 'import dbt.adapters.exasol' && : ) >/dev/null 2>&1 || return 1
    return 0
}

# _dbt_exasol_credentials — "user<TAB>password_file" for the generated profile.
# The RUNTIME ADMIN user, deliberately not the kit's read-only mcp_readonly user
# that dash-server reuses: dbt's whole job is to CREATE tables and views, so a
# read-only grant would turn every `dbt run` into a permissions error.
_dbt_exasol_credentials() {
    printf '%s\t%s\n' "$(manifest_get runtime.user 2>/dev/null)" \
        "$(manifest_get runtime.password_file 2>/dev/null)"
}

# dbt_exasol_write_profile — generate $EXAKIT_HOME/dbt/profiles.yml.
#
# A KIT-OWNED directory, never ~/.dbt/profiles.yml. That file belongs to the
# user and routinely holds their other warehouses; merging a block into YAML
# somebody else maintains is the destructive edit this kit avoids everywhere
# else. The launcher points dbt here with DBT_PROFILES_DIR instead, as a
# setdefault, so a user who exports their own still wins.
#
# The password is NOT in this file: it names an environment variable that the
# launcher fills from the credential file at run time. The DBT_ENV_SECRET_
# prefix is dbt's own convention for values it scrubs from its logs and
# artifacts, which is why the variable is not called something shorter.
dbt_exasol_write_profile() {
    _dwp_dsn="$(manifest_get runtime.dsn 2>/dev/null || true)"
    _dwp_creds="$(_dbt_exasol_credentials)"
    _dwp_user="$(printf '%s' "$_dwp_creds" | cut -f1)"

    mkdir -p "$EXAKIT_DBT_EXASOL_HOME" || {
        _dbt_exasol_not_installed "could not create $EXAKIT_DBT_EXASOL_HOME for the dbt profile"
        return 1
    }
    cat > "$EXAKIT_DBT_EXASOL_HOME/profiles.yml" <<'EXAKIT_DBT_PROFILE_EOF'
# profiles.yml - generated by the Exasol Personal Local Starter Kit.
#
# Regenerated by `exakit update dbt-exasol`, so edits here do not survive.
# Your own ~/.dbt/profiles.yml is never read or written by the kit; the
# dbt-exasol launcher points dbt at THIS directory with DBT_PROFILES_DIR,
# and exporting your own DBT_PROFILES_DIR overrides that.
#
# The password is not stored here. The launcher reads it from the kit's
# credential file at run time into DBT_ENV_SECRET_EXASOL_PASSWORD, a name
# dbt scrubs from its own logs and artifacts.
@PROFILE@:
  target: dev
  outputs:
    dev:
      type: exasol
      threads: 1
      dsn: @DSN@
      user: @USER@
      password: "{{ env_var('DBT_ENV_SECRET_EXASOL_PASSWORD') }}"
      # Required by dbt-core as a profile field; Exasol has no multi-database
      # concept, so the value is not used for anything.
      dbname: DB
      schema: @SCHEMA@
      encryption: true
      # The kit's local runtime speaks TLS with a self-signed certificate.
      validate_server_certificate: false
EXAKIT_DBT_PROFILE_EOF
    # sed with | as the delimiter: the substituted values are DSNs, user names
    # and identifiers that can contain / but never |.
    sed -i.exakit-bak \
        -e "s|@PROFILE@|$EXAKIT_DBT_EXASOL_PROFILE|" \
        -e "s|@DSN@|$_dwp_dsn|" \
        -e "s|@USER@|$_dwp_user|" \
        -e "s|@SCHEMA@|$EXAKIT_DBT_EXASOL_SCHEMA|" \
        "$EXAKIT_DBT_EXASOL_HOME/profiles.yml" && \
        rm -f "$EXAKIT_DBT_EXASOL_HOME/profiles.yml.exakit-bak"
    # No secret in it, but it names the credential file and the admin user, so
    # it is not world-readable either.
    chmod 600 "$EXAKIT_DBT_EXASOL_HOME/profiles.yml" 2>/dev/null || true
    push_rollback "rm -f \"$EXAKIT_DBT_EXASOL_HOME/profiles.yml\""
    if [ -z "$_dwp_dsn" ]; then
        warn "No database DSN is recorded yet — the dbt profile has no address until the kit install completes."
    fi
    return 0
}

# dbt_exasol_write_launcher — generate $EXAKIT_BIN_DIR/dbt-exasol.
#
# Named dbt-exasol, NOT dbt. Shadowing `dbt` on PATH would hijack a
# dbt-snowflake or dbt-postgres the user already relies on, and the kit does not
# get to take over a command name it did not create.
dbt_exasol_write_launcher() {
    _dwl_creds="$(_dbt_exasol_credentials)"
    _dwl_pwfile="$(printf '%s' "$_dwl_creds" | cut -f2)"

    mkdir -p "$EXAKIT_BIN_DIR" || {
        _dbt_exasol_not_installed "could not create $EXAKIT_BIN_DIR for the dbt-exasol launcher"
        return 1
    }
    # $@ and the credential read expand at RUN time (quoted heredoc); the paths
    # are baked in with a safe substitution below.
    cat > "$EXAKIT_DBT_EXASOL_BIN" <<'EXAKIT_DBT_LAUNCHER_EOF'
#!/bin/sh
# dbt-exasol launcher - generated by the Exasol Personal Local Starter Kit.
# Runs dbt from its kit-managed venv against the kit's local Exasol database.
# Every variable below is a setdefault: anything you export yourself wins.
# Re-running `exakit update dbt-exasol` regenerates this wrapper.
#
# Usage is dbt's own, with this name in front of it:
#   dbt-exasol debug     dbt-exasol run     dbt-exasol test
# It is deliberately not called `dbt`: a dbt you installed for another
# warehouse keeps that name.
if [ -z "${DBT_ENV_SECRET_EXASOL_PASSWORD:-}" ] && [ -r "@PWFILE@" ]; then
    DBT_ENV_SECRET_EXASOL_PASSWORD="$(cat "@PWFILE@")"
    export DBT_ENV_SECRET_EXASOL_PASSWORD
fi
: "${DBT_PROFILES_DIR:=@PROFILESDIR@}"
export DBT_PROFILES_DIR
exec "@VENVBIN@" "$@"
EXAKIT_DBT_LAUNCHER_EOF
    sed -i.exakit-bak \
        -e "s|@PWFILE@|$_dwl_pwfile|g" \
        -e "s|@PROFILESDIR@|$EXAKIT_DBT_EXASOL_HOME|" \
        -e "s|@VENVBIN@|$(dbt_exasol_venv_dbt)|" \
        "$EXAKIT_DBT_EXASOL_BIN" && rm -f "$EXAKIT_DBT_EXASOL_BIN.exakit-bak"
    chmod 755 "$EXAKIT_DBT_EXASOL_BIN"
    push_rollback "rm -f \"$EXAKIT_DBT_EXASOL_BIN\""
    ensure_path_hint "$EXAKIT_BIN_DIR"
    ok "dbt-exasol launcher written: $EXAKIT_DBT_EXASOL_BIN"
    return 0
}

# _dbt_exasol_db_reachable — is there a database to connect to at all? A cheap
# TCP probe on the recorded DSN, two seconds, no driver and no credentials.
#
# This runs BEFORE the real connection check rather than letting `dbt debug`
# discover a stopped database by timing out: the driver's own timeout would hang
# a marketplace install for as long as it takes, and a hang during an install is
# precisely the "something is wrong" feeling a stopped database does not deserve
# to cause.
_dbt_exasol_db_reachable() {
    _der_dsn="$(manifest_get runtime.dsn 2>/dev/null || true)"
    [ -n "$_der_dsn" ] || return 1
    _der_python="$(dbt_exasol_venv_python)"
    [ -x "$_der_python" ] || return 1
    ( "$_der_python" -c '
import socket, sys
host, sep, port = sys.argv[1].rpartition(":")
if not sep or not port.isdigit():
    sys.exit(1)
try:
    socket.create_connection((host or "127.0.0.1", int(port)), 2).close()
except Exception:
    sys.exit(1)
' "$_der_dsn" && : ) >/dev/null 2>&1
}

# _dbt_exasol_debug_ok — the real thing: scaffold a throwaway dbt project in a
# temp directory and let `dbt debug` open a connection with the generated
# profile. Non-destructive — dbt debug connects and tests, it creates no schema
# and no tables. Everything it prints goes to the log, not to the user.
_dbt_exasol_debug_ok() {
    _ddo_dbt="$(dbt_exasol_venv_dbt)"
    [ -x "$_ddo_dbt" ] || return 1
    _ddo_creds="$(_dbt_exasol_credentials)"
    _ddo_pwfile="$(printf '%s' "$_ddo_creds" | cut -f2)"
    [ -n "$_ddo_pwfile" ] && [ -r "$_ddo_pwfile" ] || return 1

    _ddo_tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-dbt-probe.XXXXXX")" || return 1
    cat > "$_ddo_tmp/dbt_project.yml" <<EXAKIT_DBT_PROBE_EOF
name: exakit_probe
version: "1.0.0"
config-version: 2
profile: $EXAKIT_DBT_EXASOL_PROFILE
EXAKIT_DBT_PROBE_EOF

    # The password exists only in this subshell's environment: never a file,
    # never an argument, and never the log (dbt scrubs DBT_ENV_SECRET_*).
    (
        cd "$_ddo_tmp" || exit 1
        DBT_ENV_SECRET_EXASOL_PASSWORD="$(cat "$_ddo_pwfile")"
        export DBT_ENV_SECRET_EXASOL_PASSWORD
        DBT_PROFILES_DIR="$EXAKIT_DBT_EXASOL_HOME"
        export DBT_PROFILES_DIR
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
        exakit_run_bounded 60 "$_ddo_dbt" debug --connection
    ) >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
    _ddo_rc=$?
    rm -rf "$_ddo_tmp"
    return $_ddo_rc
}

# dbt_exasol_validate — prove the adapter imports, then prove dbt can actually
# reach the database.
#
# The two-step shape is INTERNAL. From the marketplace the user chose a row and
# pressed Enter; the only thing they asked is whether dbt-exasol is on the
# machine. A stopped database is not a broken install, so it produces no warning
# and no question — the reachability probe decides which check runs, and only a
# database that IS reachable can produce a failure.
#
# What differs between the two paths is the RECORD, not the output:
# validated_by is `connection` when a connection was really opened and `import`
# when only the install was proved. Writing "connection" for a run that never
# connected would make `exakit doctor` report a check it never made, and it is
# what lets the next `exakit update dbt-exasol` finish the job once the database
# is up.
#
# Soft throughout: a marketplace install is never failed by this.
dbt_exasol_validate() {
    _dev_python="$(dbt_exasol_venv_python)"
    # Nothing to validate when the install did not get far enough: it is
    # soft-fail by design and has already explained itself.
    [ -x "$_dev_python" ] || return 0
    if ! ( "$_dev_python" -c 'import dbt.adapters.exasol' && : ) >/dev/null 2>&1; then
        warn "dbt-exasol is installed but the adapter cannot be imported from $EXAKIT_DBT_EXASOL_VENV (see log). Recorded validated=false; retry with: exakit update"
        manifest_set components.dbt_exasol.validated false
        return 0
    fi

    if _dbt_exasol_db_reachable; then
        info "Validating dbt-exasol against the local database"
        if _dbt_exasol_debug_ok; then
            manifest_set components.dbt_exasol.validated true
            manifest_set components.dbt_exasol.validated_by connection
            ok "dbt-exasol connects to the database (profile: $EXAKIT_DBT_EXASOL_PROFILE)"
            return 0
        fi
        # The database answered and dbt still could not use it. That is a real
        # defect and the one case here that says so out loud.
        warn "dbt-exasol is installed, but dbt could not connect to the database (see log). Retry with: exakit update dbt-exasol"
        manifest_set components.dbt_exasol.validated false
        manifest_set components.dbt_exasol.validated_by connection
        return 0
    fi

    # No database to reach, so the connection half cannot be judged. The install
    # itself is proven, which is what was asked for — so this is a success, and
    # a silent one. The install's own `ok` line is the whole story the user
    # needs; only the record below remembers what was not checked.
    manifest_set components.dbt_exasol.validated true
    manifest_set components.dbt_exasol.validated_by import
    return 0
}

dbt_exasol_install() {
    # The marketplace path runs from the exakit CLI, where the installer's
    # exakit_resolve_install_versions has not run — resolve the advertised
    # version here (env override -> policy -> versions.json -> fallback).
    if [ -z "${EXAKIT_DBT_EXASOL_VERSION:-}" ]; then
        EXAKIT_DBT_EXASOL_VERSION="$(exakit_component_available dbt-exasol 2>/dev/null || true)"
        [ -n "$EXAKIT_DBT_EXASOL_VERSION" ] || EXAKIT_DBT_EXASOL_VERSION="$EXAKIT_DBT_EXASOL_VERSION_FALLBACK"
        export EXAKIT_DBT_EXASOL_VERSION
    fi

    _dei_uv=""
    if command -v uv >/dev/null 2>&1; then
        _dei_uv="uv"
    elif exakit_ensure_uv && [ -x "${EXAKIT_UV_BIN:-}" ]; then
        _dei_uv="$EXAKIT_UV_BIN"
    else
        _dbt_exasol_not_installed "uv (the Python tool runner) is not available — install it from https://docs.astral.sh/uv/ and re-run"
        return 1
    fi

    _dei_current="$(dbt_exasol_package_version || true)"
    if [ -n "$_dei_current" ] && [ "$_dei_current" = "$EXAKIT_DBT_EXASOL_VERSION" ] && \
       [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ]; then
        ok "dbt-exasol $_dei_current already installed: $EXAKIT_DBT_EXASOL_VENV"
    else
        EXAKIT_ACTIVE_LABEL="Installing dbt-exasol $EXAKIT_DBT_EXASOL_VERSION"
        info "Installing dbt-exasol $EXAKIT_DBT_EXASOL_VERSION (the dbt adapter for Exasol; dbt-core comes with it)"
        if [ ! -x "$(dbt_exasol_venv_python)" ]; then
            if ! run_logged "$_dei_uv" venv --python "$EXAKIT_MANAGED_PYTHON_VERSION" "$EXAKIT_DBT_EXASOL_VENV"; then
                _dbt_exasol_not_installed "the virtual environment at $EXAKIT_DBT_EXASOL_VENV could not be created (see log)"
                return 1
            fi
            push_rollback "rm -rf '$EXAKIT_DBT_EXASOL_VENV'"
        fi
        # Version-pinned from PyPI over TLS. uv resolves dbt-core and the rest
        # of the tree the same way every other Python component here does.
        if ! run_logged "$_dei_uv" pip install --python "$(dbt_exasol_venv_python)" \
                "${EXAKIT_DBT_EXASOL_PACKAGE}==${EXAKIT_DBT_EXASOL_VERSION}"; then
            _dbt_exasol_not_installed "installing ${EXAKIT_DBT_EXASOL_PACKAGE}==${EXAKIT_DBT_EXASOL_VERSION} from PyPI failed (see log)"
            return 1
        fi
        # The install is not done until the venv can answer for the version: a
        # resolution that half-succeeded would otherwise be reported as
        # installed and only fail at the first dbt command.
        _dei_now="$(dbt_exasol_package_version || true)"
        if [ -z "$_dei_now" ]; then
            _dbt_exasol_not_installed "the venv cannot report a dbt-exasol version after the install (see log)"
            return 1
        fi
        ok "dbt-exasol installed: $EXAKIT_DBT_EXASOL_VENV"
    fi

    dbt_exasol_write_profile || return 1
    dbt_exasol_write_launcher || return 1

    manifest_set components.dbt_exasol.version "$EXAKIT_DBT_EXASOL_VERSION"
    manifest_set components.dbt_exasol.venv "$EXAKIT_DBT_EXASOL_VENV"
    manifest_set components.dbt_exasol.python "$(dbt_exasol_venv_python)"
    manifest_set components.dbt_exasol.command "$EXAKIT_DBT_EXASOL_BIN"
    manifest_set components.dbt_exasol.profiles_dir "$EXAKIT_DBT_EXASOL_HOME"
    manifest_set components.dbt_exasol.profile "$EXAKIT_DBT_EXASOL_PROFILE"
}

# dbt_exasol_update — install the advertised version into the venv. Doubles as
# the repair command after a failed marketplace install. Asked for explicitly,
# so a failure here IS a failure.
dbt_exasol_update() {
    _deu_available="$(exakit_component_available dbt-exasol 2>/dev/null || true)"
    [ -n "$_deu_available" ] || die "Could not resolve the advertised dbt-exasol version."
    _deu_current="$(dbt_exasol_installed_version 2>/dev/null || true)"
    if [ -n "$_deu_current" ] && [ "$_deu_current" = "$_deu_available" ]; then
        # Same version can still need repair: regenerate the profile and the
        # launcher so a DSN or credential change since the install is picked up,
        # then re-run validation, which is how a check that fell back to the
        # import probe (database was down) finally gets its connection proved.
        dbt_exasol_write_profile >/dev/null 2>&1 || true
        dbt_exasol_write_launcher >/dev/null 2>&1 || true
        dbt_exasol_validate || true
        ok "dbt-exasol is already current ($_deu_current)"
        return 0
    fi
    info "Updating dbt-exasol ${_deu_current:-not installed} -> $_deu_available"
    EXAKIT_DBT_EXASOL_VERSION="$_deu_available"
    EXAKIT_FORCE_COMPONENT_INSTALL=1
    export EXAKIT_DBT_EXASOL_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
    if ! dbt_exasol_install; then
        die "dbt-exasol could not be installed — see the warning above and ${EXAKIT_LOG_FILE:-the log}."
    fi
    dbt_exasol_validate || true
    manifest_set desired.dbt_exasol "$EXAKIT_DBT_EXASOL_VERSION"
    ok "dbt-exasol updated; database data was not changed"
}

# dbt_exasol_summary — the one fact worth a place on the result line. Optional
# hook, resolved generically by _exakit_addon_fn like install/validate.
dbt_exasol_summary() {
    # 30 characters: the finished cell truncates at 33 in the plain palette.
    printf 'build SQL models: dbt-exasol\n'
}

# dbt_exasol_uninstall — remove what the install put on this machine (with "1":
# narrate the plan only). This one hook folds the add-on into the selectable
# `exakit uninstall` menu AND the full teardown.
#
# The venv and the launcher are wholly ours and go. The profile directory is
# NOT: only the generated profiles.yml is removed, and the directory itself only
# if nothing else is in it. Anyone who kept a dbt project under it would
# otherwise lose their work to a command that promised to remove an adapter.
dbt_exasol_uninstall() {
    _deu_dry="${1:-0}"
    for _deu_path in "$EXAKIT_DBT_EXASOL_VENV" "$EXAKIT_DBT_EXASOL_BIN"; do
        [ -e "$_deu_path" ] || continue
        if [ "$_deu_dry" = "1" ]; then
            info "  will remove: $_deu_path"
        else
            info "Removing $_deu_path"
            rm -rf "$_deu_path"
        fi
    done
    if [ -e "$EXAKIT_DBT_EXASOL_HOME/profiles.yml" ]; then
        if [ "$_deu_dry" = "1" ]; then
            info "  will remove: $EXAKIT_DBT_EXASOL_HOME/profiles.yml (anything else in that folder is left alone)"
        else
            info "Removing $EXAKIT_DBT_EXASOL_HOME/profiles.yml"
            rm -f "$EXAKIT_DBT_EXASOL_HOME/profiles.yml"
        fi
    fi
    if [ "$_deu_dry" != "1" ]; then
        # Fails harmlessly, and on purpose, when the user kept something there.
        rmdir "$EXAKIT_DBT_EXASOL_HOME" 2>/dev/null || true
        manifest_del components.dbt_exasol
        manifest_del desired.dbt_exasol
        ok_step "dbt-exasol removed — reinstall any time with: exakit marketplace"
    fi
    return 0
}
