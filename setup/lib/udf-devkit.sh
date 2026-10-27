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
#   - The prebuilt containers are a matrix in versions.json
#     (components.udf-devkit.containers: one row per language and
#     architecture, each with the database versions it runs on, its runtime
#     and pinned packages, url, sha256 and size). `exakit udf-use default`
#     picks the Python row for the DATABASE's architecture (an Apple-silicon
#     Mac runs an aarch64 database VM, Windows runs Podman's x86_64 machine)
#     and its version, downloads it into $EXAKIT_HOME/cache/containers once,
#     verifies size and digest before the launcher sees it, installs it as
#     PYTHON3_ML and has the smoke UDF compare each package's version with the
#     pin. EXAKIT_UDF_LANGUAGE=rust (or --language rust) takes the Rust row the
#     same way, alias RUST; its smoke UDF is the next kit step.
#     EXAKIT_UDF_CONTAINERS_MIRROR (a folder or base URL) and EXAKIT_UDF_ARCH
#     point elsewhere, for tests and offline installs. The add-on's version is
#     the kit's.
#   - udf-setup and udf-use answer in JSON with --json and exit with one code
#     per failure, naming the language and the step (_udf_refuse).
#   - The rules and the database steps are setup/udf/udf_tool.py, shared with
#     the PowerShell twin; it connects as the kit's admin user through the
#     pyexasol venv, the password read from its file by the child. The rules
#     that need no database (arch, resolve, verify, pins) run on any Python 3.
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
EXAKIT_UDF_RUST_ALIAS="RUST"
# The language a persona install and the commands set up unless --language
# says otherwise; validated where it is read (_udf_language).
EXAKIT_UDF_LANGUAGE="${EXAKIT_UDF_LANGUAGE:-python}"
EXAKIT_UDF_SCHEMA="EXAKIT_UDF"
# Downloaded prebuilt containers, kept by file name so a second install (or
# another alias of the same row) verifies the cached file instead of
# downloading it again.
EXAKIT_UDF_CONTAINER_CACHE="${EXAKIT_UDF_CONTAINER_CACHE:-$EXAKIT_HOME/cache/containers}"
EXAKIT_UDF_INSTALL_TIMEOUT="${EXAKIT_UDF_INSTALL_TIMEOUT:-3600}"
# Where the commands' answer goes with --json (fd 3, the real stdout, once
# _udf_json_mode has moved everything else to stderr).
_UDF_STDOUT=1
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

# _udf_rules <command> [args] — the rules that need no database (arch, resolve,
# field, verify, pins, identifier) on any Python 3, with no connection setting
# in the child's environment. Twin of Invoke-UdfTool -NoConnection.
_udf_rules() {
    run_python_any "$(exakit_repo_root)/setup/udf/udf_tool.py" "$@"
}

# _udf_db_version — the running database's version, for the container matrix.
_udf_db_version() {
    _udf_tool dbversion 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
}

# _udf_os — this machine as the matrix names it: darwin, linux or windows
# (Git Bash and MSYS run the Windows launcher; WSL is linux).
_udf_os() {
    case "$(uname -s 2>/dev/null || true)" in
        Darwin) printf 'darwin\n' ;;
        Linux) printf 'linux\n' ;;
        MINGW*|MSYS*|CYGWIN*|Windows*) printf 'windows\n' ;;
        *) uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' ;;
    esac
}

# _udf_arch — the DATABASE's architecture (x86_64 | aarch64), which is what a
# container is built for: the rule is in udf_tool.py; EXAKIT_UDF_ARCH overrides.
_udf_arch() {
    _udf_rules arch "$(uname -m 2>/dev/null || true)" "$(_udf_os)"
}

# _udf_language [value] — the language to set up, validated: python or rust.
# 1 with the reason printed when it is anything else.
_udf_language() {
    _ul_value="${1:-$EXAKIT_UDF_LANGUAGE}"
    case "$_ul_value" in
        python|rust) printf '%s\n' "$_ul_value"; return 0 ;;
        *) printf "The UDF language must be python or rust, not '%s' (--language, or EXAKIT_UDF_LANGUAGE).\n" "$_ul_value"; return 1 ;;
    esac
}

# _udf_fail <code> <step> <remedy or ""> <message> — note why a setup step
# stopped (UDF_FAIL_*), for the caller to turn into a refusal (the commands) or
# a warning (the persona install, which must not exit). Always returns 1.
_udf_fail() {
    UDF_FAIL_CODE="$1"; UDF_FAIL_STEP="$2"; UDF_FAIL_REMEDY="$3"; shift 3
    UDF_FAIL_MSG="$*"
    _exakit_log_file "UDF   $UDF_FAIL_STEP ($UDF_FAIL_CODE): $UDF_FAIL_MSG"
    return 1
}

# _udf_refuse <code> <language> <step> <remedy or ""> <message> — stop with the
# exit code for what went wrong (AC-ML1.6): 2 bad arguments, 3 a package the
# smoke UDF did not find, 4 no container for this database (language, arch or
# version) or a digest that did not match, 5 not ready (the add-on, the
# database, the launcher, the download or the disk), 6 the launcher's install
# failed, 7 the smoke UDF did not pass or reported a version other than the
# pinned one. The JSON names the language and the step (select-container,
# download, verify, install, smoke) so an agent branches on both. No failure
# note (die writes one): nothing of the install failed. Twin of Exit-UdfRefusal.
_udf_refuse() {
    _ur_code="$1"; _ur_language="$2"; _ur_step="$3"; _ur_remedy="$4"; shift 4
    _exakit_log_file "REFUSE udf $_ur_language/$_ur_step ($_ur_code): $*"
    if [ "${EXAKIT_REFUSAL_JSON:-0}" = "1" ]; then
        _ur_r=null
        [ -n "$_ur_remedy" ] && _ur_r="\"$(_exakit_json_string "$_ur_remedy")\""
        exakit_json_out '{"ok": false, "language": "%s", "step": "%s", "reason": "%s", "remedy": %s}\n' \
            "$(_exakit_json_string "$_ur_language")" "$(_exakit_json_string "$_ur_step")" \
            "$(_exakit_json_string "$*")" "$_ur_r" >&"$_UDF_STDOUT"
        exit "$_ur_code"
    fi
    printf '\n  %s%s %s%s%s\n' "${UI_ERR:-}" "${UI_CROSS:-[x]}" "${UI_BOLD:-}" "$*" "${UI_RESET:-}" >&2
    [ -z "$_ur_remedy" ] || printf '    Run: %s\n' "$_ur_remedy" >&2
    exit "$_ur_code"
}

# _udf_raise_fail <language> — the refusal for the last _udf_fail.
_udf_raise_fail() {
    _udf_refuse "${UDF_FAIL_CODE:-1}" "$1" "${UDF_FAIL_STEP:-install}" "${UDF_FAIL_REMEDY:-}" "${UDF_FAIL_MSG:-The step did not finish (see: exakit logs).}"
}

# _udf_json_mode — --json: the answer is one object on stdout and nothing else
# there. The real stdout is kept on fd 3 for the answer; everything the steps
# narrate goes to stderr, and the detail lines are gated to the log.
_udf_json_mode() {
    EXAKIT_REFUSAL_JSON=1
    EXAKIT_QUIET_DETAIL=1
    exec 3>&1 1>&2
    _UDF_STDOUT=3
}

# _udf_done <language> <alias> — the commands' success: with --json the object
# (the container from UDF_CONTAINER_*, the smoke UDF's lines as package and
# version); otherwise the steps have already said it.
_udf_done() {
    [ "$_UDF_STDOUT" = 3 ] || return 0
    _ud_smoke=""; _ud_sep=""
    while read -r _ud_name _ud_version; do
        [ -n "$_ud_name" ] || continue
        _ud_smoke="$_ud_smoke$_ud_sep{\"package\": \"$(_exakit_json_string "$_ud_name")\", \"version\": \"$(_exakit_json_string "$_ud_version")\"}"
        _ud_sep=", "
    done <<EOF
${UDF_SMOKE_LINES:-}
EOF
    _ud_url=null; _ud_sha=null; _ud_arch=null; _ud_range=null
    [ -z "${UDF_CONTAINER_URL:-}" ] || _ud_url="\"$(_exakit_json_string "$UDF_CONTAINER_URL")\""
    [ -z "${UDF_CONTAINER_SHA256:-}" ] || _ud_sha="\"$(_exakit_json_string "$UDF_CONTAINER_SHA256")\""
    [ -z "${UDF_CONTAINER_ARCH:-}" ] || _ud_arch="\"$(_exakit_json_string "$UDF_CONTAINER_ARCH")\""
    [ -z "${UDF_CONTAINER_DB_VERSIONS:-}" ] || _ud_range="\"$(_exakit_json_string "$UDF_CONTAINER_DB_VERSIONS")\""
    exakit_json_out '{"ok": true, "language": "%s", "alias": "%s", "container": {"url": %s, "sha256": %s, "arch": %s, "db_versions": %s}, "smoke": [%s]}\n' \
        "$1" "$2" "$_ud_url" "$_ud_sha" "$_ud_arch" "$_ud_range" "$_ud_smoke" >&"$_UDF_STDOUT"
}

# udf_devkit_launcher_problem — prints why the launcher cannot install
# containers and returns 1; nothing and 0 when it can.
udf_devkit_launcher_problem() {
    _ulp_v="$(personal_launcher_version 2>/dev/null || true)"
    _udf_rules atleast "${_ulp_v:-0}" "$EXAKIT_UDF_MIN_LAUNCHER" && return 0
    printf 'The UDF dev kit needs Exasol launcher %s or later; this machine has %s. Update it with: exakit update personal\n' "$EXAKIT_UDF_MIN_LAUNCHER" "${_ulp_v:-none}"
    return 1
}

# udf_devkit_require_launcher — refuse unless the launcher can install containers.
udf_devkit_require_launcher() {
    _url_why="$(udf_devkit_launcher_problem)" && return 0
    warn "$_url_why"
    return 1
}

# _udf_ready <step> — the database running and the launcher able to install
# containers, or a _udf_fail (5) naming which.
_udf_ready() {
    exakit_db_reachable || { _udf_fail 5 "$1" "exakit start" "The database is not running."; return 1; }
    _ur_why="$(udf_devkit_launcher_problem)" || { _udf_fail 5 "$1" "exakit update personal" "$_ur_why"; return 1; }
    return 0
}

# _udf_select_container <language> — the matrix row for this language, the
# database's architecture and its version (udf_tool.py resolve), into
# UDF_CONTAINER_ROW and the fields the steps read (URL, SHA256, SIZE, ARCH,
# DB_VERSIONS); a _udf_fail (4, step select-container) names what did not match.
_udf_select_container() {
    _usc_lang="$1"
    UDF_CONTAINER_ROW=""; UDF_CONTAINER_URL=""; UDF_CONTAINER_SHA256=""; UDF_CONTAINER_SIZE=""
    UDF_CONTAINER_ARCH=""; UDF_CONTAINER_DB_VERSIONS=""
    _usc_doc="$(exakit_versions_active_doc 2>/dev/null)" || {
        _udf_fail 4 select-container "exakit update" "This kit copy has no readable versions.json to pick a container from."; return 1; }
    _usc_err="$EXAKIT_HOME/.udf-select.err"
    _usc_arch="$(_udf_rules arch "$(uname -m 2>/dev/null || true)" "$(_udf_os)" 2>"$_usc_err")" || {
        _usc_why="$(cat "$_usc_err" 2>/dev/null)"; rm -f "$_usc_err"
        _udf_fail 4 select-container "" "${_usc_why:-The architecture of this machine is not known.}"; return 1; }
    _usc_db="$(_udf_db_version)"
    [ -n "$_usc_db" ] || { rm -f "$_usc_err"; _udf_fail 5 select-container "exakit status" "The database version is not known: is the database running?"; return 1; }
    UDF_CONTAINER_ROW="$(_udf_rules resolve "$_usc_doc" "$_usc_lang" "$_usc_arch" "$_usc_db" 2>"$_usc_err")" || {
        _usc_why="$(cat "$_usc_err" 2>/dev/null)"; rm -f "$_usc_err"
        _udf_fail 4 select-container "exakit update" "No prebuilt $_usc_lang container fits this database ($_usc_arch, version $_usc_db): ${_usc_why:-no row matched}. A kit update may bring one."; return 1; }
    rm -f "$_usc_err"
    UDF_CONTAINER_URL="$(_udf_row url)"; UDF_CONTAINER_SHA256="$(_udf_row sha256)"; UDF_CONTAINER_SIZE="$(_udf_row size)"
    UDF_CONTAINER_ARCH="$_usc_arch"; UDF_CONTAINER_DB_VERSIONS="$(_udf_row db_versions)"
    UDF_CONTAINER_DB="$_usc_db"
    info "Container for $_usc_lang on $_usc_arch, database $_usc_db: $(basename "$UDF_CONTAINER_URL")"
    return 0
}

# _udf_row <field> — one field of the selected row.
_udf_row() {
    printf '%s' "$UDF_CONTAINER_ROW" | _udf_rules field "$1" 2>/dev/null
}

# _udf_fetch_container <language> — the selected row's tarball into the cache
# (UDF_CONTAINER_FILE), verified against its pinned size and sha256 before
# anything installs it: a cached file that verifies is reused; otherwise it is
# downloaded (resumed and retried by fetch) or copied from
# EXAKIT_UDF_CONTAINERS_MIRROR (a folder, file:// or https:// base URL holding
# the file by name) into a .part that is renamed only once it verifies. A
# mismatch is _udf_fail 4 (step verify) and the file is removed, so running
# the command again downloads it afresh; a download that did not arrive is 5
# (step download).
_udf_fetch_container() {
    _ufc_lang="$1"
    _ufc_name="$(basename "$UDF_CONTAINER_URL")"
    UDF_CONTAINER_FILE="$EXAKIT_UDF_CONTAINER_CACHE/$_ufc_name"
    mkdir -p "$EXAKIT_UDF_CONTAINER_CACHE" 2>/dev/null || {
        _udf_fail 5 download "" "Could not create the container cache $EXAKIT_UDF_CONTAINER_CACHE."; return 1; }
    if [ -f "$UDF_CONTAINER_FILE" ] && _udf_rules verify "$UDF_CONTAINER_FILE" "$UDF_CONTAINER_SHA256" "$UDF_CONTAINER_SIZE" 2>/dev/null; then
        ok "Using the cached container $UDF_CONTAINER_FILE (digest verified)"
        return 0
    fi
    _ufc_src="$UDF_CONTAINER_URL"; _ufc_local=""
    if [ -n "${EXAKIT_UDF_CONTAINERS_MIRROR:-}" ]; then
        case "$EXAKIT_UDF_CONTAINERS_MIRROR" in
            https://*) _ufc_src="${EXAKIT_UDF_CONTAINERS_MIRROR%/}/$_ufc_name" ;;
            file://*)  _ufc_local="${EXAKIT_UDF_CONTAINERS_MIRROR#file://}"; _ufc_local="${_ufc_local%/}/$_ufc_name"; _ufc_src="$_ufc_local" ;;
            *://*)     _udf_fail 5 download "" "EXAKIT_UDF_CONTAINERS_MIRROR must be a folder, a file:// URL or an https:// URL (got '$EXAKIT_UDF_CONTAINERS_MIRROR')."; return 1 ;;
            *)         _ufc_local="${EXAKIT_UDF_CONTAINERS_MIRROR%/}/$_ufc_name"; _ufc_src="$_ufc_local" ;;
        esac
    fi
    _ufc_mb="$(awk -v b="${UDF_CONTAINER_SIZE:-0}" 'BEGIN { printf "%d MB", b / 1000000 }')"
    _ufc_part="$UDF_CONTAINER_FILE.part"
    rm -f "$UDF_CONTAINER_FILE"
    if [ -n "$_ufc_local" ]; then
        info "Copying the $_ufc_lang container ($_ufc_mb) from $_ufc_local"
        cp "$_ufc_local" "$_ufc_part" 2>>"${EXAKIT_LOG_FILE:-/dev/null}" || {
            rm -f "$_ufc_part"
            _udf_fail 5 download "" "The container $_ufc_name is not in EXAKIT_UDF_CONTAINERS_MIRROR ($_ufc_local)."; return 1; }
    else
        info "Downloading the $_ufc_lang container ($_ufc_mb, checked against its SHA-256) from $_ufc_src"
        EXAKIT_ACTIVE_LABEL="Downloading the $_ufc_lang container ($_ufc_mb)"
        # The read-only flag keeps a miss out of the failure note; the refusal
        # below is the answer. fetch retries and resumes on its own.
        EXAKIT_READONLY_QUERY=1 fetch_quiet "$_ufc_src" "$_ufc_part" || {
            rm -f "$_ufc_part"
            EXAKIT_ACTIVE_LABEL=""
            _udf_fail 5 download "exakit udf-use default" "The container could not be downloaded from $_ufc_src. Retry when online, or set EXAKIT_UDF_CONTAINERS_MIRROR to a folder or URL holding $_ufc_name."; return 1; }
        EXAKIT_ACTIVE_LABEL=""
    fi
    _ufc_err="$EXAKIT_HOME/.udf-verify.err"
    if ! _udf_rules verify "$_ufc_part" "$UDF_CONTAINER_SHA256" "$UDF_CONTAINER_SIZE" 2>"$_ufc_err"; then
        _ufc_why="$(cat "$_ufc_err" 2>/dev/null)"; rm -f "$_ufc_err" "$_ufc_part"
        _udf_fail 4 verify "exakit udf-use default" "The container $_ufc_name does not match its pinned digest (${_ufc_why:-size or sha256 differ}); it was removed. Run this again to download it afresh; if it fails again the release asset changed and the kit needs an update."; return 1
    fi
    rm -f "$_ufc_err"
    mv -f "$_ufc_part" "$UDF_CONTAINER_FILE" || { _udf_fail 5 download "" "Could not keep $UDF_CONTAINER_FILE."; return 1; }
    ok "Verified $_ufc_name (sha256 $(printf '%s' "$UDF_CONTAINER_SHA256" | cut -c1-12)..., $UDF_CONTAINER_SIZE bytes)"
    return 0
}

# _udf_record_language <language> — components.udf_devkit.languages, a comma
# list, each language once.
_udf_record_language() {
    _url_have="$(manifest_get components.udf_devkit.languages 2>/dev/null || true)"
    case ",$_url_have," in
        *",$1,"*) return 0 ;;
    esac
    if [ -z "$_url_have" ]; then
        manifest_set components.udf_devkit.languages "$1"
    else
        manifest_set components.udf_devkit.languages "$_url_have,$1"
    fi
}

# udf_devkit_installed_aliases — the aliases of the installed containers.
udf_devkit_installed_aliases() {
    _udf_slc list --json 2>>"${EXAKIT_LOG_FILE:-/dev/null}" | _udf_tool aliases
}

# udf_devkit_smoke <alias> [package[==version] ...] — create and run the smoke
# UDF; prints what it found and keeps the "name version" lines in
# UDF_SMOKE_LINES (for --json); 3 when a declared package is missing, 7 when
# one pinned ==version is reported with another version or the UDF did not
# run (UDF_FAIL_* say which).
udf_devkit_smoke() {
    _us_alias="$1"; shift
    UDF_SMOKE_LINES=""
    _us_out="$(_udf_tool smoke "$_us_alias" "$EXAKIT_UDF_SCHEMA" "$@" 2>"$EXAKIT_HOME/.udf-smoke.err")"
    _us_rc=$?
    _us_err="$(tail -1 "$EXAKIT_HOME/.udf-smoke.err" 2>/dev/null)"; rm -f "$EXAKIT_HOME/.udf-smoke.err"
    UDF_SMOKE_LINES="$_us_out"
    if [ "$_us_rc" -ne 0 ]; then
        [ "$_us_rc" = 3 ] || _us_rc=7
        warn "The smoke UDF on $_us_alias did not pass: ${_us_err:-no output}"
        _udf_fail "$_us_rc" smoke "exakit udf-use default" "The smoke UDF on $_us_alias did not pass: ${_us_err:-no output}"
        return "$_us_rc"
    fi
    ok "Python UDFs run on $_us_alias (Python $(printf '%s\n' "$_us_out" | sed -n 's/^python //p'))"
    [ "${EXAKIT_QUIET_DETAIL:-0}" = 1 ] || printf '%s\n' "$_us_out" | grep -v '^python ' | while read -r _us_name _us_version; do
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

# udf_devkit_setup_container [force] — the official Python container when it
# is missing (or forced), then the smoke UDF. Non-zero with UDF_FAIL_* set.
udf_devkit_setup_container() {
    UDF_CONTAINER_URL=""; UDF_CONTAINER_SHA256=""; UDF_CONTAINER_DB_VERSIONS=""
    UDF_CONTAINER_ARCH="$(_udf_arch 2>/dev/null || true)"
    _udf_ready install || return 1
    if [ "${1:-0}" = 1 ] || ! udf_devkit_installed_aliases | grep -qx "$EXAKIT_UDF_OFFICIAL_ALIAS"; then
        _udf_with_restart "Installing the official $EXAKIT_UDF_OFFICIAL_ALIAS container" \
            _udf_slc install "$EXAKIT_UDF_OFFICIAL_ALIAS" --auto-approve
        case $? in
            0) ;;
            5) _udf_fail 5 install "exakit udf-setup --yes" "The install was not confirmed; nothing changed."; return 1 ;;
            *) _udf_fail 6 install "exakit logs" "The launcher could not install the $EXAKIT_UDF_OFFICIAL_ALIAS container (see: exakit logs)."; return 1 ;;
        esac
    else
        ok "The official $EXAKIT_UDF_OFFICIAL_ALIAS container is already installed"
    fi
    udf_devkit_smoke "$EXAKIT_UDF_OFFICIAL_ALIAS" || return 1
    _udf_record_language python
}

# udf_devkit_setup_default — the prebuilt Python container of the matrix for
# this database (ML1.2): select, download or reuse the cache, verify, install
# as PYTHON3_ML, and the smoke UDF compares each package's version with the
# pin. Non-zero with UDF_FAIL_* set.
udf_devkit_setup_default() {
    _udf_ready select-container || return 1
    _udf_select_container python || return 1
    _udf_fetch_container python || return 1
    _usd_pins="$(_udf_rules pins "$(exakit_versions_active_doc)" python "$UDF_CONTAINER_ARCH" "$UDF_CONTAINER_DB" 2>/dev/null | sed 's/ /==/')"
    # shellcheck disable=SC2086 -- one name==version per word
    _udf_install_tarball "$UDF_CONTAINER_FILE" "$EXAKIT_UDF_DEFAULT_ALIAS" python "$UDF_CONTAINER_URL" $_usd_pins || return 1
    _udf_record_language python
}

# udf_devkit_setup_rust — the Rust container of the matrix (alias RUST): the
# same select, download, verify and launcher install, through the restart. No
# smoke UDF yet: it arrives with the next kit step, so the add-on is recorded
# as not validated until then. Non-zero with UDF_FAIL_* set.
udf_devkit_setup_rust() {
    _udf_ready select-container || return 1
    _udf_select_container rust || return 1
    _udf_fetch_container rust || return 1
    _usr_verb=install
    udf_devkit_installed_aliases | grep -qx "$EXAKIT_UDF_RUST_ALIAS" && _usr_verb=update
    _udf_with_restart "Installing the $EXAKIT_UDF_RUST_ALIAS container" \
        _udf_slc custom "$_usr_verb" --source "$UDF_CONTAINER_FILE" --alias "$EXAKIT_UDF_RUST_ALIAS" --language rust --auto-approve
    case $? in
        0) ;;
        5) _udf_fail 5 install "exakit udf-setup --language rust --yes" "The install was not confirmed; nothing changed."; return 1 ;;
        *) _udf_fail 6 install "exakit logs" "The launcher could not install the $EXAKIT_UDF_RUST_ALIAS container (see: exakit logs)."; return 1 ;;
    esac
    manifest_set "components.udf_devkit.containers.$EXAKIT_UDF_RUST_ALIAS" "$UDF_CONTAINER_URL"
    _udf_record_language rust
    manifest_set components.udf_devkit.validated false
    UDF_SMOKE_LINES=""
    ok "Rust UDFs: the $EXAKIT_UDF_RUST_ALIAS container is installed (rustc $(_udf_row runtime | sed 's/.*"rustc": *"\([^"]*\)".*/\1/'), exasol-udf-sdk $(_udf_rules pins "$(exakit_versions_active_doc)" rust "$UDF_CONTAINER_ARCH" "$UDF_CONTAINER_DB" 2>/dev/null | awk '$1 == "exasol-udf-sdk" {print $2}'))"
    info "The Rust smoke UDF arrives with the next kit step; until then: exasol slc list shows $EXAKIT_UDF_RUST_ALIAS"
    return 0
}

udf_devkit_install() {
    [ -n "${EXAKIT_UDF_DEVKIT_VERSION:-}" ] || EXAKIT_UDF_DEVKIT_VERSION="$(udf_devkit_latest)"
    if ! udf_devkit_require_launcher; then
        command -v exakit_note_failure >/dev/null 2>&1 && exakit_note_failure "the Exasol launcher is older than $EXAKIT_UDF_MIN_LAUNCHER"
        return 1
    fi
    # EXAKIT_UDF_LANGUAGE picks what the install sets up; a value that is
    # neither language is refused before anything is recorded.
    _udi_lang="$(_udf_language)" || {
        warn "$_udi_lang"
        command -v exakit_note_failure >/dev/null 2>&1 && exakit_note_failure "EXAKIT_UDF_LANGUAGE is not python or rust"
        return 1
    }
    manifest_set components.udf_devkit.version "$EXAKIT_UDF_DEVKIT_VERSION"
    manifest_set components.udf_devkit.schema "$EXAKIT_UDF_SCHEMA"
    # The container is part of the install; with no database up, it is the
    # first thing `exakit udf-setup` does.
    if ! exakit_db_reachable; then
        info "Start the database, then set up $_udi_lang UDFs with: exakit udf-setup --language $_udi_lang"
    elif [ "$_udi_lang" = rust ]; then
        _UDF_YES=1 udf_devkit_setup_rust || warn "Rust UDFs are not set up yet (${UDF_FAIL_MSG:-see the log}) - run: exakit udf-setup --language rust"
    else
        _UDF_YES=1 udf_devkit_setup_container 0 || warn "Python UDFs are not set up yet - run: exakit udf-setup"
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
    case ",$(manifest_get components.udf_devkit.languages 2>/dev/null || true)," in
        *,rust,*) printf 'Python UDFs: exakit udf-setup; Rust UDFs: alias %s (exasol slc list)\n' "$EXAKIT_UDF_RUST_ALIAS" ;;
        *) printf 'Python UDFs: exakit udf-setup\n' ;;
    esac
}

udf_devkit_uninstall() {
    if [ "${1:-0}" = "1" ]; then
        [ -e "$EXAKIT_UDF_DEVKIT_HOME" ] && info "  will remove: $EXAKIT_UDF_DEVKIT_HOME"
        info "  containers stay installed in the database (exasol slc remove <alias> removes one)"
        info "  model files stay in the deployment's bucket directory; only their record goes"
        return 0
    fi
    command -v udf_devkit_stop >/dev/null 2>&1 && udf_devkit_stop || true
    rm -rf "$EXAKIT_UDF_DEVKIT_HOME"
    manifest_del components.udf_devkit
    manifest_del desired.udf_devkit
    info "Containers stay installed in the database; remove one with: exasol slc remove <alias> ($EXAKIT_UDF_DEFAULT_ALIAS, $EXAKIT_UDF_BUILD_ALIAS, $EXAKIT_UDF_RUST_ALIAS)"
    ok_step "udf-devkit removed — reinstall any time with: exakit marketplace udf-devkit"
    return 0
}

# --- the commands ------------------------------------------------------------------

_udf_require_installed() {
    [ -n "$(udf_devkit_installed_version || true)" ] || die "The UDF dev kit is not installed. Install it with: exakit marketplace udf-devkit"
}

# _udf_require_installed_for <language> — the udf-setup and udf-use form of the
# check: a refusal (5, step select-container) with the marketplace as remedy.
_udf_require_installed_for() {
    [ -n "$(udf_devkit_installed_version || true)" ] || \
        _udf_refuse 5 "$1" select-container "exakit marketplace udf-devkit" "The UDF dev kit is not installed."
}

# _udf_install_tarball <tarball> <alias> <language> <source> [package[==version] ...]
# — the launcher installs (or updates) the container under the alias through
# the restart, the smoke UDF proves it (Python; a Rust container has no smoke
# UDF yet and is recorded as not validated), and the alias is recorded with
# where the container came from. Non-zero with UDF_FAIL_* set.
_udf_install_tarball() {
    _uit_tar="$1"; _uit_alias="$2"; _uit_language="$3"; _uit_source="$4"; shift 4
    _uit_verb=install
    udf_devkit_installed_aliases | grep -qx "$_uit_alias" && _uit_verb=update
    _udf_with_restart "Installing the container as $_uit_alias" \
        _udf_slc custom "$_uit_verb" --source "$_uit_tar" --alias "$_uit_alias" --language "$_uit_language" --auto-approve
    case $? in
        0) ;;
        5) _udf_fail 5 install "" "The install was not confirmed; nothing changed."; return 1 ;;
        *) _udf_fail 6 install "exakit logs" "The launcher could not install the container as $_uit_alias (see: exakit logs)."; return 1 ;;
    esac
    if [ "$_uit_language" = rust ]; then
        manifest_set components.udf_devkit.validated false
        UDF_SMOKE_LINES=""
        info "The Rust smoke UDF arrives with the next kit step; until then: exasol slc list shows $_uit_alias"
    else
        udf_devkit_smoke "$_uit_alias" "$@" || return 1
    fi
    manifest_set "components.udf_devkit.containers.$_uit_alias" "$_uit_source"
}

# cmd_udf_setup [--language python|rust] [--force] [--yes] [--json] — the
# official Python container (PYTHON3) or the matrix's Rust container (RUST).
cmd_udf_setup() {
    _ucs_force=0; _ucs_lang="$EXAKIT_UDF_LANGUAGE"; _ucs_json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) _ucs_force=1 ;;
            --yes|-y) _UDF_YES=1 ;;
            --json|-j) _ucs_json=1; EXAKIT_REFUSAL_JSON=1 ;;
            --language) shift; [ -n "${1:-}" ] || reject "--language needs python or rust"; _ucs_lang="$1" ;;
            *) reject "udf-setup takes --force (reinstall the container), --language python|rust, --yes and --json, nothing else: $1" ;;
        esac
        shift
    done
    _ucs_lang="$(_udf_language "$_ucs_lang")" || reject "$_ucs_lang"
    [ "$_ucs_json" = 1 ] && _udf_json_mode
    _udf_require_installed_for "$_ucs_lang"
    if [ "$_ucs_lang" = rust ]; then
        udf_devkit_setup_rust || _udf_raise_fail rust
        _udf_done rust "$EXAKIT_UDF_RUST_ALIAS"
    else
        udf_devkit_setup_container "$_ucs_force" || _udf_raise_fail python
        _udf_done python "$EXAKIT_UDF_OFFICIAL_ALIAS"
    fi
}

# cmd_udf_use default|<container.tar.gz> [--language python|rust] [--alias NAME]
# [--yes] [--json] | --list — default is the matrix's container for this
# database (Python: PYTHON3_ML; rust: RUST); a tarball is yours.
cmd_udf_use() {
    _ucu_what=""; _ucu_alias=""; _ucu_list=0; _ucu_lang="$EXAKIT_UDF_LANGUAGE"; _ucu_json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --list) _ucu_list=1 ;;
            --yes|-y) _UDF_YES=1 ;;
            --json|-j) _ucu_json=1; EXAKIT_REFUSAL_JSON=1 ;;
            --alias) shift; [ -n "${1:-}" ] || reject "--alias needs a name"; _ucu_alias="$1" ;;
            --language) shift; [ -n "${1:-}" ] || reject "--language needs python or rust"; _ucu_lang="$1" ;;
            -*) reject "Unknown option for udf-use: $1 (supported: --alias, --language, --list, --yes, --json)" ;;
            *) [ -z "$_ucu_what" ] || reject "Name one thing to install: default, or one container tarball"; _ucu_what="$1" ;;
        esac
        shift
    done
    _ucu_lang="$(_udf_language "$_ucu_lang")" || reject "$_ucu_lang"
    if [ "$_ucu_list" = 1 ]; then
        _udf_require_installed
        _udf_slc list 2>&1
        return 0
    fi
    [ -n "$_ucu_what" ] || reject "Name what to install: exakit udf-use default, or exakit udf-use <container.tar.gz>."
    if [ "$_ucu_what" != default ]; then
        case "$_ucu_what" in *.tar.gz|*.tgz) ;; *) reject "$_ucu_what is not a container tarball (.tar.gz)." ;; esac
        [ -f "$_ucu_what" ] || reject "$_ucu_what is not a file."
        _ucu_err="$EXAKIT_HOME/.udf-alias.err"
        _ucu_alias="$(_udf_rules identifier "${_ucu_alias:-$EXAKIT_UDF_BUILD_ALIAS}" 2>"$_ucu_err")" || { _ucu_why="$(cat "$_ucu_err")"; rm -f "$_ucu_err"; reject "$_ucu_why"; }
        rm -f "$_ucu_err"
    fi
    [ "$_ucu_json" = 1 ] && _udf_json_mode
    _udf_require_installed_for "$_ucu_lang"
    if [ "$_ucu_what" = default ]; then
        if [ "$_ucu_lang" = rust ]; then
            udf_devkit_setup_rust || _udf_raise_fail rust
            _udf_done rust "$EXAKIT_UDF_RUST_ALIAS"
        else
            udf_devkit_setup_default || _udf_raise_fail python
            _udf_done python "$EXAKIT_UDF_DEFAULT_ALIAS"
        fi
        return 0
    fi
    UDF_CONTAINER_URL=""; UDF_CONTAINER_SHA256=""; UDF_CONTAINER_DB_VERSIONS=""
    UDF_CONTAINER_ARCH="$(_udf_arch 2>/dev/null || true)"
    _udf_ready install || _udf_raise_fail "$_ucu_lang"
    _udf_install_tarball "$_ucu_what" "$_ucu_alias" "$_ucu_lang" "$_ucu_what" || _udf_raise_fail "$_ucu_lang"
    _udf_done "$_ucu_lang" "$_ucu_alias"
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
    _udf_install_tarball "$_ucb_tar" "$_ucb_alias" python "$_ucb_req" $(printf '%s\n' "$_ucb_pins" | sed 's/==.*//') || {
        [ "${UDF_FAIL_STEP:-}" = smoke ] || die "$UDF_FAIL_MSG"
        return 1
    }
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
        put|list|rm|template)
            case " $* " in
                *" --help "*|*" -h "*) exakit_help_render command "exakit model $_cm_sub"; return $? ;;
            esac
            "_cmd_model_$_cm_sub" "$@" ;;
        "") reject "Name what to do: exakit model put <file> | exakit model list | exakit model rm <name> | exakit model template (exakit model --help)." ;;
        *) reject "Unknown model command '$_cm_sub' (supported: put, list, rm, template)." ;;
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
        6) _model_refuse 6 "" "$_cmp_why" ;;
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
    printf '%s\n' "$_cmp_answer" | run_python_any -c 'import json,sys; w=json.load(sys.stdin).get("warning"); print("  Warning: "+w if w else "")' | sed '/^$/d'
}

_cmd_model_rm() {
    _cmr_name=""; _cmr_json=0
    for _cmr_arg in "$@"; do
        case "$_cmr_arg" in
            --json|-j) _cmr_json=1; EXAKIT_REFUSAL_JSON=1 ;;
            -*) reject "Unknown option '$_cmr_arg' for model rm (supported: --json)." ;;
            *) [ -z "$_cmr_name" ] || reject "Name one model: exakit model rm <name>"; _cmr_name="$_cmr_arg" ;;
        esac
    done
    [ -n "$_cmr_name" ] || reject "Name the model: exakit model rm <name>"
    _model_ready
    _cmr_err="$EXAKIT_HOME/.model-rm.err"
    _cmr_out="$(_model_record | _model_tool rm "$_cmr_name" "$UDF_BUCKET_DIR" "$UDF_BUCKET_UDF_ROOT" 2>"$_cmr_err")"
    _cmr_rc=$?
    _cmr_why="$(cat "$_cmr_err" 2>/dev/null)"; rm -f "$_cmr_err"
    case "$_cmr_rc" in
        0) ;;
        5) _model_refuse 5 "" "$_cmr_why" ;;
        2) reject "$_cmr_why" ;;
        *) die "Could not remove $_cmr_name: ${_cmr_why:-no reason given}" ;;
    esac
    manifest_set components.udf_devkit.models "$(printf '%s\n' "$_cmr_out" | sed -n 2p)"
    if [ "$_cmr_json" = 1 ]; then
        exakit_json_pretty "$(printf '%s\n' "$_cmr_out" | sed -n 1p)"
    else
        ok "Removed $_cmr_name from the bucket directory and the kit's record"
    fi
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
