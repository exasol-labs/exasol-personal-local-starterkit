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
#     same way, alias RUST, and proves it with the kit's prebuilt Rust smoke
#     UDF: the row's smoke_asset (libexakit_smoke.so for the arch, built by
#     CI in .github/workflows/rust-smoke.yml from udf/rust-smoke with the
#     container's rustc) is downloaded and verified before the install,
#     copied into the bucket directory under udf/ and registered as
#     STARTER_KIT.EXAKIT_SMOKE(x BIGINT); it reports the container, rustc and
#     exasol-udf-sdk versions, held against the row (exit 7 on a mismatch, or
#     when the container refuses the library: F-UDF-CL-RUST-9001).
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
# The Rust smoke UDF (design 5): where its library lands in the bucket, the
# schema it is registered in, its name (udf_tool.py: EXAKIT_SMOKE).
EXAKIT_UDF_RUST_SMOKE_SCHEMA="STARTER_KIT"
EXAKIT_UDF_RUST_SMOKE_DIR="udf"
EXAKIT_UDF_RUST_SMOKE_LIB="libexakit_smoke.so"
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
# version, and - a Rust setup - "steps", one per language it installed or
# kept, UDF_DONE_STEPS); otherwise the steps have already said it.
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
    _ud_steps=""
    [ -z "${UDF_DONE_STEPS:-}" ] || _ud_steps=", \"steps\": [$UDF_DONE_STEPS]"
    exakit_json_out '{"ok": true, "language": "%s", "alias": "%s", "container": {"url": %s, "sha256": %s, "arch": %s, "db_versions": %s}, "smoke": [%s]%s}\n' \
        "$1" "$2" "$_ud_url" "$_ud_sha" "$_ud_arch" "$_ud_range" "$_ud_smoke" "$_ud_steps" >&"$_UDF_STDOUT"
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
    # A cached release catalog may predate this installed kit's UDF matrix even
    # when its publication date is newer. The container and smoke pins belong
    # to the code shipping with this kit, so resolve them from that copy.
    UDF_CONTAINER_DOC="$(exakit_versions_baked_doc 2>/dev/null)" || {
        _udf_fail 4 select-container "exakit update" "This kit copy has no readable versions.json to pick a container from."; return 1; }
    _usc_err="$EXAKIT_HOME/.udf-select.err"
    _usc_arch="$(_udf_rules arch "$(uname -m 2>/dev/null || true)" "$(_udf_os)" 2>"$_usc_err")" || {
        _usc_why="$(cat "$_usc_err" 2>/dev/null)"; rm -f "$_usc_err"
        _udf_fail 4 select-container "" "${_usc_why:-The architecture of this machine is not known.}"; return 1; }
    _usc_db="$(_udf_db_version)"
    [ -n "$_usc_db" ] || { rm -f "$_usc_err"; _udf_fail 5 select-container "exakit status" "The database version is not known: is the database running?"; return 1; }
    UDF_CONTAINER_ROW="$(_udf_rules resolve "$UDF_CONTAINER_DOC" "$_usc_lang" "$_usc_arch" "$_usc_db" 2>"$_usc_err")" || {
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
# anything installs it (_udf_fetch_verified).
_udf_fetch_container() {
    _udf_fetch_verified "$1" container "$UDF_CONTAINER_URL" "$UDF_CONTAINER_SHA256" "$UDF_CONTAINER_SIZE" "exakit udf-use default" || return 1
    UDF_CONTAINER_FILE="$UDF_FETCHED_FILE"
}

# _udf_fetch_verified <language> <what> <url> <sha256> <size> <retry remedy> —
# a pinned release asset (the container tarball, the Rust smoke library) into
# the cache (UDF_FETCHED_FILE), verified against its pinned size and sha256
# before anything uses it: a cached file that verifies is reused; otherwise it
# is downloaded (resumed and retried by fetch) or copied from
# EXAKIT_UDF_CONTAINERS_MIRROR (a folder, file:// or https:// base URL holding
# the file by name) into a .part that is renamed only once it verifies. A
# mismatch is _udf_fail 4 (step verify) and the file is removed, so running
# the command again downloads it afresh; a download that did not arrive is 5
# (step download).
_udf_fetch_verified() {
    _ufc_lang="$1"; _ufc_what="$2"; _ufc_sha="$4"; _ufc_size="$5"; _ufc_remedy="$6"
    _ufc_url="$3"
    _ufc_name="$(basename "$_ufc_url")"
    UDF_FETCHED_FILE="$EXAKIT_UDF_CONTAINER_CACHE/$_ufc_name"
    mkdir -p "$EXAKIT_UDF_CONTAINER_CACHE" 2>/dev/null || {
        _udf_fail 5 download "" "Could not create the container cache $EXAKIT_UDF_CONTAINER_CACHE."; return 1; }
    if [ -f "$UDF_FETCHED_FILE" ] && _udf_rules verify "$UDF_FETCHED_FILE" "$_ufc_sha" "$_ufc_size" 2>/dev/null; then
        ok "Using the cached $_ufc_what $UDF_FETCHED_FILE (digest verified)"
        return 0
    fi
    _ufc_src="$_ufc_url"; _ufc_local=""
    if [ -n "${EXAKIT_UDF_CONTAINERS_MIRROR:-}" ]; then
        case "$EXAKIT_UDF_CONTAINERS_MIRROR" in
            https://*) _ufc_src="${EXAKIT_UDF_CONTAINERS_MIRROR%/}/$_ufc_name" ;;
            file://*)  _ufc_local="${EXAKIT_UDF_CONTAINERS_MIRROR#file://}"; _ufc_local="${_ufc_local%/}/$_ufc_name"; _ufc_src="$_ufc_local" ;;
            *://*)     _udf_fail 5 download "" "EXAKIT_UDF_CONTAINERS_MIRROR must be a folder, a file:// URL or an https:// URL (got '$EXAKIT_UDF_CONTAINERS_MIRROR')."; return 1 ;;
            *)         _ufc_local="${EXAKIT_UDF_CONTAINERS_MIRROR%/}/$_ufc_name"; _ufc_src="$_ufc_local" ;;
        esac
    fi
    _ufc_mb="$(awk -v b="${_ufc_size:-0}" 'BEGIN { printf "%d MB", b / 1000000 }')"
    _ufc_part="$UDF_FETCHED_FILE.part"
    rm -f "$UDF_FETCHED_FILE"
    if [ -n "$_ufc_local" ]; then
        info "Copying the $_ufc_lang $_ufc_what ($_ufc_mb) from $_ufc_local"
        cp "$_ufc_local" "$_ufc_part" 2>>"${EXAKIT_LOG_FILE:-/dev/null}" || {
            rm -f "$_ufc_part"
            _udf_fail 5 download "" "The $_ufc_what $_ufc_name is not in EXAKIT_UDF_CONTAINERS_MIRROR ($_ufc_local)."; return 1; }
    else
        info "Downloading the $_ufc_lang $_ufc_what ($_ufc_mb, checked against its SHA-256) from $_ufc_src"
        EXAKIT_ACTIVE_LABEL="Downloading the $_ufc_lang $_ufc_what ($_ufc_mb)"
        # The read-only flag keeps a miss out of the failure note; the refusal
        # below is the answer. fetch retries and resumes on its own.
        EXAKIT_READONLY_QUERY=1 fetch_quiet "$_ufc_src" "$_ufc_part" || {
            rm -f "$_ufc_part"
            EXAKIT_ACTIVE_LABEL=""
            _udf_fail 5 download "$_ufc_remedy" "The $_ufc_what could not be downloaded from $_ufc_src. Retry when online, or set EXAKIT_UDF_CONTAINERS_MIRROR to a folder or URL holding $_ufc_name."; return 1; }
        EXAKIT_ACTIVE_LABEL=""
    fi
    exakit_addon_activity "Verifying $_ufc_name size and SHA-256"
    _ufc_err="$EXAKIT_HOME/.udf-verify.err"
    if ! _udf_rules verify "$_ufc_part" "$_ufc_sha" "$_ufc_size" 2>"$_ufc_err"; then
        _ufc_why="$(cat "$_ufc_err" 2>/dev/null)"; rm -f "$_ufc_err" "$_ufc_part"
        _udf_fail 4 verify "$_ufc_remedy" "The $_ufc_what $_ufc_name does not match its pinned digest (${_ufc_why:-size or sha256 differ}); it was removed. Run this again to download it afresh; if it fails again the release asset changed and the kit needs an update."; return 1
    fi
    rm -f "$_ufc_err"
    mv -f "$_ufc_part" "$UDF_FETCHED_FILE" || { _udf_fail 5 download "" "Could not keep $UDF_FETCHED_FILE."; return 1; }
    ok "Verified $_ufc_name (sha256 $(printf '%s' "$_ufc_sha" | cut -c1-12)..., $_ufc_size bytes)"
    return 0
}

# _udf_rust_smoke_asset — the selected Rust row's smoke_asset (url, sha256,
# size) into UDF_SMOKE_URL, UDF_SMOKE_SHA256 and UDF_SMOKE_SIZE; 1 when the
# row carries no pinned asset yet (the placeholders a kit ships before the
# first CI build: no url, a sha256 that is not 64 hex digits, a size that is
# not a number), with UDF_SMOKE_WHY saying so.
_udf_rust_smoke_asset() {
    UDF_SMOKE_URL=""; UDF_SMOKE_SHA256=""; UDF_SMOKE_SIZE=""; UDF_SMOKE_WHY=""
    UDF_SMOKE_BUNDLED=""; UDF_SMOKE_CORRUPT=0
    _ursa_asset="$(_udf_row smoke_asset)"
    [ -n "$_ursa_asset" ] || { UDF_SMOKE_WHY="the row has no smoke_asset"; return 1; }
    UDF_SMOKE_URL="$(printf '%s' "$_ursa_asset" | _udf_rules field url 2>/dev/null)"
    UDF_SMOKE_SHA256="$(printf '%s' "$_ursa_asset" | _udf_rules field sha256 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    UDF_SMOKE_SIZE="$(printf '%s' "$_ursa_asset" | _udf_rules field size 2>/dev/null)"
    case "$UDF_SMOKE_SHA256" in
        *[!0-9a-f]*|"") UDF_SMOKE_WHY="its sha256 is a placeholder (set after the first CI build)"; return 1 ;;
    esac
    [ "${#UDF_SMOKE_SHA256}" -eq 64 ] || { UDF_SMOKE_WHY="its sha256 is not 64 hex digits"; return 1; }
    case "$UDF_SMOKE_SIZE" in *[!0-9]*|"") UDF_SMOKE_WHY="its size is a placeholder (set after the first CI build)"; return 1 ;; esac
    _ursa_path="$(printf '%s' "$_ursa_asset" | _udf_rules field bundled_path 2>/dev/null)"
    if [ -n "$_ursa_path" ]; then
        case "$_ursa_path" in
            udf/rust-smoke/prebuilt/*)
                _ursa_name="${_ursa_path##*/}"
                case "$_ursa_name" in *[!A-Za-z0-9._-]*|""|.*) UDF_SMOKE_WHY="its bundled_path has an unsafe name"; UDF_SMOKE_CORRUPT=1; return 1 ;; esac
                [ "$_ursa_path" = "udf/rust-smoke/prebuilt/$_ursa_name" ] || { UDF_SMOKE_WHY="its bundled_path is nested"; UDF_SMOKE_CORRUPT=1; return 1; }
                ;;
            *) UDF_SMOKE_WHY="its bundled_path is outside the Rust smoke assets"; UDF_SMOKE_CORRUPT=1; return 1 ;;
        esac
        _ursa_file="$(exakit_repo_root)/$_ursa_path"
        if [ -f "$_ursa_file" ]; then
            if ! _udf_rules verify "$_ursa_file" "$UDF_SMOKE_SHA256" "$UDF_SMOKE_SIZE" >/dev/null 2>&1; then
                UDF_SMOKE_WHY="the bundled library failed its size or SHA-256 check"
                UDF_SMOKE_CORRUPT=1
                return 1
            fi
            UDF_SMOKE_BUNDLED="$_ursa_file"
            return 0
        fi
    fi
    case "$UDF_SMOKE_URL" in https://*|http://*) ;; *) UDF_SMOKE_WHY="its url is not set"; return 1 ;; esac
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

# _udf_python_alias — the alias of an installed Python container (the kit's
# three, official first), or nothing. Training is Python-only, so a Rust
# install adds the official one when this says nothing (design 5: rust adds,
# never replaces). The record's language list counts too: a Python container
# of the user's own (udf-use <tarball> --alias X) was recorded by the kit.
_udf_python_alias() {
    _upa_aliases="$(udf_devkit_installed_aliases)"
    for _upa_alias in "$EXAKIT_UDF_OFFICIAL_ALIAS" "$EXAKIT_UDF_DEFAULT_ALIAS" "$EXAKIT_UDF_BUILD_ALIAS"; do
        if printf '%s\n' "$_upa_aliases" | grep -qx "$_upa_alias"; then
            printf '%s\n' "$_upa_alias"
            return 0
        fi
    done
    case ",$(manifest_get components.udf_devkit.languages 2>/dev/null || true)," in
        *,python,*) printf '%s\n' "$(manifest_get components.udf_devkit.python_alias 2>/dev/null || printf '%s' "$EXAKIT_UDF_OFFICIAL_ALIAS")"; return 0 ;;
    esac
    return 1
}

# udf_devkit_smoke <alias> [package[==version] ...] — create and run the smoke
# UDF; prints what it found and keeps the "name version" lines in
# UDF_SMOKE_LINES (for --json); 3 when a declared package is missing, 7 when
# one pinned ==version is reported with another version or the UDF did not
# run (UDF_FAIL_* say which).
udf_devkit_smoke() {
    _us_alias="$1"; shift
    exakit_addon_activity "Checking Python packages inside $_us_alias"
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

# udf_devkit_smoke_rust <alias> — prove the Rust container with the kit's
# prebuilt smoke library (UDF_SMOKE_FILE, fetched and verified by
# udf_devkit_setup_rust): copy it into the deployment's bucket directory as
# udf/libexakit_smoke.so (the same folder a user's Rust UDF goes to), register
# STARTER_KIT.EXAKIT_SMOKE(x BIGINT) over it and run it once; the "name
# version" lines (container, rustc, sdk) are kept in UDF_SMOKE_LINES (for
# --json) and the rustc and sdk are held against the selected row (udf_tool.py
# smoke-rust). 7 (step smoke, both versions in the reason) when they differ or
# the container refused the library (F-UDF-CL-RUST-9001); 5 when there is no
# bucket directory to put the library into. On success the manifest records
# the row as validated (components.udf_devkit.rust: validated, rustc, sdk).
udf_devkit_smoke_rust() {
    _usr_alias="$1"
    UDF_SMOKE_LINES=""
    udf_bucket_locate || { _udf_fail 5 smoke "exakit status" "$UDF_BUCKET_ERROR"; return 1; }
    _usr_dest="$UDF_BUCKET_DIR/$EXAKIT_UDF_RUST_SMOKE_DIR/$EXAKIT_UDF_RUST_SMOKE_LIB"
    mkdir -p "$(dirname "$_usr_dest")" 2>/dev/null && cp "$UDF_SMOKE_FILE" "$_usr_dest.part" && mv -f "$_usr_dest.part" "$_usr_dest" || {
        rm -f "$_usr_dest.part"
        _udf_fail 5 smoke "exakit status" "Could not copy the smoke library into the bucket directory ($_usr_dest)."; return 1; }
    _usr_path="$UDF_BUCKET_UDF_ROOT/$EXAKIT_UDF_RUST_SMOKE_DIR/$EXAKIT_UDF_RUST_SMOKE_LIB"
    _usr_rustc="$(_udf_row runtime | sed 's/.*"rustc": *"\([^"]*\)".*/\1/')"
    _usr_sdk="$(_udf_rules pins "$UDF_CONTAINER_DOC" rust "$UDF_CONTAINER_ARCH" "$UDF_CONTAINER_DB" 2>/dev/null | awk '$1 == "exasol-udf-sdk" {print $2}')"
    info "Running the Rust smoke UDF $EXAKIT_UDF_RUST_SMOKE_SCHEMA.EXAKIT_SMOKE over $_usr_path"
    _usr_out="$(_udf_tool smoke-rust "$_usr_alias" "$EXAKIT_UDF_RUST_SMOKE_SCHEMA" "$_usr_path" "$_usr_rustc" "$_usr_sdk" 2>"$EXAKIT_HOME/.udf-smoke.err")"
    _usr_rc=$?
    _usr_err="$(tr '\n' ' ' < "$EXAKIT_HOME/.udf-smoke.err" 2>/dev/null | sed 's/ *$//')"; rm -f "$EXAKIT_HOME/.udf-smoke.err"
    UDF_SMOKE_LINES="$_usr_out"
    if [ "$_usr_rc" -ne 0 ]; then
        warn "The Rust smoke UDF on $_usr_alias did not pass: ${_usr_err:-no output}"
        manifest_set components.udf_devkit.rust.validated false
        _udf_fail 7 smoke "exakit udf-setup --language rust" "The Rust smoke UDF on $_usr_alias did not pass: ${_usr_err:-no output}"
        return 1
    fi
    _usr_got_rustc="$(printf '%s\n' "$_usr_out" | sed -n 's/^rustc //p' | head -1)"
    _usr_got_sdk="$(printf '%s\n' "$_usr_out" | sed -n 's/^sdk //p' | head -1)"
    ok "Rust UDFs run on $_usr_alias (rustc $_usr_got_rustc, exasol-udf-sdk $_usr_got_sdk - as pinned)"
    info "Use it in SQL: CREATE OR REPLACE $_usr_alias SCALAR SCRIPT ... AS %udf_object $UDF_BUCKET_UDF_ROOT/$EXAKIT_UDF_RUST_SMOKE_DIR/lib<name>.so;"
    manifest_set components.udf_devkit.rust.validated true
    manifest_set components.udf_devkit.rust.rustc "$_usr_got_rustc"
    manifest_set components.udf_devkit.rust.sdk "$_usr_got_sdk"
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
    exakit_addon_activity "Waiting for the database to restart"
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

# Standard Python archives declare PYTHON3/PYTHON312 inside the archive, even
# when the launcher is given a different --alias. Isolate that declaration so
# the ML runtime can coexist with the official container. Keep the verified
# original; the shared helper records both digests beside its cached derivative.
_udf_prepare_ml_container() {
    UDF_CONTAINER_INSTALL_FILE="$EXAKIT_UDF_CONTAINER_CACHE/$(basename "$UDF_CONTAINER_FILE" .tar.gz)-$EXAKIT_UDF_DEFAULT_ALIAS.tar.gz"
    exakit_addon_activity "Preparing isolated Python ML container aliases"
    EXAKIT_ACTIVE_LABEL="Preparing isolated Python ML container aliases"
    run_logged run_python_any "$(exakit_repo_root)/setup/udf/slc_archive.py" \
        "$UDF_CONTAINER_FILE" "$UDF_CONTAINER_INSTALL_FILE" "$EXAKIT_UDF_DEFAULT_ALIAS" "$UDF_CONTAINER_SHA256" || {
        _udf_fail 5 verify "exakit logs" "Could not prepare the isolated ML container (see: exakit logs)."
        return 1
    }
}

# udf_devkit_setup_default — the prebuilt Python container of the matrix for
# this database (ML1.2): select, download or reuse the cache, verify, install
# as PYTHON3_ML, and the smoke UDF compares each package's version with the
# pin. Non-zero with UDF_FAIL_* set.
udf_devkit_setup_default() {
    _udf_ready select-container || return 1
    _udf_select_container python || return 1
    _udf_fetch_container python || return 1
    _udf_prepare_ml_container || return 1
    _usd_pins="$(_udf_rules pins "$UDF_CONTAINER_DOC" python "$UDF_CONTAINER_ARCH" "$UDF_CONTAINER_DB" 2>/dev/null | sed 's/ /==/')"
    # shellcheck disable=SC2086 -- one name==version per word
    _udf_install_tarball "$UDF_CONTAINER_INSTALL_FILE" "$EXAKIT_UDF_DEFAULT_ALIAS" python "$UDF_CONTAINER_URL" $_usd_pins || return 1
    _udf_record_language python
}

# The add-on promises an ML-ready UDF runtime, independently of the notebook
# venv. Reuse and prove an existing ML alias; download it only when missing.
udf_devkit_ensure_ml() {
    if udf_devkit_installed_aliases | grep -qx "$EXAKIT_UDF_DEFAULT_ALIAS"; then
        _udf_select_container python || return 1
        _uem_pins="$(_udf_rules pins "$UDF_CONTAINER_DOC" python "$UDF_CONTAINER_ARCH" "$UDF_CONTAINER_DB" 2>/dev/null | sed 's/ /==/')"
        # shellcheck disable=SC2086
        udf_devkit_smoke "$EXAKIT_UDF_DEFAULT_ALIAS" $_uem_pins || return 1
        manifest_set components.udf_devkit.python_alias "$EXAKIT_UDF_DEFAULT_ALIAS"
    else
        exakit_addon_activity "Preparing scikit-learn, pandas, NumPy and SciPy for UDFs"
        udf_devkit_setup_default || return 1
    fi
}

# udf_devkit_setup_rust [force] — the Rust container of the matrix (alias
# RUST): select, download and verify the container AND the row's smoke
# library (so a bad download never costs a restart), the launcher install
# through the restart (skipped when RUST is already installed, unless forced:
# udf-setup proves what is there, udf-use default updates it), then the Rust
# smoke UDF. A row whose smoke_asset is still a placeholder (before the first
# CI build) installs the container and stops at step smoke (7), so the
# container is never reported as proven when it was not. Non-zero with
# UDF_FAIL_* set.
udf_devkit_setup_rust() {
    _udf_ready select-container || return 1
    _udf_select_container rust || return 1
    _udf_fetch_container rust || return 1
    UDF_SMOKE_FILE=""
    if _udf_rust_smoke_asset; then
        if [ -n "$UDF_SMOKE_BUNDLED" ]; then
            UDF_SMOKE_FILE="$UDF_SMOKE_BUNDLED"
        else
            _udf_fetch_verified rust "smoke UDF library" "$UDF_SMOKE_URL" "$UDF_SMOKE_SHA256" "$UDF_SMOKE_SIZE" "exakit udf-setup --language rust" || return 1
            UDF_SMOKE_FILE="$UDF_FETCHED_FILE"
        fi
    elif [ "$UDF_SMOKE_CORRUPT" = 1 ]; then
        _udf_fail 7 verify "exakit update" "Rust smoke library refused: $UDF_SMOKE_WHY"
        return 1
    fi
    _usr_verb=install
    udf_devkit_installed_aliases | grep -qx "$EXAKIT_UDF_RUST_ALIAS" && _usr_verb=update
    # Rust adds, never replaces (design 5, G2 C1): training runs Python UDFs,
    # so when no Python container is installed the official one goes in with
    # the same restart - the Rust install is recorded without a restart
    # (--no-restart) and the Python install's restart activates both. Said up
    # front, in the one confirmation.
    _usr_python="$(_udf_python_alias || true)"
    _usr_add_python=0
    [ -n "$_usr_python" ] || _usr_add_python=1
    UDF_DONE_STEPS=""
    _usr_rust_action=kept
    if [ "$_usr_verb" = update ] && [ "${1:-0}" != 1 ]; then
        ok "The $EXAKIT_UDF_RUST_ALIAS container is already installed"
        if [ "$_usr_add_python" = 1 ]; then
            info "Rust adds to Python, never replaces it: no Python container is installed, and training runs Python UDFs - the official $EXAKIT_UDF_OFFICIAL_ALIAS container goes in now"
            _udf_with_restart "Installing the official $EXAKIT_UDF_OFFICIAL_ALIAS container beside $EXAKIT_UDF_RUST_ALIAS" \
                _udf_slc install "$EXAKIT_UDF_OFFICIAL_ALIAS" --auto-approve
            case $? in
                0) ;;
                5) _udf_fail 5 install "exakit udf-setup --language rust --yes" "The install was not confirmed; nothing changed."; return 1 ;;
                *) _udf_fail 6 install "exakit logs" "The launcher could not install the $EXAKIT_UDF_OFFICIAL_ALIAS container beside $EXAKIT_UDF_RUST_ALIAS (see: exakit logs)."; return 1 ;;
            esac
        fi
    else
        _usr_rust_action=installed
        _usr_what="Installing the $EXAKIT_UDF_RUST_ALIAS container"
        if [ "$_usr_add_python" = 1 ]; then
            info "Rust adds to Python, never replaces it: no Python container is installed, and training runs Python UDFs - the official $EXAKIT_UDF_OFFICIAL_ALIAS container goes in with the same restart"
            _usr_what="Installing the $EXAKIT_UDF_RUST_ALIAS container and the official $EXAKIT_UDF_OFFICIAL_ALIAS container (one restart for both)"
        fi
        _udf_with_restart "$_usr_what" _udf_slc_rust_then_python "$_usr_verb" "$_usr_add_python"
        case $? in
            0) ;;
            5) _udf_fail 5 install "exakit udf-setup --language rust --yes" "The install was not confirmed; nothing changed."; return 1 ;;
            *) _udf_fail 6 install "exakit logs" "The launcher could not install the $EXAKIT_UDF_RUST_ALIAS container${_usr_add_python:+ or the official $EXAKIT_UDF_OFFICIAL_ALIAS one beside it} (see: exakit logs)."; return 1 ;;
        esac
        manifest_set "components.udf_devkit.containers.$EXAKIT_UDF_RUST_ALIAS" "$UDF_CONTAINER_URL"
        ok "Rust UDFs: the $EXAKIT_UDF_RUST_ALIAS container is installed (rustc $(_udf_row runtime | sed 's/.*"rustc": *"\([^"]*\)".*/\1/'), exasol-udf-sdk $(_udf_rules pins "$UDF_CONTAINER_DOC" rust "$UDF_CONTAINER_ARCH" "$UDF_CONTAINER_DB" 2>/dev/null | awk '$1 == "exasol-udf-sdk" {print $2}'))"
    fi
    _udf_record_language rust
    UDF_DONE_STEPS="{\"language\": \"rust\", \"alias\": \"$EXAKIT_UDF_RUST_ALIAS\", \"step\": \"install\", \"action\": \"$_usr_rust_action\"}"
    if [ "$_usr_add_python" = 1 ]; then
        # The Python container just added is proven by its smoke UDF, and
        # recorded, before the Rust smoke: both languages must be there.
        udf_devkit_smoke "$EXAKIT_UDF_OFFICIAL_ALIAS" || return 1
        _udf_record_language python
        manifest_set components.udf_devkit.python_alias "$EXAKIT_UDF_OFFICIAL_ALIAS"
        UDF_DONE_STEPS="$UDF_DONE_STEPS, {\"language\": \"python\", \"alias\": \"$EXAKIT_UDF_OFFICIAL_ALIAS\", \"step\": \"install\", \"action\": \"installed\"}"
    else
        # Older kit manifests may not record a Python container already known
        # to the launcher. Prove and adopt it so 01_train can select it.
        udf_devkit_smoke "$_usr_python" || return 1
        _udf_record_language python
        manifest_set components.udf_devkit.python_alias "$_usr_python"
        ok "Python UDFs keep running on $_usr_python (training needs them); Rust adds to it"
        UDF_DONE_STEPS="$UDF_DONE_STEPS, {\"language\": \"python\", \"alias\": \"$_usr_python\", \"step\": \"install\", \"action\": \"kept\"}"
    fi
    UDF_SMOKE_LINES=""
    if [ -z "$UDF_SMOKE_FILE" ]; then
        manifest_set components.udf_devkit.rust.validated false
        manifest_set components.udf_devkit.validated false
        _udf_fail 7 smoke "exakit update" "The Rust smoke UDF library for $UDF_CONTAINER_ARCH is not pinned in this kit's versions.json yet ($UDF_SMOKE_WHY): the $EXAKIT_UDF_RUST_ALIAS container is installed (exasol slc list) but not proven. A kit update brings the pin."
        return 1
    fi
    udf_devkit_smoke_rust "$EXAKIT_UDF_RUST_ALIAS" || return 1
    return 0
}

# _udf_slc_rust_then_python <install|update> <add python 0|1> — the launcher
# commands of one Rust setup, run inside one _udf_with_restart: the Rust
# container recorded without a restart (--no-restart) when the official Python
# container follows, whose own install restarts the database once for both.
_udf_slc_rust_then_python() {
    if [ "$2" = 1 ]; then
        _udf_slc custom "$1" --source "$UDF_CONTAINER_FILE" --alias "$EXAKIT_UDF_RUST_ALIAS" --language rust --auto-approve --no-restart || return $?
        _udf_slc install "$EXAKIT_UDF_OFFICIAL_ALIAS" --auto-approve
    else
        _udf_slc custom "$1" --source "$UDF_CONTAINER_FILE" --alias "$EXAKIT_UDF_RUST_ALIAS" --language rust --auto-approve
    fi
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
    _udi_primary_ok=1
    if ! exakit_db_reachable; then
        info "Start the database, then set up $_udi_lang UDFs with: exakit udf-setup --language $_udi_lang"
    elif [ "$_udi_lang" = rust ]; then
        info "EXAKIT_UDF_LANGUAGE=rust: the Rust container is added beside a Python one (installed with it when none is there - training runs Python UDFs); the ML container is prepared next"
        _UDF_YES=1 udf_devkit_setup_rust 0 || { _udi_primary_ok=0; warn "Rust UDFs are not proven yet (${UDF_FAIL_MSG:-see the log}) - run: exakit udf-setup --language rust"; }
    else
        _UDF_YES=1 udf_devkit_setup_container 0 || { _udi_primary_ok=0; warn "Python UDFs are not set up yet - run: exakit udf-setup"; }
    fi
    if exakit_db_reachable; then
        _UDF_YES=1 udf_devkit_ensure_ml || {
            manifest_set components.udf_devkit.validated false
            warn "The ML packages are not ready inside the database - retry: exakit udf-use default"
            return 1
        }
    fi
    [ "$_udi_primary_ok" = 1 ] || { manifest_set components.udf_devkit.validated false; return 1; }
    return 0
}

# udf_devkit_validate — the installed containers proven again, quietly: the
# official Python one by its smoke UDF, the Rust one by its smoke library when
# that is in the cache (udf_devkit_setup_rust fetched it); otherwise the
# record says not validated.
udf_devkit_validate() {
    exakit_db_reachable || return 0
    _udv_aliases="$(udf_devkit_installed_aliases)"
    _udv_ok=0
    if printf '%s\n' "$_udv_aliases" | grep -qx "$EXAKIT_UDF_OFFICIAL_ALIAS"; then
        udf_devkit_smoke "$EXAKIT_UDF_OFFICIAL_ALIAS" >/dev/null 2>&1 && _udv_ok=1
    fi
    if printf '%s\n' "$_udv_aliases" | grep -qx "$EXAKIT_UDF_DEFAULT_ALIAS"; then
        udf_devkit_ensure_ml >/dev/null 2>&1 || { manifest_set components.udf_devkit.validated false; return 0; }
        _udv_ok=1
    fi
    if printf '%s\n' "$_udv_aliases" | grep -qx "$EXAKIT_UDF_RUST_ALIAS"; then
        _udf_select_container rust >/dev/null 2>&1 && _udf_rust_smoke_asset \
            && UDF_SMOKE_FILE="${UDF_SMOKE_BUNDLED:-$EXAKIT_UDF_CONTAINER_CACHE/$(basename "$UDF_SMOKE_URL")}" \
            && _udf_rules verify "$UDF_SMOKE_FILE" "$UDF_SMOKE_SHA256" "$UDF_SMOKE_SIZE" >/dev/null 2>&1 \
            && udf_devkit_smoke_rust "$EXAKIT_UDF_RUST_ALIAS" >/dev/null 2>&1 && _udv_ok=1
    fi
    [ "$_udv_ok" = 1 ] || manifest_set components.udf_devkit.validated false
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
        # The Rust smoke library is built for the kit's pinned container; a
        # tarball of yours is recorded as installed, not proven.
        manifest_set components.udf_devkit.validated false
        UDF_SMOKE_LINES=""
        info "A Rust container of your own has no smoke UDF (the kit's proves its pinned one: exakit udf-setup --language rust); exasol slc list shows $_uit_alias"
    else
        udf_devkit_smoke "$_uit_alias" "$@" || return 1
    fi
    manifest_set "components.udf_devkit.containers.$_uit_alias" "$_uit_source"
}

# cmd_udf_setup [--language python|rust] [--force] [--yes] [--json] — the
# official Python container (PYTHON3) or the matrix's Rust container (RUST),
# each proven by its smoke UDF; --force reinstalls one that is there.
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
        udf_devkit_setup_rust "$_ucs_force" || _udf_raise_fail rust
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
            udf_devkit_setup_rust 1 || _udf_raise_fail rust
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
# place for every command that hands a UDF a file (udf-file, model put | list,
# the Rust smoke library; the external-sources work stages its drivers through
# the same mapping). The layout belongs to the launcher, so nothing else spells
# it out: the deployment's runtime folder (local/runtime/exa) must exist and so
# must its BucketFS folder (bucketfs, which the launcher creates - a missing
# one is a FAIL: no deployment to put a file into); the bucket folder itself
# (bfsdefault/default) is NOT created by the launcher - the database makes it
# on the first file - so a missing one under an existing bucketfs is fine and
# is created here (0755), UDF_BUCKET_CREATED=1 for the caller to say so. The
# mapping comes from the deployment's bucketfs.conf when it is there (one line
# per bucket: <path in the database> <service> <bucket> <path a UDF reads>
# ...; the database path's /exa/ is local/runtime/exa/ on this machine), else
# the default mapping is assumed; a conf that maps no such bucket is a FAIL
# naming it. Sets UDF_BUCKET_DIR (the folder on this machine),
# UDF_BUCKET_UDF_ROOT (that folder as a UDF sees it, /buckets/<service>/<bucket>)
# and UDF_BUCKET_MAPPING (bucketfs.conf | default); returns 1 with
# UDF_BUCKET_ERROR saying why. Globals rather than printed lines: the paths
# travel together, and a subshell per value would resolve them twice.
udf_bucket_locate() {
    UDF_BUCKET_DIR=""; UDF_BUCKET_UDF_ROOT=""; UDF_BUCKET_ERROR=""; UDF_BUCKET_CREATED=0; UDF_BUCKET_MAPPING=default
    _ubl_root="$EXAKIT_PERSONAL_DEPLOY_DIR/$EXAKIT_UDF_BUCKETFS_DIR"
    _ubl_exa="$(dirname "$_ubl_root")"
    if [ ! -d "$_ubl_exa" ]; then
        UDF_BUCKET_ERROR="The deployment has no BucketFS folder at $_ubl_root; is the database deployed by this launcher? (exakit status)"
        return 1
    fi
    if [ ! -d "$_ubl_root" ]; then
        UDF_BUCKET_ERROR="The deployment has no BucketFS folder at $_ubl_root (the launcher creates it with the database); is the database deployed by this launcher? (exakit status)"
        return 1
    fi
    UDF_BUCKET_DIR="$_ubl_root/$EXAKIT_UDF_BUCKETFS_SERVICE/$EXAKIT_UDF_BUCKETFS_BUCKET"
    UDF_BUCKET_UDF_ROOT="$EXAKIT_UDF_BUCKETFS_ROOT/$EXAKIT_UDF_BUCKETFS_SERVICE/$EXAKIT_UDF_BUCKETFS_BUCKET"
    _ubl_conf="$_ubl_exa/bucketfs.conf"
    if [ -f "$_ubl_conf" ]; then
        _ubl_line="$(awk -v s="$EXAKIT_UDF_BUCKETFS_SERVICE" -v b="$EXAKIT_UDF_BUCKETFS_BUCKET" '$2 == s && $3 == b { print; exit }' "$_ubl_conf" 2>/dev/null)"
        if [ -z "$_ubl_line" ]; then
            # The launcher writes only its internal SLC mapping on a fresh
            # deployment. User bucket directories are still visible under
            # /buckets as soon as they are created; this is the default mapping.
            if awk '$0 !~ /^[[:space:]]*(#|$)/ && $2 != "__builtin__" { found=1 } END { exit !found }' "$_ubl_conf"; then
                UDF_BUCKET_ERROR="$_ubl_conf maps no bucket $EXAKIT_UDF_BUCKETFS_SERVICE/$EXAKIT_UDF_BUCKETFS_BUCKET; the kit expects the launcher's default bucket (exakit status)"
                return 1
            fi
        else
            _ubl_inside="$(printf '%s\n' "$_ubl_line" | awk '{ print $1 }')"
            _ubl_seen="$(printf '%s\n' "$_ubl_line" | awk '{ print $4 }')"
            case "$_ubl_inside" in
                /exa/*) UDF_BUCKET_DIR="$_ubl_exa/${_ubl_inside#/exa/}" ;;
                *) UDF_BUCKET_ERROR="$_ubl_conf keeps bucket $EXAKIT_UDF_BUCKETFS_SERVICE/$EXAKIT_UDF_BUCKETFS_BUCKET at $_ubl_inside, outside the deployment's exa folder the kit can write to (exakit status)"; return 1 ;;
            esac
            case "$_ubl_seen" in
                /*) UDF_BUCKET_UDF_ROOT="$_ubl_seen" ;;
            esac
            UDF_BUCKET_MAPPING=bucketfs.conf
        fi
    fi
    if [ ! -d "$UDF_BUCKET_DIR" ]; then
        if ! mkdir -p "$UDF_BUCKET_DIR" 2>/dev/null || ! chmod 755 "$UDF_BUCKET_DIR" 2>/dev/null; then
            UDF_BUCKET_ERROR="The bucket folder $UDF_BUCKET_DIR is missing and could not be created (check the folder's permissions; exakit status)"
            return 1
        fi
        UDF_BUCKET_CREATED=1
        _exakit_log_file "UDF   created the bucket folder $UDF_BUCKET_DIR (mapping: $UDF_BUCKET_MAPPING)"
    fi
    return 0
}

# udf_bucket_note — the one line a command says when udf_bucket_locate has just
# created the bucket folder (not with --json: the answer is one object).
udf_bucket_note() {
    [ "${UDF_BUCKET_CREATED:-0}" = 1 ] || return 0
    [ "${EXAKIT_REFUSAL_JSON:-0}" = 1 ] && return 0
    info "Created the bucket folder $UDF_BUCKET_DIR (the launcher leaves it to the first file; UDFs read it at $UDF_BUCKET_UDF_ROOT)"
}

# cmd_udf_file <file> [<path in the bucket>] — copy a file into BucketFS and
# name the path a UDF reads.
cmd_udf_file() {
    [ $# -ge 1 ] && [ $# -le 2 ] || die "Name the file and, optionally, where in the bucket: exakit udf-file model.pkl models/model.pkl"
    _udf_require_installed
    [ -f "$1" ] || die "$1 is not a file."
    _ucf_rel="$(_udf_tool relative "${2:-$(basename "$1")}" 2>&1)" || die "$_ucf_rel"
    udf_bucket_locate || die "$UDF_BUCKET_ERROR"
    udf_bucket_note
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
    udf_bucket_note
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
        put|list|rm|prune|inspect|template)
            case " $* " in
                *" --help "*|*" -h "*) exakit_help_render command "exakit model $_cm_sub"; return $? ;;
            esac
            "_cmd_model_$_cm_sub" "$@" ;;
        "") reject "Name what to do: exakit model put <file> | list | rm <name> | prune | inspect <file> | template (exakit model --help)." ;;
        *) reject "Unknown model command '$_cm_sub' (supported: put, list, rm, prune, inspect, template)." ;;
    esac
}

# _model_inspect <file> — model_tool.py inspect: what the file is and whether
# its provenance is trusted, as one JSON object in _MODEL_INSPECT (exit 2 with
# the reason when the tool refuses it).
_model_inspect() {
    _mi_err="$EXAKIT_HOME/.model-inspect.err"
    _MODEL_INSPECT="$(_model_tool inspect "$1" "$UDF_BUCKET_DIR" "$EXAKIT_HOME" 2>"$_mi_err")"
    _mi_rc=$?
    _mi_why="$(cat "$_mi_err" 2>/dev/null)"; rm -f "$_mi_err"
    case "$_mi_rc" in
        0) ;;
        2) reject "$_mi_why" ;;
        *) die "Could not read $1: ${_mi_why:-no reason given}" ;;
    esac
}

# _model_inspect_field <name> — one field of _MODEL_INSPECT (True/False for a boolean).
_model_inspect_field() {
    printf '%s\n' "$_MODEL_INSPECT" | run_python_any -c 'import json, sys
v = json.load(sys.stdin).get(sys.argv[1])
print("" if v is None else v)' "$1"
}

# The prompt and the refusal before a pickle without trusted provenance is put
# (design 9, T21b). Loading a pickle or joblib file runs code from the file, so
# one whose provenance sidecar does not match an MLflow run or a workflow of
# this kit is confirmed first: on a terminal the question below (default no;
# a decline is exit 5, nothing copied); without one - or with --json - it is
# refused with exit 6 unless --yes or EXAKIT_MODEL_TRUST=1 says the source is
# trusted. The same file already in the bucket (same digest) asks nothing: the
# UDF loads nothing new.
EXAKIT_MODEL_TRUST_PROMPT="Loading a pickle runs code from the file. Continue?"

# _model_trust_gate <file> <name> <yes 0|1> <json 0|1> — leaves when the put may
# go on; exits 5 (declined) or 6 (refused without a terminal) otherwise.
_model_trust_gate() {
    [ "$(_model_inspect_field loads_code)" = True ] || return 0
    [ "$(_model_inspect_field trusted)" = True ] && return 0
    [ "$(_model_inspect_field in_bucket)" = same ] && return 0
    if [ "$3" = 1 ] || [ "${EXAKIT_MODEL_TRUST:-0}" = 1 ]; then
        _exakit_log_file "UDF   model put $2: pickle without trusted provenance, confirmed by --yes or EXAKIT_MODEL_TRUST=1"
        return 0
    fi
    _mtg_why="$(_model_inspect_field reason)"
    if [ "$4" != 1 ] && [ -n "$(_exakit_prompt_tty)" ]; then
        warn "$2 is a $(_model_inspect_field kind) file without trusted provenance ($_mtg_why)."
        if confirm "$EXAKIT_MODEL_TRUST_PROMPT" n; then
            return 0
        fi
        _model_refuse 5 "exakit model put $1 --yes" "Not confirmed; nothing was copied."
    fi
    _model_refuse 6 "exakit model put $1 --yes" "Loading a pickle runs code from the file, and $2 carries no trusted provenance ($_mtg_why). Nothing was copied; confirm with --yes, or EXAKIT_MODEL_TRUST=1, when you trust its source."
}

# exakit model put <file> [--replace] [--yes] [--json]
_cmd_model_put() {
    _cmp_file=""; _cmp_replace=0; _cmp_json=0; _cmp_yes=0
    for _cmp_arg in "$@"; do
        case "$_cmp_arg" in
            --replace) _cmp_replace=1 ;;
            --yes|-y) _cmp_yes=1 ;;
            --json|-j) _cmp_json=1; EXAKIT_REFUSAL_JSON=1 ;;
            -*) reject "Unknown option '$_cmp_arg' for model put (supported: --replace --yes --json)." ;;
            *) [ -z "$_cmp_file" ] || reject "Name one model file: exakit model put <file> [--replace] [--yes]"; _cmp_file="$_cmp_arg" ;;
        esac
    done
    [ -n "$_cmp_file" ] || reject "Name the model file: exakit model put <file> [--replace] [--yes] [--json]"
    _model_ready
    [ -f "$_cmp_file" ] || reject "$_cmp_file is not a file."
    _model_inspect "$_cmp_file"
    _model_trust_gate "$_cmp_file" "$(_model_inspect_field name)" "$_cmp_yes" "$_cmp_json"
    _cmp_err="$EXAKIT_HOME/.model-put.err"
    _cmp_out="$(_model_record | _model_tool put "$_cmp_file" "$UDF_BUCKET_DIR" "$UDF_BUCKET_UDF_ROOT" "$_cmp_replace" "$EXAKIT_HOME" 2>"$_cmp_err")"
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
    printf '%s\n' "$_cmp_answer" | run_python_any -c 'import json,sys
a = json.load(sys.stdin)
p = a.get("provenance") or {}
if a.get("trusted_origin"):
    print("  Provenance: trusted (" + ", ".join(k + " " + str(p[k]) for k in ("run_id", "workflow_id") if p.get(k)) + ")")
elif p.get("scikit-learn"):
    print("  Pickled with scikit-learn " + str(p["scikit-learn"]) + " (pickle protocol " + str(p.get("pickle_protocol")) + "), recorded in its provenance sidecar")
w = a.get("warning")
if w: print("  Warning: " + w)'
}

# exakit model inspect <file> [--json] — what the file is and whether its
# provenance is trusted, before it is put: kind, sha256, size, the versions its
# header or sidecar name, the trust verdict with its reason, and whether the
# bucket already holds it.
_cmd_model_inspect() {
    _cmi_file=""; _cmi_json=0
    for _cmi_arg in "$@"; do
        case "$_cmi_arg" in
            --json|-j) _cmi_json=1; EXAKIT_REFUSAL_JSON=1 ;;
            -*) reject "Unknown option '$_cmi_arg' for model inspect (supported: --json)." ;;
            *) [ -z "$_cmi_file" ] || reject "Name one model file: exakit model inspect <file>"; _cmi_file="$_cmi_arg" ;;
        esac
    done
    [ -n "$_cmi_file" ] || reject "Name the model file: exakit model inspect <file> [--json]"
    _model_ready
    [ -f "$_cmi_file" ] || reject "$_cmi_file is not a file."
    _model_inspect "$_cmi_file"
    if [ "$_cmi_json" = 1 ]; then
        exakit_json_pretty "$_MODEL_INSPECT"
        return 0
    fi
    printf '%s\n' "$_MODEL_INSPECT" | run_python_any -c 'import json, sys
d = json.load(sys.stdin)
p = d.get("provenance") or {}
print("  %s: %s file, %d bytes, sha256 %s" % (d["name"], d["kind"], d["size"], d["sha256"]))
if p:
    print("  Provenance (%s): scikit-learn %s, python %s, pickle protocol %s, run_id %s, workflow_id %s" % (
        p.get("source"), p.get("scikit-learn") or "unknown", p.get("python") or "unknown", p.get("pickle_protocol"),
        p.get("run_id") or "-", p.get("workflow_id") or "-"))
print("  Trusted: %s (%s)" % ("yes" if d["trusted"] else "no", d["reason"]))
print("  In the bucket directory: %s" % {"same": "yes, this file", "different": "a different file of this name", "absent": "no"}[d["in_bucket"]])
if d.get("warning"): print("  Warning: " + d["warning"] + " exakit model put asks before copying it (--yes or EXAKIT_MODEL_TRUST=1 answers).")'
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

_cmd_model_prune() {
    _cmpn_days=30; _cmpn_yes=0; _cmpn_json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --older-than) shift; [ -n "${1:-}" ] || reject "--older-than needs days"; _cmpn_days="$1" ;;
            --yes) _cmpn_yes=1 ;;
            --json|-j) _cmpn_json=1; EXAKIT_REFUSAL_JSON=1 ;;
            *) reject "Unknown option '$1' for model prune (supported: --older-than DAYS --yes --json)." ;;
        esac
        shift
    done
    case "$_cmpn_days" in *[!0-9]*|"") reject "--older-than must be a positive number of days" ;; esac
    _model_ready
    _cmpn_err="$EXAKIT_HOME/.model-prune.err"
    _cmpn_out="$(_model_record | _model_tool prune "$UDF_BUCKET_DIR" "$UDF_BUCKET_UDF_ROOT" "$EXAKIT_HOME" "$_cmpn_days" "$_cmpn_yes" 2>"$_cmpn_err")"
    _cmpn_rc=$?
    _cmpn_why="$(cat "$_cmpn_err" 2>/dev/null)"; rm -f "$_cmpn_err"
    case "$_cmpn_rc" in 0) ;; 2) reject "$_cmpn_why" ;; *) die "Could not prune models: ${_cmpn_why:-no reason given}" ;; esac
    _cmpn_answer="$(printf '%s\n' "$_cmpn_out" | sed -n 1p)"
    if [ "$_cmpn_yes" = 1 ]; then
        manifest_set components.udf_devkit.models "$(printf '%s\n' "$_cmpn_out" | sed -n 2p)"
    fi
    if [ "$_cmpn_json" = 1 ]; then exakit_json_pretty "$_cmpn_answer"; return 0; fi
    printf '%s\n' "$_cmpn_answer" | run_python_any -c 'import json,sys
d=json.load(sys.stdin)
for name in d["candidates"]: print(("Removed " if not d["dry_run"] else "Would remove ")+name)
print("No old unreferenced models found." if not d["candidates"] else ("Pruned." if not d["dry_run"] else "Dry run; pass --yes to remove these models."))
if d.get("mlflow"): print("(" + d["mlflow"] + ")")'
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
    _cml_doc="$(_model_record | _model_tool list "$UDF_BUCKET_DIR" "$UDF_BUCKET_UDF_ROOT" "${UDF_BUCKET_CREATED:-0}" "${UDF_BUCKET_MAPPING:-default}" 2>"$_cml_err")"
    _cml_rc=$?
    _cml_why="$(cat "$_cml_err" 2>/dev/null)"; rm -f "$_cml_err"
    [ "$_cml_rc" -eq 0 ] || die "Could not list the bucket directory: ${_cml_why:-no reason given}"
    if [ "$_cml_json" = 1 ]; then
        exakit_json_pretty "$_cml_doc"
        return 0
    fi
    printf '%s\n' "$_cml_doc" | run_python_any -c 'import json, sys
d = json.load(sys.stdin)
print("  Bucket directory: %s%s" % (d["bucket_dir"], " (created now)" if d.get("created") else ""))
print("  UDFs read it as:  %s (mapping: %s)" % (d["udf_root"], d.get("mapping", "default")))
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
