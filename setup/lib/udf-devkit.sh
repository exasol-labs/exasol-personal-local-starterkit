#!/usr/bin/env bash
# udf-devkit.sh — udf-devkit (Python UDFs on the local database): managed
# install + validation + the `exakit udf-setup | udf-use | udf-build | udf-file
# | model` commands.
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
#     `exakit udf-file` copies a file there and names the path a UDF reads;
#     `exakit model put | list` does the same for model files under models/,
#     with each file's sha256 recorded (components.udf_devkit.models) so a
#     different file is never put over one silently. Where that folder is
#     comes from one helper, udf_bucket_locate.
#   - `exakit udf-build requirements.txt` builds a container with the notebook
#     add-on's SLC tooling (it needs that add-on and a running Docker or
#     Podman engine, and about 25 GB free; both checked before it starts).
#   - Nothing of its own to download until a prebuilt container is published
#     (versions.json components.udf-devkit); the version is the kit's.
#   - The rules and the database steps are setup/udf/udf_tool.py, shared with
#     the PowerShell twin; it connects as the kit's admin user through the
#     pyexasol venv, the password read from its file by the child.
#
#   - model files: setup/udf/model_tool.py (standard library only) copies,
#     digests and lists them; udf/templates/ holds the scoring UDF template
#     and its renderer.
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
        info "  model files stay in the deployment's bucket directory; only their record goes"
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

# _udf_container_runtime — the engine udf-build's exaslct talks to, checked
# before anything is built (AC-ML1.3). Sets UDF_CONTAINER_RUNTIME to "docker"
# when the Docker CLI answers, or "podman" when Podman answers and its
# Docker-compatible API socket is known: DOCKER_HOST already set, or the socket
# Podman (or its machine) reports, exported here for exaslct. On Windows and
# Linux the Podman the launcher installed is enough. 1 when no engine answers,
# 2 when Podman answers without an API socket. Bounded: `podman info` can
# block while a machine is still coming up.
_udf_container_runtime() {
    UDF_CONTAINER_RUNTIME=""
    if command -v docker >/dev/null 2>&1 && exakit_run_bounded 20 docker info >/dev/null 2>&1; then
        UDF_CONTAINER_RUNTIME=docker
        return 0
    fi
    { command -v podman >/dev/null 2>&1 && exakit_run_bounded 20 podman info >/dev/null 2>&1; } || return 1
    if [ -z "${DOCKER_HOST:-}" ]; then
        _ucr_sock="$(exakit_run_bounded 20 podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null | head -1)"
        [ -S "$_ucr_sock" ] || _ucr_sock="$(exakit_run_bounded 20 podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null | head -1)"
        _ucr_sock="${_ucr_sock#unix://}"
        { [ -n "$_ucr_sock" ] && [ -S "$_ucr_sock" ]; } || return 2
        DOCKER_HOST="unix://$_ucr_sock"
        export DOCKER_HOST
    fi
    UDF_CONTAINER_RUNTIME=podman
    return 0
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
    _udf_container_runtime
    case $? in
        0) ;;
        2) die "Podman answers, but not its Docker-compatible API, which the container build talks to. Start it (Linux: systemctl --user start podman.socket) or point DOCKER_HOST at its socket, then run this again." ;;
        *) die "Building a container needs a running container engine, Docker or Podman, and none answers (start Docker Desktop or Colima, or Podman's machine: podman machine start)." ;;
    esac
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
    info "Building a container with $(printf '%s\n' "$_ucb_pins" | grep -c .) package(s) on $UDF_CONTAINER_RUNTIME; this takes a while the first time"
    _ucb_out="$(EXAKIT_UDF_BUILD="$_ucb_doc" SCS_FILE="$(notebook_store_file)" \
        SCS_MASTER_PASSWORD="$(_notebook_secret "$EXAKIT_NOTEBOOK_MASTER_CRED")" \
        "$(notebook_venv_python)" "$(exakit_repo_root)/setup/udf/udf_tool.py" build 2>>"${EXAKIT_LOG_FILE:-/dev/null}")" || \
        die "The container build failed (see: exakit logs)."
    _ucb_tar="$(printf '%s\n' "$_ucb_out" | tail -1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["tarball"])' 2>/dev/null)"
    [ -f "$_ucb_tar" ] || die "The container build did not report its tarball (see: exakit logs)."
    # shellcheck disable=SC2046
    _udf_install_tarball "$_ucb_tar" "$_ucb_alias" "$_ucb_req" $(printf '%s\n' "$_ucb_pins" | sed 's/==.*//')
}

# udf_bucket_locate — where the deployment's bucket is, resolved in this one
# place for every command that hands a UDF a file (udf-file, model put | list;
# the external-sources work stages its drivers through the same mapping). The
# layout belongs to the launcher, so nothing else spells it out. Sets
# UDF_BUCKET_DIR (the folder on this machine) and UDF_BUCKET_UDF_ROOT (that
# folder as a UDF sees it, /buckets/<service>/<bucket>); returns 1 with
# UDF_BUCKET_ERROR saying why when there is no deployment to put a file into.
# Globals rather than printed lines: the two paths travel together, and a
# subshell per value would resolve them twice.
udf_bucket_locate() {
    UDF_BUCKET_DIR=""; UDF_BUCKET_UDF_ROOT=""; UDF_BUCKET_ERROR=""
    _ubl_root="$EXAKIT_PERSONAL_DEPLOY_DIR/$EXAKIT_UDF_BUCKETFS_DIR"
    if [ ! -d "$(dirname "$_ubl_root")" ]; then
        UDF_BUCKET_ERROR="The deployment has no BucketFS folder at $_ubl_root; is the database deployed by this launcher? (exakit status)"
        return 1
    fi
    UDF_BUCKET_DIR="$_ubl_root/$EXAKIT_UDF_BUCKETFS_SERVICE/$EXAKIT_UDF_BUCKETFS_BUCKET"
    UDF_BUCKET_UDF_ROOT="$EXAKIT_UDF_BUCKETFS_ROOT/$EXAKIT_UDF_BUCKETFS_SERVICE/$EXAKIT_UDF_BUCKETFS_BUCKET"
    return 0
}

# cmd_udf_file <file> [<path in the bucket>] — copy a file into BucketFS and
# name the path a UDF reads.
cmd_udf_file() {
    [ $# -ge 1 ] && [ $# -le 2 ] || die "Name the file and, optionally, where in the bucket: exakit udf-file model.pkl models/model.pkl"
    _udf_require_installed
    [ -f "$1" ] || die "$1 is not a file."
    _ucf_rel="$(_udf_tool relative "${2:-$(basename "$1")}" 2>&1)" || die "$_ucf_rel"
    udf_bucket_locate || die "$UDF_BUCKET_ERROR"
    _ucf_dest="$UDF_BUCKET_DIR/$_ucf_rel"
    mkdir -p "$(dirname "$_ucf_dest")" || die "Could not create $(dirname "$_ucf_dest")"
    if ! { cp "$1" "$_ucf_dest.part" && mv "$_ucf_dest.part" "$_ucf_dest"; }; then
        die "Could not copy $1 into BucketFS."
    fi
    ok "Copied into BucketFS: $_ucf_dest"
    info "A UDF reads it as: $UDF_BUCKET_UDF_ROOT/$_ucf_rel"
}

# --- exakit model put | list | template --------------------------------------
#
# A model trained anywhere arrives as a file. `put` copies it to
# <bucket>/models/<its name>, records its sha256, size and time in the
# manifest (components.udf_devkit.models: one JSON object keyed by file name -
# a name holds dots, so it cannot be a dotted manifest key of its own) and
# prints the /buckets path the scoring UDF opens. A file of the same name with
# a DIFFERENT digest is never overwritten without --replace; the same digest is
# a no-op. Exit codes are the kit's (AGENTS.md): 2 bad input, 3 no deployment,
# 4 the add-on is not installed, 5 not confirmed (--replace was not given).
# Nothing here reads or prints a credential: a local deployment has no
# BucketFS password, and the copy is a file copy.

# _model_tool <args> — setup/udf/model_tool.py on any Python 3 (standard
# library only and no database connection, so no credential in its environment).
_model_tool() {
    run_python_any "$(exakit_repo_root)/setup/udf/model_tool.py" "$@"
}

# _model_refuse <exit code> <remedy or ""> <message> — stop with the kit's exit
# code for what went wrong. No failure note (die writes one): nothing of the
# install failed. With --json, one object on stdout, reject()'s shape.
_model_refuse() {
    _mr_code="$1"; _mr_remedy="$2"; shift 2
    if [ "${EXAKIT_REFUSAL_JSON:-0}" = "1" ]; then
        _mr_r=null
        [ -n "$_mr_remedy" ] && _mr_r="\"$(_exakit_json_string "$_mr_remedy")\""
        exakit_json_out '{"ok": false, "error": "%s", "remedy": %s}\n' "$(_exakit_json_string "$*")" "$_mr_r"
        exit "$_mr_code"
    fi
    printf '\n  %s%s %s%s%s\n' "${UI_ERR:-}" "${UI_CROSS:-[x]}" "${UI_BOLD:-}" "$*" "${UI_RESET:-}" >&2
    [ -z "$_mr_remedy" ] || printf '    Run: %s\n' "$_mr_remedy" >&2
    exit "$_mr_code"
}

# _model_ready — the add-on installed and a deployment to put files into;
# leaves UDF_BUCKET_DIR and UDF_BUCKET_UDF_ROOT set.
_model_ready() {
    [ -n "$(udf_devkit_installed_version || true)" ] || \
        _model_refuse 4 "exakit marketplace udf-devkit" "The UDF dev kit is not installed."
    udf_bucket_locate || _model_refuse 3 "exakit status" "$UDF_BUCKET_ERROR"
}

# _model_record — the recorded models as one JSON object ({} when none yet).
_model_record() {
    _mrc="$(manifest_get components.udf_devkit.models 2>/dev/null || true)"
    case "$_mrc" in "{"*) printf '%s\n' "$_mrc" ;; *) printf '{}\n' ;; esac
}

# cmd_model put|list|template ... — `exakit model --help` shows every page,
# `exakit model put --help` the one.
cmd_model() {
    _cm_sub="${1:-}"
    [ $# -gt 0 ] && shift
    case "$_cm_sub" in
        --help|-h) exakit_help_render command "exakit model" ;;
        put|list|template)
            case " $* " in
                *" --help "*|*" -h "*) exakit_help_render command "exakit model $_cm_sub"; return $? ;;
            esac
            "_cmd_model_$_cm_sub" "$@" ;;
        "") reject "Name what to do: exakit model put <file> | exakit model list | exakit model template (exakit model --help)." ;;
        *) reject "Unknown model command '$_cm_sub' (supported: put, list, template)." ;;
    esac
}

# exakit model put <file> [--replace] [--json]
_cmd_model_put() {
    _cmp_file=""; _cmp_replace=0; _cmp_json=0
    for _cmp_arg in "$@"; do
        case "$_cmp_arg" in
            --replace) _cmp_replace=1 ;;
            --json|-j) _cmp_json=1; EXAKIT_REFUSAL_JSON=1 ;;
            -*) reject "Unknown option '$_cmp_arg' for model put (supported: --replace --json)." ;;
            *) [ -z "$_cmp_file" ] || reject "Name one model file: exakit model put <file> [--replace]"; _cmp_file="$_cmp_arg" ;;
        esac
    done
    [ -n "$_cmp_file" ] || reject "Name the model file: exakit model put <file> [--replace] [--json]"
    _model_ready
    [ -f "$_cmp_file" ] || reject "$_cmp_file is not a file."
    _cmp_err="$EXAKIT_HOME/.model-put.err"
    _cmp_out="$(_model_record | _model_tool put "$_cmp_file" "$UDF_BUCKET_DIR" "$UDF_BUCKET_UDF_ROOT" "$_cmp_replace" 2>"$_cmp_err")"
    _cmp_rc=$?
    _cmp_why="$(cat "$_cmp_err" 2>/dev/null)"; rm -f "$_cmp_err"
    case "$_cmp_rc" in
        0) ;;
        5) _model_refuse 5 "exakit model put $_cmp_file --replace" "$_cmp_why" ;;
        2) reject "$_cmp_why" ;;
        *) die "Could not put $_cmp_file into the bucket directory: ${_cmp_why:-no reason given}" ;;
    esac
    _cmp_action="$(printf '%s\n' "$_cmp_out" | sed -n 1p)"
    _cmp_answer="$(printf '%s\n' "$_cmp_out" | sed -n 2p)"
    manifest_set components.udf_devkit.models "$(printf '%s\n' "$_cmp_out" | sed -n 3p)"
    if [ "$_cmp_json" = 1 ]; then
        exakit_json_pretty "$_cmp_answer"
        return 0
    fi
    _cmp_fields="$(printf '%s\n' "$_cmp_answer" | run_python_any -c 'import json, sys
a = json.load(sys.stdin)
print("\n".join(str(a[k]) for k in ("name", "path", "sha256", "size")))')"
    _cmp_name="$(printf '%s\n' "$_cmp_fields" | sed -n 1p)"
    case "$_cmp_action" in
        unchanged) ok "$_cmp_name is already in the bucket directory with the same digest; nothing was copied" ;;
        replaced)  ok "Replaced $_cmp_name in the bucket directory: $UDF_BUCKET_DIR/models/$_cmp_name" ;;
        *)         ok "Copied $_cmp_name into the bucket directory: $UDF_BUCKET_DIR/models/$_cmp_name" ;;
    esac
    info "sha256 $(printf '%s\n' "$_cmp_fields" | sed -n 3p), $(printf '%s\n' "$_cmp_fields" | sed -n 4p) bytes, recorded"
    info "A UDF reads it as: $(printf '%s\n' "$_cmp_fields" | sed -n 2p)"
}

# exakit model list [--json]
_cmd_model_list() {
    _cml_json=0
    for _cml_arg in "$@"; do
        case "$_cml_arg" in
            --json|-j) _cml_json=1; EXAKIT_REFUSAL_JSON=1 ;;
            *) reject "Unknown argument '$_cml_arg' for model list (supported: --json)." ;;
        esac
    done
    _model_ready
    _cml_err="$EXAKIT_HOME/.model-list.err"
    _cml_doc="$(_model_record | _model_tool list "$UDF_BUCKET_DIR" "$UDF_BUCKET_UDF_ROOT" 2>"$_cml_err")"
    _cml_rc=$?
    _cml_why="$(cat "$_cml_err" 2>/dev/null)"; rm -f "$_cml_err"
    [ "$_cml_rc" -eq 0 ] || die "Could not list the bucket directory: ${_cml_why:-no reason given}"
    if [ "$_cml_json" = 1 ]; then
        exakit_json_pretty "$_cml_doc"
        return 0
    fi
    printf '%s\n' "$_cml_doc" | run_python_any -c 'import json, sys
d = json.load(sys.stdin)
print("  Bucket directory: %s" % d["bucket_dir"])
print("  UDFs read it as:  %s" % d["udf_root"])
print("")
if not d["models"]:
    print("  No models yet. Put one with: exakit model put <file>")
for m in d["models"]:
    note = {"ok": "", "unrecorded": "  (not put with exakit model put)",
            "changed": "  ! CHANGED since it was put (recorded %s...)" % (m["recorded_sha256"] or "")[:12]}[m["status"]]
    print("  %-28s %10d bytes  sha256 %s...%s" % (m["name"], m["size"], m["sha256"][:12], note))
    print("      %s" % m["path"])
for name in d["missing"]:
    print("  %-28s recorded, but no longer in the bucket directory" % name)'
}

# exakit model template [--json] — where the scoring UDF template and its
# renderer are; filling it is the renderer's job (python3 render.py --help).
_cmd_model_template() {
    _cmt_json=0
    for _cmt_arg in "$@"; do
        case "$_cmt_arg" in
            --json|-j) _cmt_json=1 ;;
            *) reject "Unknown argument '$_cmt_arg' for model template (supported: --json)." ;;
        esac
    done
    _cmt_dir="$(exakit_repo_root)/udf/templates"
    [ -f "$_cmt_dir/render.py" ] || die "The UDF templates are missing from this kit copy ($_cmt_dir). Repair with: exakit update"
    _cmt_places="$(run_python_any "$_cmt_dir/render.py" --placeholders | tr '\n' ' ' | sed 's/ $//')"
    if [ "$_cmt_json" = 1 ]; then
        exakit_json_out '{"template": "%s", "renderer": "%s", "placeholders": [%s], "usage": "%s"}\n' \
            "$(_exakit_json_string "$_cmt_dir/score_model.sql")" "$(_exakit_json_string "$_cmt_dir/render.py")" \
            "$(printf '%s' "$_cmt_places" | sed 's/[A-Z_][A-Z_]*/"&"/g; s/ /, /g')" \
            "$(_exakit_json_string "python3 $_cmt_dir/render.py --help")"
        return 0
    fi
    info "Scoring UDF template: $_cmt_dir/score_model.sql"
    info "Placeholders: $_cmt_places"
    info "Fill them with the renderer (every value is checked; none may be left unfilled):"
    printf '    python3 %s \\\n' "$_cmt_dir/render.py"
    printf '      --schema SCORING --name SCORE_MODEL --model-path <the path exakit model put printed> \\\n'
    printf '      --input category:VARCHAR(2000) --input doc_text:VARCHAR(2000000):text --output DOUBLE --method predict_proba\n'
}
