#!/usr/bin/env bash
# udf-devkit.sh — udf-devkit (Python UDFs on the local database): managed
# install + validation + the `exakit udf-setup | udf-use | udf-build | udf-file`
# commands.
#
# A MARKETPLACE ADD-ON: never installed by the setup scripts. Sourced by the
# exakit CLI after common.sh.
#
# udf-devkit facts:
#   - A local Exasol Personal deployment runs a Python UDF only on a script
#     language container. The launcher installs containers itself (`exasol slc
#     install`, `exasol slc custom install --source`, launcher 2.3.0 or later);
#     this add-on chooses which, and proves each with a SMOKE UDF that reports
#     Python and every declared package's version.
#   - EVERY container install restarts the database. So each one is confirmed
#     (--yes, or a run with no terminal, answers), the running add-on services
#     are stopped first and started again once the database answers.
#   - BucketFS has no upload service on a local deployment: it is a folder
#     inside the deployment directory, read by UDFs under /buckets.
#     `exakit udf-file` copies a file there and names the path a UDF reads.
#   - `exakit udf-build requirements.txt` builds a container with the notebook
#     add-on's SLC tooling (it needs that add-on and a running Docker engine).
#   - Nothing of its own to download until a prebuilt container is published
#     (versions.json components.udf-devkit); the version is the kit's.
#   - The rules and the database steps are setup/udf/udf_tool.py, shared with
#     the PowerShell twin; it connects as the kit's admin user through the
#     pyexasol venv, the password read from its file by the child.
#
#   - build workspace: $EXAKIT_HOME/udf-devkit/build

EXAKIT_UDF_DEVKIT_VERSION="${EXAKIT_UDF_DEVKIT_VERSION:-}"
EXAKIT_UDF_DEVKIT_VERSION_FALLBACK="${EXAKIT_UDF_DEVKIT_VERSION_FALLBACK:-0.1.0}"
EXAKIT_UDF_DEVKIT_HOME="${EXAKIT_UDF_DEVKIT_HOME:-$EXAKIT_HOME/udf-devkit}"
EXAKIT_UDF_MIN_LAUNCHER="2.3.0"
EXAKIT_UDF_OFFICIAL_ALIAS="PYTHON3"
EXAKIT_UDF_DEFAULT_ALIAS="PYTHON3_ML"
EXAKIT_UDF_BUILD_ALIAS="PYTHON3_CUSTOM"
EXAKIT_UDF_LANGUAGE="python"
EXAKIT_UDF_SCHEMA="EXAKIT_UDF"
# The prebuilt container's packages (exakit udf-use default): unused until one is published.
# shellcheck disable=SC2034
EXAKIT_UDF_DEFAULT_PACKAGES="numpy pandas scikit-learn"
EXAKIT_UDF_INSTALL_TIMEOUT="${EXAKIT_UDF_INSTALL_TIMEOUT:-3600}"
# BucketFS of a local deployment: a folder inside the deployment directory,
# mounted at /buckets in the database.
EXAKIT_UDF_BUCKETFS_DIR="local/runtime/exa/bucketfs"
EXAKIT_UDF_BUCKETFS_SERVICE="bfsdefault"
EXAKIT_UDF_BUCKETFS_BUCKET="default"
EXAKIT_UDF_BUCKETFS_ROOT="/buckets"
EXAKIT_UDF_BUILD_FLAVOR="template-Exasol-all-python-3.12"
EXAKIT_UDF_BUILD_NAME="kit_custom"
EXAKIT_UDF_BUILD_MIN_FREE_GB=25

udf_devkit_latest() {
    _udl="$(exakit_versions_value components.udf-devkit.version 2>/dev/null || true)"
    [ -n "$_udl" ] || _udl="$EXAKIT_UDF_DEVKIT_VERSION_FALLBACK"
    printf '%s\n' "$_udl"
}

# udf_devkit_installed_version — the record: the add-on has nothing of its own
# on disk until a build.
udf_devkit_installed_version() {
    manifest_get components.udf_devkit.version 2>/dev/null
}

# _udf_tool <command> [args] — setup/udf/udf_tool.py with the pyexasol venv's
# Python (it has pyexasol for the database steps), connected as the kit's admin
# user; the password is read from its file by the child.
_udf_tool() {
    _ut_python="$(pyexasol_venv_python 2>/dev/null)"
    [ -x "$_ut_python" ] || _ut_python="$(command -v python3 || true)"
    [ -n "$_ut_python" ] || { warn "No Python to run the UDF helper - repair with: exakit update pyexasol"; return 2; }
    EXAKIT_PYX_DSN="$(manifest_get runtime.dsn 2>/dev/null || true)" \
    EXAKIT_PYX_USER="$(manifest_get runtime.user 2>/dev/null || echo sys)" \
    EXAKIT_PYX_PWFILE="$(manifest_get runtime.password_file 2>/dev/null || true)" \
        "$_ut_python" "$(exakit_repo_root)/setup/udf/udf_tool.py" "$@"
}

# _udf_slc <args> — the launcher's container commands for this deployment.
_udf_slc() {
    "$(personal_cli)" slc "$@" --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR"
}

# udf_devkit_require_launcher — refuse unless the launcher can install containers.
udf_devkit_require_launcher() {
    _url_v="$(personal_launcher_version 2>/dev/null || true)"
    _udf_tool atleast "${_url_v:-0}" "$EXAKIT_UDF_MIN_LAUNCHER" && return 0
    warn "The UDF dev kit needs Exasol launcher $EXAKIT_UDF_MIN_LAUNCHER or later; this machine has ${_url_v:-none}. Update it with: exakit update personal"
    return 1
}

# udf_devkit_installed_aliases — the aliases of the installed containers.
udf_devkit_installed_aliases() {
    _udf_slc list --json 2>>"${EXAKIT_LOG_FILE:-/dev/null}" | _udf_tool aliases
}

# udf_devkit_smoke <alias> [package ...] — create and run the smoke UDF; prints
# what it found; 1 when a declared package is missing or the UDF did not run.
udf_devkit_smoke() {
    _us_alias="$1"; shift
    _us_out="$(_udf_tool smoke "$_us_alias" "$EXAKIT_UDF_SCHEMA" "$@" 2>"$EXAKIT_HOME/.udf-smoke.err")"
    _us_rc=$?
    _us_err="$(tail -1 "$EXAKIT_HOME/.udf-smoke.err" 2>/dev/null)"; rm -f "$EXAKIT_HOME/.udf-smoke.err"
    if [ "$_us_rc" -ne 0 ]; then
        warn "The smoke UDF on $_us_alias did not pass: ${_us_err:-no output}"
        return 1
    fi
    ok "Python UDFs run on $_us_alias (Python $(printf '%s\n' "$_us_out" | sed -n 's/^python //p'))"
    printf '%s\n' "$_us_out" | grep -v '^python ' | while read -r _us_name _us_version; do
        printf '      %-24s %s\n' "$_us_name" "$_us_version"
    done
    info "Use it in SQL: CREATE OR REPLACE $_us_alias SCALAR SCRIPT ..."
    manifest_set components.udf_devkit.validated true
    return 0
}

# _udf_with_restart <what> <command ...> — confirm, stop the running add-on
# services, run the install, wait for the database, start the services again.
_udf_with_restart() {
    _uwr_what="$1"; shift
    if [ "${_UDF_YES:-0}" != 1 ] && ! confirm "$_uwr_what restarts the database (running add-ons are stopped and started again). Continue?" y; then
        info "$_uwr_what was not started; nothing changed."
        return 5
    fi
    _uwr_running=""
    for _uwr_id in $(exakit_service_ids); do
        [ "$_uwr_id" = database ] && continue
        [ "$(exakit_service_status "$_uwr_id" 2>/dev/null)" = running ] || continue
        exakit_service_stop "$_uwr_id" >/dev/null 2>&1 && _uwr_running="$_uwr_running $_uwr_id"
    done
    EXAKIT_ACTIVE_LABEL="$_uwr_what"
    run_logged "$@"
    _uwr_rc=$?
    info "Waiting for the database to answer after the restart"
    personal_wait_ready
    for _uwr_id in $_uwr_running; do
        exakit_service_start "$_uwr_id" >/dev/null 2>&1 || warn "$_uwr_id did not start again - start it with: exakit start $_uwr_id"
    done
    return $_uwr_rc
}

# udf_devkit_setup_container [force] — the official container when it is
# missing (or forced), then the smoke UDF.
udf_devkit_setup_container() {
    exakit_db_reachable || { warn "The database is not running. Start it with: exakit start"; return 1; }
    udf_devkit_require_launcher || return 1
    if [ "${1:-0}" = 1 ] || ! udf_devkit_installed_aliases | grep -qx "$EXAKIT_UDF_OFFICIAL_ALIAS"; then
        _udf_with_restart "Installing the official $EXAKIT_UDF_OFFICIAL_ALIAS container" \
            _udf_slc install "$EXAKIT_UDF_OFFICIAL_ALIAS" --auto-approve || {
            warn "The launcher could not install the $EXAKIT_UDF_OFFICIAL_ALIAS container (see the log)."
            return 1
        }
    else
        ok "The official $EXAKIT_UDF_OFFICIAL_ALIAS container is already installed"
    fi
    udf_devkit_smoke "$EXAKIT_UDF_OFFICIAL_ALIAS"
}

udf_devkit_install() {
    [ -n "${EXAKIT_UDF_DEVKIT_VERSION:-}" ] || EXAKIT_UDF_DEVKIT_VERSION="$(udf_devkit_latest)"
    if ! udf_devkit_require_launcher; then
        command -v exakit_note_failure >/dev/null 2>&1 && exakit_note_failure "the Exasol launcher is older than $EXAKIT_UDF_MIN_LAUNCHER"
        return 1
    fi
    manifest_set components.udf_devkit.version "$EXAKIT_UDF_DEVKIT_VERSION"
    manifest_set components.udf_devkit.schema "$EXAKIT_UDF_SCHEMA"
    # The official container is part of the install; with no database up, it is
    # the first thing `exakit udf-setup` does.
    if exakit_db_reachable; then
        _UDF_YES=1 udf_devkit_setup_container 0 || warn "Python UDFs are not set up yet - run: exakit udf-setup"
    else
        info "Start the database, then set up Python UDFs with: exakit udf-setup"
    fi
    return 0
}

udf_devkit_validate() {
    exakit_db_reachable || return 0
    if udf_devkit_installed_aliases | grep -qx "$EXAKIT_UDF_OFFICIAL_ALIAS"; then
        udf_devkit_smoke "$EXAKIT_UDF_OFFICIAL_ALIAS" >/dev/null 2>&1 || manifest_set components.udf_devkit.validated false
    else
        manifest_set components.udf_devkit.validated false
    fi
    return 0
}

udf_devkit_update() {
    _udu_target="$(udf_devkit_latest)"
    _udu_current="$(udf_devkit_installed_version || true)"
    if [ "$_udu_current" = "$_udu_target" ]; then
        ok "udf-devkit is current ($_udu_target)"
        return 0
    fi
    manifest_set components.udf_devkit.version "$_udu_target"
    manifest_set desired.udf_devkit "$_udu_target"
    if [ "${_udu_current%%.*}" != "${_udu_target%%.*}" ] && [ -n "$_udu_current" ]; then
        warn "udf-devkit $_udu_current -> $_udu_target is a major version: its prebuilt container, alias or packages may differ (exakit help udf-devkit). Your installed containers and UDFs keep working until you switch."
    fi
    info "The prebuilt container $_udu_target is available - install it when ready with: exakit udf-use default"
    ok "udf-devkit ${_udu_current:-not installed} -> $_udu_target"
}

udf_devkit_summary() {
    printf 'Python UDFs: exakit udf-setup\n'
}

udf_devkit_uninstall() {
    if [ "${1:-0}" = "1" ]; then
        [ -e "$EXAKIT_UDF_DEVKIT_HOME" ] && info "  will remove: $EXAKIT_UDF_DEVKIT_HOME"
        info "  containers stay installed in the database (exasol slc remove <alias> removes one)"
        return 0
    fi
    rm -rf "$EXAKIT_UDF_DEVKIT_HOME"
    manifest_del components.udf_devkit
    manifest_del desired.udf_devkit
    info "Containers stay installed in the database; remove one with: exasol slc remove <alias> ($EXAKIT_UDF_DEFAULT_ALIAS, $EXAKIT_UDF_BUILD_ALIAS)"
    ok_step "udf-devkit removed — reinstall any time with: exakit marketplace udf-devkit"
    return 0
}

# --- the commands ------------------------------------------------------------------

_udf_require_installed() {
    [ -n "$(udf_devkit_installed_version || true)" ] || die "The UDF dev kit is not installed. Install it with: exakit marketplace udf-devkit"
}

# _udf_install_tarball <tarball> <alias> <source> [package ...]
_udf_install_tarball() {
    _uit_tar="$1"; _uit_alias="$2"; _uit_source="$3"; shift 3
    _uit_verb=install
    udf_devkit_installed_aliases | grep -qx "$_uit_alias" && _uit_verb=update
    _udf_with_restart "Installing the container as $_uit_alias" \
        _udf_slc custom "$_uit_verb" --source "$_uit_tar" --alias "$_uit_alias" --language "$EXAKIT_UDF_LANGUAGE" --auto-approve || \
        die "The launcher could not install the container as $_uit_alias (see: exakit logs)."
    udf_devkit_smoke "$_uit_alias" "$@" || return 1
    manifest_set "components.udf_devkit.containers.$_uit_alias" "$_uit_source"
}

# cmd_udf_setup [--force] [--yes]
cmd_udf_setup() {
    _ucs_force=0
    for _ucs_arg in "$@"; do
        case "$_ucs_arg" in
            --force) _ucs_force=1 ;;
            --yes|-y) _UDF_YES=1 ;;
            *) die "udf-setup takes --force (reinstall the container) and --yes, nothing else: $_ucs_arg" ;;
        esac
    done
    _udf_require_installed
    udf_devkit_setup_container "$_ucs_force"
}

# cmd_udf_use default|<container.tar.gz> [--alias NAME] [--yes] | --list
cmd_udf_use() {
    _ucu_what=""; _ucu_alias=""; _ucu_list=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --list) _ucu_list=1 ;;
            --yes|-y) _UDF_YES=1 ;;
            --alias) shift; [ -n "${1:-}" ] || die "--alias needs a name"; _ucu_alias="$1" ;;
            -*) die "Unknown option for udf-use: $1 (supported: --alias, --list, --yes)" ;;
            *) [ -z "$_ucu_what" ] || die "Name one thing to install: default, or one container tarball"; _ucu_what="$1" ;;
        esac
        shift
    done
    _udf_require_installed
    if [ "$_ucu_list" = 1 ]; then
        _udf_slc list 2>&1
        return 0
    fi
    [ -n "$_ucu_what" ] || die "Name what to install: exakit udf-use default, or exakit udf-use <container.tar.gz>."
    exakit_db_reachable || die "The database is not running. Start it with: exakit start"
    udf_devkit_require_launcher || exit 1
    if [ "$_ucu_what" = default ]; then
        die "No prebuilt container $(udf_devkit_latest) is published for this machine yet. Build one from a requirements file with: exakit udf-build requirements.txt - or install your own tarball with: exakit udf-use <file>"
    fi
    case "$_ucu_what" in *.tar.gz|*.tgz) ;; *) die "$_ucu_what is not a container tarball (.tar.gz)." ;; esac
    [ -f "$_ucu_what" ] || die "$_ucu_what is not a file."
    _ucu_alias="$(_udf_tool identifier "${_ucu_alias:-$EXAKIT_UDF_BUILD_ALIAS}")" || exit 2
    _udf_install_tarball "$_ucu_what" "$_ucu_alias" "$_ucu_what"
}

# cmd_udf_build <requirements.txt> [--alias NAME] [--yes]
cmd_udf_build() {
    _ucb_req=""; _ucb_alias=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes|-y) _UDF_YES=1 ;;
            --alias) shift; [ -n "${1:-}" ] || die "--alias needs a name"; _ucb_alias="$1" ;;
            -*) die "Unknown option for udf-build: $1 (supported: --alias, --yes)" ;;
            *) [ -z "$_ucb_req" ] || die "Name one requirements file"; _ucb_req="$1" ;;
        esac
        shift
    done
    [ -n "$_ucb_req" ] || die "Name the requirements file: exakit udf-build requirements.txt (every package pinned name==version)."
    _udf_require_installed
    [ -f "$_ucb_req" ] || die "$_ucb_req is not a file."
    # Refused before anything heavy: every package pinned name==version.
    _ucb_pins="$(_udf_tool pinned "$_ucb_req" 2>"$EXAKIT_HOME/.udf-pins.err")" || die "$(cat "$EXAKIT_HOME/.udf-pins.err")"
    rm -f "$EXAKIT_HOME/.udf-pins.err"
    _ucb_alias="$(_udf_tool identifier "${_ucb_alias:-$EXAKIT_UDF_BUILD_ALIAS}")" || exit 2
    if ! { command -v notebook_installed_version >/dev/null 2>&1 && notebook_installed_version >/dev/null; }; then
        die "Building a container uses the notebook add-on's tooling, which is not installed. Install it with: exakit marketplace notebook"
    fi
    exakit_db_reachable || die "The database is not running. Start it with: exakit start"
    udf_devkit_require_launcher || exit 1
    if ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; then
        die "Building a container needs a running Docker engine, and none answers (start Docker Desktop or Colima; with Podman, start its machine and point DOCKER_HOST at its socket)."
    fi
    _ucb_work="$EXAKIT_UDF_DEVKIT_HOME/build"
    mkdir -p "$_ucb_work"
    _ucb_free="$(df -Pk "$_ucb_work" | awk 'NR==2 {print int($4/1048576)}')"
    [ "${_ucb_free:-0}" -ge "$EXAKIT_UDF_BUILD_MIN_FREE_GB" ] || \
        die "Building a container needs about $EXAKIT_UDF_BUILD_MIN_FREE_GB GB free; $_ucb_work has ${_ucb_free:-0} GB."
    _ucb_uv="$(_notebook_uv)" || die "uv (the Python tool runner) is not available."
    # Read by run_logged's spinner in common.sh.
    # shellcheck disable=SC2034
    EXAKIT_ACTIVE_LABEL="Adding the container build tooling to the notebook environment"
    # shellcheck disable=SC2086
    run_logged "$_ucb_uv" pip install --python "$(notebook_venv_python)" \
        "${EXAKIT_NOTEBOOK_PACKAGE}[$EXAKIT_NOTEBOOK_EXTRAS,slc]==$(notebook_package_version)" || \
        die "The container build tooling could not be added to the notebook environment (see the log)."
    notebook_write_connection >/dev/null || die "The notebook connection store could not be written."
    _ucb_doc="$(printf '%s\n' "$_ucb_pins" | python3 -c '
import json, sys
pins = [line.strip().split("==", 1) for line in sys.stdin if line.strip()]
print(json.dumps({"work_dir": sys.argv[1], "name": sys.argv[2], "flavor": sys.argv[3], "packages": pins}))' \
        "$_ucb_work" "$EXAKIT_UDF_BUILD_NAME" "$EXAKIT_UDF_BUILD_FLAVOR")"
    info "Building a container with $(printf '%s\n' "$_ucb_pins" | grep -c .) package(s); this takes a while the first time"
    _ucb_out="$(EXAKIT_UDF_BUILD="$_ucb_doc" SCS_FILE="$(notebook_store_file)" \
        SCS_MASTER_PASSWORD="$(_notebook_secret "$EXAKIT_NOTEBOOK_MASTER_CRED")" \
        "$(notebook_venv_python)" "$(exakit_repo_root)/setup/udf/udf_tool.py" build 2>>"${EXAKIT_LOG_FILE:-/dev/null}")" || \
        die "The container build failed (see: exakit logs)."
    _ucb_tar="$(printf '%s\n' "$_ucb_out" | tail -1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["tarball"])' 2>/dev/null)"
    [ -f "$_ucb_tar" ] || die "The container build did not report its tarball (see: exakit logs)."
    # shellcheck disable=SC2046
    _udf_install_tarball "$_ucb_tar" "$_ucb_alias" "$_ucb_req" $(printf '%s\n' "$_ucb_pins" | sed 's/==.*//')
}

# cmd_udf_file <file> [<path in the bucket>] — copy a file into BucketFS and
# name the path a UDF reads.
cmd_udf_file() {
    [ $# -ge 1 ] && [ $# -le 2 ] || die "Name the file and, optionally, where in the bucket: exakit udf-file model.pkl models/model.pkl"
    _udf_require_installed
    [ -f "$1" ] || die "$1 is not a file."
    _ucf_rel="$(_udf_tool relative "${2:-$(basename "$1")}" 2>&1)" || die "$_ucf_rel"
    _ucf_root="$EXAKIT_PERSONAL_DEPLOY_DIR/$EXAKIT_UDF_BUCKETFS_DIR"
    [ -d "$(dirname "$_ucf_root")" ] || die "The deployment has no BucketFS folder at $_ucf_root; is the database deployed by this launcher? (exakit status)"
    _ucf_dest="$_ucf_root/$EXAKIT_UDF_BUCKETFS_SERVICE/$EXAKIT_UDF_BUCKETFS_BUCKET/$_ucf_rel"
    mkdir -p "$(dirname "$_ucf_dest")" || die "Could not create $(dirname "$_ucf_dest")"
    if ! { cp "$1" "$_ucf_dest.part" && mv "$_ucf_dest.part" "$_ucf_dest"; }; then
        die "Could not copy $1 into BucketFS."
    fi
    ok "Copied into BucketFS: $_ucf_dest"
    info "A UDF reads it as: $EXAKIT_UDF_BUCKETFS_ROOT/$EXAKIT_UDF_BUCKETFS_SERVICE/$EXAKIT_UDF_BUCKETFS_BUCKET/$_ucf_rel"
}
