#!/usr/bin/env bash
# personal-update-rename.sh - the update from a 0.3.0 kit: the database the
# 0.3.0 kit uses becomes the deployment starter-kit-local on Exasol Personal
# 2.5, in one restart, and nothing 2.5 runs before its folder has its new name.
#   owner kit   the kit's own 2.4 launcher: stopped with it, `default` renamed
#               in its root, the launcher swapped (checksum checked), the
#               folder moved by the new launcher's first command and followed
#               by its id, the 20-session limit lifted while stopped, started
#               once, only when it ran
#   current     a launcher at 2.5 already, `default` in the 2.5 root (or still
#               in the legacy root): renamed there, no swap
#   named       a database already starter-kit-local: no rename
#   target      a starter-kit-local in the way: nothing changed
#   undo        a swap that fails (bad checksum, a launcher that does not run,
#               one that moved the folder first): the launcher, the folder's
#               name and the records put back, started again only when it ran
#   owner user  a database the user let the 0.3.0 kit use, run by their own
#               2.4 (or a later one): their launcher is run to stop it, and
#               never replaced, moved or deleted (#41); the kit's own 2.5 takes
#               over from the kit folder
#   installer   the installer run again over a 0.3.0 kit takes the same steps
#   --json      the rows: updated, or deferred with the reason
#
#   bash tests/personal-update-rename.sh
#
# All in a scratch HOME with stub launchers (2.4.0 and 2.5.0, the 2.5.0 one
# moving stopped legacy deployments as the real one does): no real launcher,
# database, container, port or kit home is touched, and nothing is downloaded.
# Under `set -o pipefail`, as exakit and the setup scripts run: a pipe that
# breaks there (grep -q on a launcher that writes on) breaks here too.
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home" EXAKIT_HOME="$WORK/home/kit" EXAKIT_BIN_DIR="$WORK/home/bin"
export EXAKIT_VERSION_POLICY=pinned EXAKIT_NO_UPDATE_NOTICE=1 EXAKIT_NO_FANCY=1
export TMPDIR="$WORK/tmp"
unset EXAKIT_PERSONAL_DEPLOY_DIR EXAKIT_PERSONAL_BIN EXAKIT_PERSONAL_MODE EXAKIT_PERSONAL_LAUNCHER_HOME \
    EXAKIT_REUSE_DB EXAKIT_CONFIRM_RUNTIME_UPDATE EXAKIT_FORCE_COMPONENT_INSTALL EXAKIT_PERSONAL_VERSION \
    EXAKIT_UPDATE_JSON EXAKIT_UPDATE_RESULTS EXAKIT_LOG_FILE XDG_CACHE_HOME XDG_DATA_HOME XDG_CONFIG_HOME
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$TMPDIR" "$WORK/userbin" "$WORK/state"
# No folder of this machine's PATH that holds an `exasol` stays on it: no real
# launcher is ever run. The user's own launcher, when a case has one, is in
# userbin.
_path=""
_rest="$PATH:"
while [ -n "$_rest" ]; do
    _d="${_rest%%:*}"; _rest="${_rest#*:}"
    [ -n "$_d" ] && [ ! -e "$_d/exasol" ] || continue
    _path="${_path:+$_path:}$_d"
done
export PATH="$WORK/userbin:$EXAKIT_BIN_DIR:$_path"

NAME=starter-kit-local
NEWROOT="$HOME/.exasol/launcher/deployments"
OLDROOT="$HOME/.exasol/personal/deployments"
NEW="$NEWROOT/$NAME"
OLD="$OLDROOT/$NAME"
CONF_REL="local/runtime/exa/exasol.conf"
export STUB_STATE="$WORK/state" STUB_CALLS="$WORK/calls"
SAID="$WORK/said"

# write_launcher <file> <version> [broken]: a stub Exasol Personal launcher.
# Every call is logged in STUB_CALLS as "<version> <args> [<the folders in
# both roots before it ran>]". A database's state (running or stopped) is
# kept by its id in STUB_STATE. From 2.5, any command but help first moves
# every legacy deployment that is stopped, unlocked and has no namesake in
# the 2.5 root, as the real launcher does (startup_migration.go). "broken":
# `version` answers nothing (it moves folders all the same).
write_launcher() {
    cat > "$1" <<'STUB'
#!/bin/sh
V='@V@'
BROKEN='@B@'
old="$HOME/.exasol/personal/deployments"; new="$HOME/.exasol/launcher/deployments"
id_of() { sed -n 's/.*"deploymentId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/.exasolLauncherState.json" 2>/dev/null | head -1; }
state_of() { cat "$STUB_STATE/$(id_of "$1")" 2>/dev/null || echo stopped; }
seen="$( (cd "$old" 2>/dev/null && ls; cd "$new" 2>/dev/null && ls) | tr '\n' ' ')"
[ -n "${STUB_CALLS:-}" ] && printf '%s %s [%s]\n' "$V" "$*" "$seen" >> "$STUB_CALLS"
help=0
for a in "$@"; do case "$a" in --help|-h) help=1 ;; esac; done
[ "${1:-}" = help ] && help=1
case "$V" in
    2.[5-9]*)
        if [ "$help" = 0 ] && [ -d "$old" ]; then
            for d in "$old"/*; do
                [ -d "$d" ] || continue
                [ "$(state_of "$d")" = running ] && continue
                ls "$d"/.dirmutex.* >/dev/null 2>&1 && continue
                [ -e "$new/$(basename "$d")" ] && continue
                mkdir -p "$new" && mv "$d" "$new/"
            done
        fi ;;
esac
dir=""; prev=""
for a in "$@"; do [ "$prev" = "--deployment-dir" ] && dir="$a"; prev="$a"; done
case "${1:-}" in
    version|--version)
        [ "$BROKEN" = broken ] && [ "$1" = version ] && exit 1
        echo "$V" ;;
    --help|help) printf 'Commands:\n  start  Start\n  stop  Stop\n  status  Status\n  sidecar  Sidecars\n' ;;
    info) [ -n "$dir" ] && [ -d "$dir" ] || exit 1; echo info ;;
    status)
        [ -d "$dir" ] || { echo '{"status": "not_initialized"}'; exit 0; }
        case "$(state_of "$dir")" in running) s=database_ready ;; *) s=stopped ;; esac
        printf '{"status": "%s"}\n' "$s" ;;
    stop)
        [ "${STUB_STOP_RC:-0}" = 0 ] && [ -d "$dir" ] || exit 1
        echo stopped > "$STUB_STATE/$(id_of "$dir")" ;;
    start)
        [ -d "$dir" ] || exit 1
        n="$(cat "$STUB_STATE/start-fails" 2>/dev/null || echo 0)"
        if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$STUB_STATE/start-fails"; exit 1; fi
        echo running > "$STUB_STATE/$(id_of "$dir")" ;;
    deployments)
        case "$V" in 2.[5-9]*) ;; *) echo 'Error: unknown command "deployments" for "exasol"' >&2; exit 1 ;; esac
        printf '['; sep=""
        for d in "$new"/* "$old"/*; do
            [ -f "$d/.exasolLauncherState.json" ] || continue
            case "$d" in "$old"/*) [ -e "$new/$(basename "$d")" ] && continue ;; esac
            case "$(state_of "$d")" in running) s=database_ready ;; *) s=stopped ;; esac
            printf '%s{"name": "%s", "path": "%s", "status": "%s", "infrastructure": "local"}' "$sep" "$(basename "$d")" "$d" "$s"
            sep=", "
        done
        printf ']\n' ;;
    install) [ "${2:-}" = --help ] && printf 'Commands:\n  local  Local\n' ;;
    *) exit 0 ;;
esac
STUB
    sed -i.bak -e "s/@V@/$2/" -e "s/@B@/${3:-}/" "$1" && rm -f "$1.bak"
    chmod +x "$1"
}
write_launcher "$WORK/exasol-2.4.0" 2.4.0
write_launcher "$WORK/exasol-2.5.0" 2.5.0
write_launcher "$WORK/exasol-2.5.0-broken" 2.5.0 broken
# 2.5.0, with a line after its version a moment later (an update notice): a
# `| grep -q` reader is gone by then, and the launcher dies of SIGPIPE.
# 2.5.0 whose first `version` takes 5 s (its 2.5 move), then answers at once.
write_launcher "$WORK/exasol-2.5.0-slow" 2.5.0
sed -i.bak 's|^        \[ "\$BROKEN" = broken \] && \[ "\$1" = version \] && exit 1$|        [ "$1" = version ] \&\& [ ! -e "$STUB_STATE/slow-once" ] \&\& { : > "$STUB_STATE/slow-once"; sleep 5; }|' "$WORK/exasol-2.5.0-slow" && \
    rm -f "$WORK/exasol-2.5.0-slow.bak"
write_launcher "$WORK/exasol-2.5.0-chatty" 2.5.0
sed -i.bak 's/^        echo "\$V" ;;$/        echo "$V"; sleep 1; echo "A newer Exasol Personal is available." ;;/' "$WORK/exasol-2.5.0-chatty" && \
    rm -f "$WORK/exasol-2.5.0-chatty.bak"
printf 'not a launcher\n' > "$WORK/corrupt"
sha() { shasum -a 256 < "$1" 2>/dev/null | cut -d' ' -f1; }

. "$ROOT/setup/lib/common.sh"
. "$ROOT/setup/lib/detect.sh"
. "$ROOT/setup/lib/runtime-personal.sh"
. "$ROOT/setup/lib/mcp.sh"
info(){ printf 'INFO %s\n' "$*"; }; ok(){ printf 'OK %s\n' "$*"; }; warn(){ printf 'WARN %s\n' "$*"; }
error(){ printf 'ERROR %s\n' "$*"; }; info_step(){ :; }; ok_step(){ :; }
ensure_path_hint(){ :; }
fetch(){ echo 'Unexpected download' >&2; return 91; }
# The sidecars.yaml editor runs as the kit runs it (`uv run ... python
# sidecar_definition.py ...`), through a uv that hands it to this machine's
# python3 with a stand-in for PyYAML that reads JSON (JSON is YAML): the
# editor's own code decides, and nothing is downloaded.
mkdir -p "$WORK/yamlshim"
cat > "$WORK/yamlshim/yaml.py" <<'PY'
import json
class YAMLError(Exception):
    pass
class MarkedYAMLError(YAMLError):
    problem_mark = None
def safe_load(text):
    return json.loads(text) if text.strip() else None
def safe_dump(document, **_):
    return json.dumps(document, indent=2)
PY
cat > "$WORK/uv" <<UV
#!/bin/sh
[ -z "\${STUB_CALLS:-}" ] || echo "uv \$*" >> "\$STUB_CALLS"
while [ "\$1" != python ]; do shift; done; shift
PYTHONPATH="$WORK/yamlshim" exec python3 "\$@"
UV
chmod +x "$WORK/uv"
exakit_ensure_uv() { echo "ensure_uv readonly=${EXAKIT_READONLY_QUERY:-}" >> "$WORK/ensure_uv"; EXAKIT_UV_BIN="$WORK/uv"; }
# The download: Exasol's S3, pinned to the 2.5.0 stub's checksum. DOWNLOAD
# names the file the server hands out (a corrupt one fails the check).
DOWNLOAD="$WORK/exasol-2.5.0"
PIN="$(sha "$WORK/exasol-2.5.0")"
personal_s3_source() { printf 'https://example.test/exasol\n%s' "$PIN"; }
fetch_soft() { echo "$1" >> "$WORK/downloads"; cp "$DOWNLOAD" "$2"; }
# The database's state is the stub launcher's (by its id), asked as the kit
# asks it; a start is the launcher's start on the folder in use, and the wait
# asks that state.
personal_status() {
    personal_deploy_dir_refresh
    _pst="$("$(personal_cli)" status --json --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>/dev/null)"
    case "$_pst" in
        *database_ready*) echo running ;;
        *'"stopped"'*) echo stopped ;;
        *) echo "not deployed" ;;
    esac
}
personal_start() {
    personal_deploy_dir_refresh
    exakit_kit_database_guard || return 3
    run_logged "$(personal_cli)" start --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" || die "Failed to start the database."
}
personal_wait_ready_or_deploy() { [ "$(personal_status)" = running ]; }

PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1))
    else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
has() { case "$3" in *"$2"*) check "$1" yes yes ;; *) check "$1" "has: $2" "$(printf '%s' "$3" | tail -15)" ;; esac; }
hasnt() { case "$3" in *"$2"*) check "$1" "not: $2" "$(printf '%s' "$3" | grep -F -- "$2" | head -3)" ;; *) check "$1" yes yes ;; esac; }
yn() { if "$@"; then echo yes; else echo no; fi; }

# fresh: a new process on the machine as the case set it up.
fresh() {
    unset _EXAKIT_PERSONAL_LIST_DECIDED _EXAKIT_PERSONAL_LIST_ASKED _EXAKIT_PERSONAL_DEPLOY_FOLLOWED \
        _EXAKIT_PERSONAL_DEPLOY_ID_SEEN _EXAKIT_PERSONAL_DEPLOY_REC _EXAKIT_PERSONAL_DEPLOY_AT _EXAKIT_PERSONAL_DEPLOY_LOST \
        _EXAKIT_KIT_DB_GUARD_SAID EXAKIT_RUNTIME_UPDATE_SAID
    DETECT_PERSONAL_LAUNCHER_LISTED=0; DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS=""; PERSONAL_LAUNCHER_ROWS=""
    EXAKIT_PERSONAL_MODE=""; EXAKIT_PERSONAL_BIN="$EXAKIT_PERSONAL_KIT_BIN"
    EXAKIT_PERSONAL_DEPLOY_DIR=""
}
reset_home() {
    chmod -R u+w "$WORK/userbin" 2>/dev/null
    rm -rf "$HOME/.exasol" "$EXAKIT_HOME/cache" "$EXAKIT_BIN_DIR/exasol" "$WORK/userbin"/* "$WORK/state"/* "$WORK/downloads" \
        "$EXAKIT_HOME/personal"
    printf '{}\n' > "$EXAKIT_MANIFEST"
    rm -f "$EXAKIT_HOME/.last-failure"
    DOWNLOAD="$WORK/exasol-2.5.0"
    fresh
}
# seed <dir> <id> <port> [running]: a deployment Exasol Personal 2.4 made, its
# 20-session limit in exasol.conf.
seed() {
    mkdir -p "$1/local/runtime/exa" "$1/infrastructure"
    printf '{"deploymentId": "%s", "connection": {"host": "127.0.0.1", "dbPort": %s, "username": "sys"}}\n' "$2" "$3" > "$1/deployment.json"
    printf '{"deploymentId": "%s", "deploymentVersion": "2.4.0"}\n' "$2" > "$1/.exasolLauncherState.json"
    printf '2.4.0' > "$1/.exasolLauncher.version"
    printf 'name: Exasol Local\nbackend: local\nlocal:\n  ports: db:%s\n' "$3" > "$1/infrastructure/infrastructure.yaml"
    printf '[DB_PARAMS]\nmaxConnectionsLicenseLimit=20\nother = 1\n' > "$1/$CONF_REL"
    printf '{"dbPassword": "pw-%s-0123456789"}\n' "$2" > "$1/secrets.json"
    printf 'tables of %s\n' "$2" > "$1/local/runtime/exa/data.bin"
    echo "${4:-stopped}" > "$STUB_STATE/$2"
}
state() { cat "$STUB_STATE/$1" 2>/dev/null || echo stopped; }
# kit030 <dir> <launcher version> [id]: what a 0.3.0 kit recorded about the
# database it deployed with its own launcher (no id: 0.3.0 kept none).
kit030() {
    cp "$WORK/exasol-$2" "$EXAKIT_BIN_DIR/exasol"
    manifest_set runtime.type personal
    manifest_set runtime.version "$2"
    manifest_set runtime.deployment_dir "$1"
    manifest_set runtime.launcher "$EXAKIT_BIN_DIR/exasol"
    manifest_set runtime.dsn 127.0.0.1:8563
    exakit_record_ownership personal kit "$EXAKIT_BIN_DIR/exasol"
    exakit_record_ownership database kit "$1"
    [ -z "${3:-}" ] || manifest_set runtime.deployment_id "$3"
}
# user030 <dir> <their launcher> <version>: a database the user let the 0.3.0
# kit use ("Use it instead?" yes), run by their own launcher.
user030() {
    cp "$WORK/exasol-$3" "$2"
    manifest_set runtime.type personal
    manifest_set runtime.version "$3"
    manifest_set runtime.deployment_dir "$1"
    manifest_set runtime.launcher "$2"
    manifest_set runtime.dsn 127.0.0.1:8563
    exakit_record_ownership personal user "$2"
    exakit_record_ownership database user "$1"
}
# upd [args]: `exakit update` on this machine, as a user runs it, the personal
# row only; its exit code in UPD_RC, what it said in SAID, its rows in ROWS.
export EXAKIT_UPDATE_RESULTS="$WORK/rows"
upd() {
    : > "$STUB_CALLS"; : > "$SAID"; : > "$EXAKIT_UPDATE_RESULTS"
    fresh
    UPD_RC=0
    ( exakit_update_targets() { printf 'personal\n'; }
      _exakit_marketplace_warm_about() { :; }
      exakit_versions_update_cache() { :; }
      mcp_sidecar_refresh() { :; }; exakit_autostart_refresh() { :; }; exakit_report_readonly_allowlist() { :; }
      exakit_core_update_check() { :; }; exakit_core_preprocessor_verify() { :; }
      exakit_update "$@" ) </dev/null >>"$SAID" 2>&1 || UPD_RC=$?
}
row() { grep '^personal|' "$EXAKIT_UPDATE_RESULTS" | cut -d'|' -f"${1:-1-2}" | tr '\n' ' ' | sed 's/ $//'; }
calls() { grep -E "^[0-9.]+ $1" "$STUB_CALLS" | sed 's/ \[.*//' ; }
said() { sed 's/\x1b\[[0-9;]*m//g' "$SAID"; }
first_25() { grep -m1 '^2\.5\.0 ' "$STUB_CALLS" || true; }
lineno() { said | grep -nF -- "$1" | head -1 | cut -d: -f1; }
before() { _b1="$(lineno "$2")"; _b2="$(lineno "$3")"; check "$1" yes "$([ -n "$_b1" ] && [ -n "$_b2" ] && [ "$_b1" -lt "$_b2" ] && echo yes || echo "no ($_b1 < $_b2)")"; }
L5="INFO Renaming the database to 'starter-kit-local'."

# THEIR LAUNCHER IS NEVER TOUCHED (#41), wherever it is, whatever it is, and
# however the update ends: the file, its time, and a link's target. One place a
# process, side by side: 48 updates, and each starts Python many times.
print_file() { ls -ldn "$1" 2>/dev/null | awk '{print $1,$3,$4,$5,$6,$7,$8}'; [ ! -L "$1" ] || readlink "$1"; sha "$1"; }
matrix_place() { # <place>
    _place="$1"
    for _ver in 2.4.0 2.5.0 2.6.0; do
        [ "$_ver" != 2.6.0 ] || write_launcher "$WORK/exasol-2.6.0" 2.6.0
        for _end in ok badsum broken norename; do
            reset_home
            rm -rf "$WORK/cellar" "$HOME/mybin"; mkdir -p "$WORK/cellar" "$HOME/mybin"
            case "$_place" in
                kitbin) T="$EXAKIT_BIN_DIR/exasol" ;;
                home)   T="$HOME/mybin/exasol" ;;
                path)   T="$WORK/userbin/exasol" ;;
                link)   T="$WORK/userbin/exasol" ;;
            esac
            _tdir="$NEWROOT"; [ "$_ver" != 2.4.0 ] || _tdir="$OLDROOT"
            seed "$_tdir/default" exa-mt 8563 running
            if [ "$_place" = link ]; then
                cp "$WORK/exasol-$_ver" "$WORK/cellar/exasol"; ln -s "$WORK/cellar/exasol" "$T"
                user030 "$_tdir/default" "$WORK/cellar/exasol" "$_ver"; exakit_record_ownership personal user "$T"; manifest_set runtime.launcher "$T"
            else
                user030 "$_tdir/default" "$T" "$_ver"
            fi
            chmod 555 "$T" 2>/dev/null
            T_BEFORE="$(print_file "$T")"
            case "$_end" in
                badsum)   DOWNLOAD="$WORK/corrupt" ;;
                broken)   DOWNLOAD="$WORK/exasol-2.5.0-broken"; PIN="$(sha "$DOWNLOAD")" ;;
                norename) mkdir -p "$NEW" ;;
            esac
            upd
            PIN="$(sha "$WORK/exasol-2.5.0")"; DOWNLOAD="$WORK/exasol-2.5.0"
            check "matrix $_place $_ver $_end: their launcher is the same file" "$T_BEFORE" "$(print_file "$T")"
            check "matrix $_place $_ver $_end: the database runs, theirs" "running|user" "$(state exa-mt)|$(manifest_get runtime.ownership)"
            case "$_end" in
                ok) check "matrix $_place $_ver $_end: updated, on the kit's own launcher" "personal|updated|kit|$EXAKIT_PERSONAL_KIT_BIN|$T|2.5.0" \
                        "$(row)|$(manifest_get components.personal.ownership)|$(manifest_get components.personal.ownership_path)|$(manifest_get components.personal.user_launcher)|$("$EXAKIT_PERSONAL_KIT_BIN" version)"
                    check "matrix $_place $_ver $_end: run once more to stop it, then never" "$_ver stop|2.5.0 start" \
                        "$(calls 'st(op|art)' | sed 's/ --.*//' | tr '\n' '|' | sed 's/|$//')" ;;
                *)  check "matrix $_place $_ver $_end: put back, the record names theirs, no launcher of the kit's" "personal|deferred|user|$T|no" \
                        "$(row)|$(manifest_get components.personal.ownership)|$(manifest_get components.personal.ownership_path)|$(yn test -e "$EXAKIT_PERSONAL_KIT_BIN")" ;;
            esac
        done
    done
}
if [ -n "${RENAME_MATRIX_PLACE:-}" ]; then
    matrix_place "$RENAME_MATRIX_PLACE"
    printf '%s %s\n' "$PASS" "$FAIL" > "$RENAME_MATRIX_RESULT"
    exit 0
fi
# THE TWO HALVES OF THE SECTIONS BELOW RUN SIDE BY SIDE, each in a process of
# its own (its own HOME and kit home), as the places of the matrix do: each
# update starts Python many times, and one after the other they outlast the job.
# RENAME_HALF=1 or 2 runs only that half.
same() {
    check "$1: no stop, no start, nothing downloaded" "|no" "$(calls 'st(op|art)')|$(yn test -e "$WORK/downloads")"
    check "$1: the database as it was, in its folder, not renamed" "${6:-running}|yes|no|no" \
        "$(state "$2")|$(yn test -d "$3")|$(yn test -e "$NEW")|$(yn test -e "$OLD")"
    check "$1: its limit and its records as they were" "yes|no|$3|$3|" \
        "$(yn grep -q maxConnectionsLicenseLimit "$3/$CONF_REL")|$(yn test -e "$3/$CONF_REL.before-session-limit")|$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.ownership_path)|$(manifest_get runtime.session_limit 2>/dev/null)"
    check "$1: the launcher as it was, the MCP server not claimed, no copy kept" "$5||no" \
        "$(sha "$4")|$(manifest_get components.mcp_server.sidecar_dir 2>/dev/null)|$(yn test -e "$EXAKIT_HOME/cache/personal-launcher-before-update")"
}
_half_pid=""
if [ -z "${RENAME_HALF:-}" ]; then
    RENAME_HALF=2 RENAME_HALF_RESULT="$WORK/half2.count" bash "$0" > "$WORK/half2.out" 2>&1 &
    _half_pid=$!
    RENAME_HALF=1
fi
if [ "$RENAME_HALF" = 1 ]; then
echo "owner kit: a 0.3.0 kit's own database on its own launcher 2.4.0, running:"
reset_home
seed "$OLDROOT/default" exa-030 8563 running
seed "$OLDROOT/theirs" exa-theirs 8600          # a stopped deployment of the user's, beside it
kit030 "$OLDROOT/default" 2.4.0
manifest_set runtime.deployment_id exa-030   # the record 0.3.1 backfills from the folder
OLD_SHA="$(sha "$EXAKIT_BIN_DIR/exasol")"
upd
check "succeeds" 0 "$UPD_RC"
check "the row: updated" "personal|updated" "$(row)"
check "the database is starter-kit-local in the 2.5 root" "yes|no|no" \
    "$(yn test -d "$NEW")|$(yn test -e "$OLDROOT/default")|$(yn test -e "$OLD")"
check "...its data and its id with it" "tables of exa-030|exa-030" \
    "$(cat "$NEW/local/runtime/exa/data.bin" 2>/dev/null)|$(detect_personal_deployment_id "$NEW")"
check "the records follow: folder, receipt, name, owner, id" "$NEW|$NEW|$NAME|kit|exa-030" \
    "$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.ownership_path)|$(manifest_get runtime.deployment_name)|$(manifest_get runtime.ownership)|$(manifest_get runtime.deployment_id)"
check "...still the kit's, managed" kit "$(fresh; exakit_component_ownership database)"
check "the launcher is 2.5.0 in the kit folder, checksum checked, the kit's receipt on it" "$PIN|$PIN|kit|$EXAKIT_PERSONAL_KIT_BIN" \
    "$(sha "$EXAKIT_PERSONAL_KIT_BIN")|$(manifest_get components.personal.ownership_sha256)|$(manifest_get components.personal.ownership)|$(manifest_get components.personal.ownership_path)"
check "...the 0.3.0 one at ~/.local/bin/exasol, the file the kit recorded, removed" no "$(yn test -e "$EXAKIT_BIN_DIR/exasol")"
has "...and one line says where the kit's launcher is now" "INFO The kit's Exasol launcher is now in $(ui_tilde "$(dirname "$EXAKIT_PERSONAL_KIT_BIN")"). Run it with: exakit exasol" "$(said)"
check "...recorded" "2.5.0|2.5.0" "$(manifest_get runtime.version)|$(manifest_get desired.runtime.personal)"
check "the old launcher's copy is gone" no "$(yn test -e "$EXAKIT_HOME/cache/personal-launcher-before-update")"
check "stopped once, by the old launcher, on the 0.3.0 folder" "2.4.0 stop --deployment-dir $OLDROOT/default" "$(calls stop)"
check "started once, by the new launcher, on the new folder" "2.5.0 start --deployment-dir $NEW" "$(calls start)"
check "the database runs again" running "$(state exa-030)"
has "nothing 2.5 ran before the rename: its first call saw starter-kit-local" "[$NAME theirs ]" "$(first_25)"
hasnt "...and never a default" "default" "$(first_25)"
check "the 20-session limit is gone, the rest kept, a backup beside it" "no|yes|yes" \
    "$(yn grep -q maxConnectionsLicenseLimit "$NEW/$CONF_REL")|$(yn grep -q 'other = 1' "$NEW/$CONF_REL")|$(yn test -f "$NEW/$CONF_REL.before-session-limit")"
check "...recorded as lifted" lifted "$(manifest_get runtime.session_limit)"
has "the stop line is said" "personal 2.4.0 -> 2.5.0 needs the database stopped." "$(said)"
has "approved line 5, exactly" "$L5" "$(said)"
before "...after the stop line" "needs the database stopped" "$L5"
before "...and after the stop" "OK Database stopped" "$L5"
check "the stop line is said once" 1 "$(said | grep -c 'needs the database stopped')"
check "their own deployment is not stopped or started" 0 "$(sed 's/ \[.*//' "$STUB_CALLS" | grep -cE '^[0-9.]+ (stop|start) .*theirs')"
check "...and is still theirs, moved by the 2.5 launcher like any stopped legacy one" "yes|stopped" \
    "$(yn test -d "$NEWROOT/theirs")|$(state exa-theirs)"
fresh
check "nothing is missing afterwards" "" "$(exakit_personal_db_state)"
upd
check "a second update: nothing to do" "0|personal|current" "$UPD_RC|$(row)"
check "...no stop, no start" "" "$(calls 'st(op|art)')"

echo "owner kit, the 0.3.0 record with no id, the database stopped:"
reset_home
seed "$OLDROOT/default" exa-030b 8563
kit030 "$OLDROOT/default" 2.4.0
upd
check "succeeds, updated" "0|personal|updated" "$UPD_RC|$(row)"
check "the id is recorded from the folder, and followed" "exa-030b|$NEW" "$(manifest_get runtime.deployment_id)|$(manifest_get runtime.deployment_dir)"
check "Q8: a stopped database is started once at the end, never stopped" "2.5.0 start --deployment-dir $NEW|running" "$(calls 'st(op|art)')|$(state exa-030b)"
check "...its limit lifted for its next start" no "$(yn grep -q maxConnectionsLicenseLimit "$NEW/$CONF_REL")"
has "line 5" "$L5" "$(said)"

echo "a launcher at 2.5.0 already, the database still default in the 2.5 root:"
reset_home
seed "$NEWROOT/default" exa-25 8563 running
kit030 "$NEWROOT/default" 2.5.0 exa-25
upd
check "succeeds, current (no launcher to replace)" "0|personal|current" "$UPD_RC|$(row)"
check "renamed in the 2.5 root" "yes|no" "$(yn test -d "$NEW")|$(yn test -e "$NEWROOT/default")"
check "the records follow" "$NEW|$NEW|$NAME" \
    "$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.ownership_path)|$(manifest_get runtime.deployment_name)"
check "nothing downloaded" no "$(yn test -e "$WORK/downloads")"
check "one restart" "2.5.0 stop --deployment-dir $NEWROOT/default
2.5.0 start --deployment-dir $NEW" "$(calls 'st(op|art)')"
check "...running again" running "$(state exa-25)"
check "its limit lifted while stopped" "no|lifted" "$(yn grep -q maxConnectionsLicenseLimit "$NEW/$CONF_REL")|$(manifest_get runtime.session_limit)"
has "a line says the restart first" "WARN The database stops and starts again once, to rename it to 'starter-kit-local'." "$(said)"
has "line 5" "$L5" "$(said)"
before "...after the stop" "OK Database stopped" "$L5"

echo "a launcher at 2.5.0, the database still default in the legacy root (it ran when 2.5.0 came):"
reset_home
seed "$OLDROOT/default" exa-25b 8563 running
kit030 "$OLDROOT/default" 2.5.0
upd
check "succeeds" "0|personal|current" "$UPD_RC|$(row)"
check "moved by the launcher after the stop, followed by its id, renamed where it is" "yes|no|no" \
    "$(yn test -d "$NEW")|$(yn test -e "$OLDROOT/default")|$(yn test -e "$NEWROOT/default")"
check "...the records with it" "$NEW|exa-25b" "$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.deployment_id)"
check "...one restart" 2 "$(calls 'st(op|art)' | grep -c .)"
check "...running again" running "$(state exa-25b)"

echo "a database already starter-kit-local: no rename:"
reset_home
seed "$NEW" exa-new 8563 running
printf '[DB_PARAMS]\nother = 1\n' > "$NEW/$CONF_REL"
kit030 "$NEW" 2.5.0 exa-new
upd
check "current launcher: nothing to do" "0|personal|current" "$UPD_RC|$(row)"
check "...no stop, no start, no rename line" "|no" "$(calls 'st(op|art)')|$(yn grep -qF "$L5" "$SAID")"
reset_home
seed "$OLD" exa-old 8563 running
kit030 "$OLD" 2.4.0 exa-old
upd
check "launcher 2.4.0 over a starter-kit-local: updated" "0|personal|updated" "$UPD_RC|$(row)"
hasnt "...with no rename" "Renaming the database" "$(said)"
check "...moved by the new launcher and followed" "yes|$NEW" "$(yn test -d "$NEW")|$(manifest_get runtime.deployment_dir)"
check "...one restart" "2.4.0 stop --deployment-dir $OLD
2.5.0 start --deployment-dir $NEW" "$(calls 'st(op|art)')"

echo "the rename target exists: nothing is changed:"
reset_home
seed "$OLDROOT/default" exa-t1 8563 running
kit030 "$OLDROOT/default" 2.4.0 exa-t1
mkdir -p "$OLD"
OLD_SHA="$(sha "$EXAKIT_BIN_DIR/exasol")"
upd
check "the update runs to its end" 0 "$UPD_RC"
check "the row waits for the next update" "personal|deferred|exakit update" "$(row 1-2,5)"
has "said, with the folder in the way" "WARN The database 'default' was not renamed to 'starter-kit-local', because ~/.exasol/personal/deployments/starter-kit-local already exists. Nothing was changed." "$(said)"
has "...and when it is tried again" "INFO The next exakit update tries again." "$(said)"
check "nothing stopped, nothing downloaded" "|no" "$(calls 'st(op|art)')|$(yn test -e "$WORK/downloads")"
check "...still running, still default, the launcher as it was" "running|yes|$OLD_SHA" \
    "$(state exa-t1)|$(yn test -d "$OLDROOT/default")|$(sha "$EXAKIT_BIN_DIR/exasol")"
check "...the records as they were" "$OLDROOT/default|2.4.0" "$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.version)"
hasnt "...never called updated" "Runtime updated" "$(said)"
check "...the reason kept for exakit status --json" yes "$(yn grep -q "was not renamed to 'starter-kit-local'" "$EXAKIT_HOME/.last-failure")"
rmdir "$OLD"
upd
check "the folder out of the way: the next update goes through" "0|personal|updated|yes" "$UPD_RC|$(row)|$(yn test -d "$NEW")"
check "...and the earlier reason is gone" no "$(yn test -e "$EXAKIT_HOME/.last-failure")"
reset_home
seed "$OLDROOT/default" exa-t2 8563 running
kit030 "$OLDROOT/default" 2.4.0 exa-t2
mkdir -p "$NEW"
upd
has "a starter-kit-local in the 2.5 root blocks it too (2.5 would not move one onto it)" \
    "because ~/.exasol/launcher/deployments/starter-kit-local already exists. Nothing was changed." "$(said)"
check "...nothing stopped" "|running" "$(calls 'st(op|art)')|$(state exa-t2)"
reset_home
seed "$OLDROOT/default" exa-t3 8563
kit030 "$OLDROOT/default" 2.4.0 exa-t3
: > "$OLDROOT/default/.dirmutex.exclusive"
upd
has "a launcher command holding it: not renamed" "because another Exasol Personal command is using it. Nothing was changed." "$(said)"
check "...the row waits" "personal|deferred" "$(row)"
rm -f "$OLDROOT/default/.dirmutex.exclusive"
# --json: the reason travels with the row.
reset_home
seed "$OLDROOT/default" exa-t4 8563 running
kit030 "$OLDROOT/default" 2.4.0 exa-t4
mkdir -p "$OLD"
J="$(fresh; unset EXAKIT_UPDATE_RESULTS
     exakit_update_targets() { printf 'personal\n'; }
     _exakit_marketplace_warm_about() { :; }; exakit_versions_update_cache() { :; }
     mcp_sidecar_refresh() { :; }; exakit_autostart_refresh() { :; }; exakit_report_readonly_allowlist() { :; }
     exakit_core_update_check() { :; }; exakit_core_preprocessor_verify() { :; }
     exakit_update --json --yes </dev/null 2>/dev/null)"
jq_py() { printf '%s' "$J" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1" 2>&1; }
check "--json: one object, deferred" deferred "$(jq_py 'd["status"]')"
check "--json: the personal row, remedy exakit update" "personal|exakit update" "$(jq_py 'd["deferred"][0]["component"] + "|" + d["deferred"][0]["remedy"]')"
has "--json: the row says why" "already exists" "$(jq_py 'd["deferred"][0].get("error", "")')"
check "--json: the hint is the row's" "Run exakit update again once that is solved." "$(jq_py 'd["remedy_hint"]')"
check "--json: still running, not renamed" "running|yes" "$(state exa-t4)|$(yn test -d "$OLDROOT/default")"
check "--json: the reason kept for exakit status --json" yes "$(yn grep -q "was not renamed to 'starter-kit-local'" "$EXAKIT_HOME/.last-failure")"
rmdir "$OLD"
J="$(fresh; unset EXAKIT_UPDATE_RESULTS
     exakit_update_targets() { printf 'personal\n'; }
     _exakit_marketplace_warm_about() { :; }; exakit_versions_update_cache() { :; }
     mcp_sidecar_refresh() { :; }; exakit_autostart_refresh() { :; }; exakit_report_readonly_allowlist() { :; }
     exakit_core_update_check() { :; }; exakit_core_preprocessor_verify() { :; }
     exakit_update --json --yes </dev/null 2>/dev/null)"
check "--json: the next update goes through" "updated|personal" "$(jq_py 'd["status"] + "|" + d["updated"][0]["component"]')"
check "--json: ...and the earlier reason is gone (not put back)" no "$(yn test -e "$EXAKIT_HOME/.last-failure")"

echo "a swap that fails is put back:"
# The download fails its checksum: no new launcher.
reset_home
seed "$OLDROOT/default" exa-u1 8563 running
kit030 "$OLDROOT/default" 2.4.0
OLD_SHA="$(sha "$EXAKIT_BIN_DIR/exasol")"; OLD_RECEIPT="$(manifest_get components.personal.ownership_sha256)"
DOWNLOAD="$WORK/corrupt"
upd
check "the update runs to its end, the row waits" "0|personal|deferred|exakit update" "$UPD_RC|$(row 1-2,5)"
has "the checksum is what failed" "does not match the checksum this kit pins" "$(said)"
has "said, with what is as it was" "WARN Exasol Personal was not updated to 2.5.0, because the new launcher could not be installed. The launcher and the database are as they were." "$(said)"
check "the launcher put back, with its receipt" "$OLD_SHA|$OLD_RECEIPT|kit" \
    "$(sha "$EXAKIT_BIN_DIR/exasol")|$(manifest_get components.personal.ownership_sha256)|$(manifest_get components.personal.ownership)"
check "the folder renamed back" "yes|no|no" "$(yn test -d "$OLDROOT/default")|$(yn test -e "$OLD")|$(yn test -e "$NEW")"
check "the records put back" "$OLDROOT/default|$OLDROOT/default|default|2.4.0" \
    "$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.ownership_path)|$(manifest_get runtime.deployment_name)|$(manifest_get runtime.version)"
check "it ran, so it runs again, started by the old launcher on its old folder" \
    "2.4.0 stop --deployment-dir $OLDROOT/default
2.4.0 start --deployment-dir $OLDROOT/default|running" "$(calls 'st(op|art)')|$(state exa-u1)"
check "no 2.5 command ever ran" "" "$(first_25)"
check "its limit is as it was" yes "$(yn grep -q maxConnectionsLicenseLimit "$OLDROOT/default/$CONF_REL")"
check "the copy of the launcher is gone" no "$(yn test -e "$EXAKIT_HOME/cache/personal-launcher-before-update")"
# Stopped before: put back, and not started.
reset_home
seed "$OLDROOT/default" exa-u2 8563
kit030 "$OLDROOT/default" 2.4.0 exa-u2
DOWNLOAD="$WORK/corrupt"
upd
check "stopped before: put back, the row waits" "personal|deferred|yes" "$(row)|$(yn test -d "$OLDROOT/default")"
check "...and never started" "|stopped" "$(calls 'st(op|art)')|$(state exa-u2)"
# The new launcher is installed but does not run: put back.
reset_home
seed "$OLDROOT/default" exa-u3 8563 running
kit030 "$OLDROOT/default" 2.4.0 exa-u3
OLD_SHA="$(sha "$EXAKIT_BIN_DIR/exasol")"
cp "$WORK/exasol-2.5.0-broken" "$WORK/download-broken"
printf '#!/bin/sh\nexit 126\n' > "$WORK/download-broken"; chmod +x "$WORK/download-broken"
DOWNLOAD="$WORK/download-broken"; PIN="$(sha "$WORK/download-broken")"
upd
PIN="$(sha "$WORK/exasol-2.5.0")"
has "a launcher that does not run: said" "because the new launcher did not run on this computer. The launcher and the database are as they were." "$(said)"
check "...put back: the launcher, the folder, the records, running again" "$OLD_SHA|yes|$OLDROOT/default|running" \
    "$(sha "$EXAKIT_BIN_DIR/exasol")|$(yn test -d "$OLDROOT/default")|$(manifest_get runtime.deployment_dir)|$(state exa-u3)"
# A copy of a launcher an earlier update could not put back is never written
# over or removed: this update keeps its own beside it, and its undo puts back
# only what it replaced.
reset_home
seed "$OLDROOT/default" exa-u10 8563 running
kit030 "$OLDROOT/default" 2.4.0 exa-u10
U10_SHA="$(sha "$EXAKIT_BIN_DIR/exasol")"
EARLIER="$EXAKIT_HOME/cache/personal-launcher-before-update/exasol"
mkdir -p "$(dirname "$EARLIER")"
printf '#!/bin/sh\necho 2.3.0\n' > "$EARLIER"; chmod +x "$EARLIER"
EARLIER_SHA="$(sha "$EARLIER")"
DOWNLOAD="$WORK/corrupt"
upd
DOWNLOAD="$WORK/exasol-2.5.0"
check "an earlier copy there: the undo puts back the launcher this update replaced" "$U10_SHA|personal|deferred" \
    "$(sha "$EXAKIT_BIN_DIR/exasol")|$(row)"
check "...the earlier copy kept as it was, this update's own copy gone" "$EARLIER_SHA|0" \
    "$(sha "$EARLIER")|$(find "$(dirname "$EARLIER")" -name 'update-*' | grep -c .)"
upd
check "...an update that goes through: the earlier copy still kept, nothing else left" "personal|updated|$EARLIER_SHA|exasol" \
    "$(row)|$(sha "$EARLIER")|$(ls "$(dirname "$EARLIER")" | tr '\n' ' ' | sed 's/ $//')"
# The new launcher moves the folder on its first command, then does not
# answer: the folder comes back from the 2.5 root.
reset_home
seed "$OLDROOT/default" exa-u4 8563 running
kit030 "$OLDROOT/default" 2.4.0 exa-u4
DOWNLOAD="$WORK/exasol-2.5.0-broken"; PIN="$(sha "$WORK/exasol-2.5.0-broken")"
upd
PIN="$(sha "$WORK/exasol-2.5.0")"
has "it moved the folder first, then did not answer" "2.5.0 --version" "$(cat "$STUB_CALLS")"
check "...the folder is brought back to its 0.3.0 place and name" "yes|no|no" \
    "$(yn test -d "$OLDROOT/default")|$(yn test -e "$NEW")|$(yn test -e "$OLD")"
check "...its data with it, the records put back" "tables of exa-u4|$OLDROOT/default|default" \
    "$(cat "$OLDROOT/default/local/runtime/exa/data.bin")|$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.deployment_name)"
check "...the old launcher back, the database running again" "2.4.0|running" "$("$EXAKIT_BIN_DIR/exasol" version)|$(state exa-u4)"
# The stop fails: nothing is changed.
reset_home
seed "$OLDROOT/default" exa-u5 8563 running
kit030 "$OLDROOT/default" 2.4.0 exa-u5
upd_stop_fails() { STUB_STOP_RC=1; export STUB_STOP_RC; upd; unset STUB_STOP_RC; }
upd_stop_fails
has "the stop fails: said" "WARN The database did not stop, so it was not updated. Nothing was changed." "$(said)"
check "...still running, not renamed, nothing downloaded" "running|yes|no" \
    "$(state exa-u5)|$(yn test -d "$OLDROOT/default")|$(yn test -e "$WORK/downloads")"
check "...the row waits" "personal|deferred" "$(row)"
# The kit's record cannot be written after the stop (a full disk, a kit home
# that is not writable): the rename is put back, and the database runs again.
reset_home
seed "$OLDROOT/default" exa-u6 8563 running
kit030 "$OLDROOT/default" 2.4.0 exa-u6
U6_SHA="$(sha "$EXAKIT_BIN_DIR/exasol")"
upd_home_locked() {
    ( personal_stop() {
          personal_deploy_dir_refresh
          run_logged "$(personal_cli)" stop --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" || return 1
          chmod 555 "$EXAKIT_HOME"
      }
      upd )
    chmod 755 "$EXAKIT_HOME"
    rm -f "$EXAKIT_HOME/.update.lock"
}
upd_home_locked
has "the record cannot be written: the rename is said not to have happened" \
    "WARN The database 'default' was not renamed to 'starter-kit-local', because the kit could not write its record. Nothing was changed." "$(said)"
check "...the folder back under its 0.3.0 name, the record as it was" "yes|no|no|$OLDROOT/default" \
    "$(yn test -d "$OLDROOT/default")|$(yn test -e "$OLD")|$(yn test -e "$NEW")|$(manifest_get runtime.deployment_dir)"
check "...it ran, so it runs again, on its 0.3.0 folder, the launcher as it was" "running|2.4.0 start --deployment-dir $OLDROOT/default|$U6_SHA" \
    "$(state exa-u6)|$(calls start)|$(sha "$EXAKIT_BIN_DIR/exasol")"
check "...the update runs to its end, the row waits" "0|personal|deferred" "$UPD_RC|$(row)"
# A new launcher that writes a line after its version (an update notice): it
# ran, so the update stands (a `| grep -q` under pipefail read it as one
# that did not run, and put everything back).
reset_home
seed "$OLDROOT/default" exa-u7 8563 running
kit030 "$OLDROOT/default" 2.4.0 exa-u7
DOWNLOAD="$WORK/exasol-2.5.0-chatty"; PIN="$(sha "$WORK/exasol-2.5.0-chatty")"
upd
check "a launcher that writes after its version: updated, not put back" "0|personal|updated|$PIN|yes" \
    "$UPD_RC|$(row)|$(sha "$EXAKIT_PERSONAL_KIT_BIN")|$(yn test -d "$NEW")"
hasnt "...never said not to run" "did not run on this computer" "$(said)"
PIN="$(sha "$WORK/exasol-2.5.0")"
# A new launcher whose first command is slow (its 2.5 move) is not a broken
# one: it gets EXAKIT_PERSONAL_FIRST_RUN_TIMEOUT, not the probes' bound, and is
# asked once more when that runs out, before anything is put back.
for _slow in "120 by default" "3, then once more"; do
    reset_home
    seed "$OLDROOT/default" exa-u11 8563 running
    kit030 "$OLDROOT/default" 2.4.0 exa-u11
    DOWNLOAD="$WORK/exasol-2.5.0-slow"; PIN="$(sha "$WORK/exasol-2.5.0-slow")"
    case "$_slow" in
        3*) ( EXAKIT_PERSONAL_PROBE_TIMEOUT=3 EXAKIT_PERSONAL_FIRST_RUN_TIMEOUT=3; export EXAKIT_PERSONAL_PROBE_TIMEOUT EXAKIT_PERSONAL_FIRST_RUN_TIMEOUT; upd; echo "$UPD_RC" > "$WORK/slow.rc" ) ;;
        *)  ( EXAKIT_PERSONAL_PROBE_TIMEOUT=3; export EXAKIT_PERSONAL_PROBE_TIMEOUT; upd; echo "$UPD_RC" > "$WORK/slow.rc" ) ;;
    esac
    check "a slow first command ($_slow): the update stands" "0|personal|updated|$PIN|yes" \
        "$(cat "$WORK/slow.rc")|$(row)|$(sha "$EXAKIT_PERSONAL_KIT_BIN")|$(yn test -d "$NEW")"
    hasnt "...never said not to run ($_slow)" "did not run on this computer" "$(said)"
done
DOWNLOAD="$WORK/exasol-2.5.0"; PIN="$(sha "$WORK/exasol-2.5.0")"
# A record that cannot be written after the swap went through (the lift's,
# here, after the folder's own record followed the move): the database that
# ran is started again first, then the run ends with that write's own error.
upd_lift_locked() {
    ( eval "_w_lift() $(declare -f personal_update_lift | sed 1d)"
      personal_update_lift() { chmod 555 "$EXAKIT_HOME"; _w_lift "$@"; }
      upd "$@"; echo "$UPD_RC" > "$WORK/locked.rc" )
    chmod 755 "$EXAKIT_HOME"
    rm -f "$EXAKIT_HOME/.update.lock"
}
LOCKED_ERR="is not writable, so runtime.session_limit could not be recorded"
reset_home
seed "$OLDROOT/default" exa-u12 8563 running
kit030 "$OLDROOT/default" 2.4.0 exa-u12
upd_lift_locked
check "owner kit, a record that fails after the swap: running again, then the run ends (exit 1)" "running|yes|$PIN|1" \
    "$(state exa-u12)|$(yn test -d "$NEW")|$(sha "$EXAKIT_PERSONAL_KIT_BIN")|$(cat "$WORK/locked.rc")"
has "...with that write's own error" "$LOCKED_ERR" "$(said)"
check "...started once, after the stop" "2.4.0 stop --deployment-dir $OLDROOT/default
2.5.0 start --deployment-dir $NEW" "$(calls 'st(op|art)')"
THEIRS="$WORK/userbin/exasol"
reset_home
seed "$OLDROOT/default" exa-u13 8563 running
user030 "$OLDROOT/default" "$THEIRS" 2.4.0
upd_lift_locked
check "owner user, the same: running again, their launcher as it was, then the run ends (exit 1)" "running|yes|$(sha "$WORK/exasol-2.4.0")|1" \
    "$(state exa-u13)|$(yn test -d "$NEW")|$(sha "$THEIRS")|$(cat "$WORK/locked.rc")"
has "...with that write's own error" "$LOCKED_ERR" "$(said)"
reset_home
seed "$NEWROOT/default" exa-u14 8563 running
kit030 "$NEWROOT/default" 2.5.0 exa-u14
upd_lift_locked
check "a launcher already current (the rename only), the same: running again, then the run ends (exit 1)" "running|yes|1" \
    "$(state exa-u14)|$(yn test -d "$NEW")|$(cat "$WORK/locked.rc")"
has "...with that write's own error" "$LOCKED_ERR" "$(said)"
# The new launcher moved the user's other stopped databases on its first
# command, then the undo put the old one back: those are not "as they were".
reset_home
seed "$OLDROOT/default" exa-u8 8563 running
seed "$OLDROOT/demo" exa-demo 8600             # the user's, made with the kit's 2.4, stopped
seed "$OLDROOT/dev" exa-dev8 8601
kit030 "$OLDROOT/default" 2.4.0 exa-u8
DOWNLOAD="$WORK/exasol-2.5.0-broken"; PIN="$(sha "$WORK/exasol-2.5.0-broken")"
upd
PIN="$(sha "$WORK/exasol-2.5.0")"
check "the undo: the kit's database back, theirs moved by the new launcher" "yes|yes|yes" \
    "$(yn test -d "$OLDROOT/default")|$(yn test -d "$NEWROOT/demo")|$(yn test -d "$NEWROOT/dev")"
has "...the launcher and the kit's database as they were, named" \
    "WARN Exasol Personal was not updated to 2.5.0, because the new launcher did not run on this computer. The launcher and the database 'default' are as they were." "$(said)"
hasnt "...never that every database is as it was" "The launcher and the database are as they were." "$(said)"
has "...where theirs are now" "INFO Your other databases 'demo' and 'dev' are now in ~/.exasol/launcher/deployments, where Exasol Personal 2.5 keeps them." "$(said)"
# Owner user: their own launcher put back, their other database moved.
THEIRS="$WORK/userbin/exasol"
reset_home
seed "$OLDROOT/default" exa-u9 8563 running
seed "$OLDROOT/dev" exa-dev9 8601
user030 "$OLDROOT/default" "$THEIRS" 2.4.0
DOWNLOAD="$WORK/exasol-2.5.0-broken"; PIN="$(sha "$WORK/exasol-2.5.0-broken")"
upd
PIN="$(sha "$WORK/exasol-2.5.0")"
check "owner user, the undo: their launcher 2.4.0 as it was, their database back, their dev moved" "2.4.0|yes|yes" \
    "$("$THEIRS" version)|$(yn test -d "$OLDROOT/default")|$(yn test -d "$NEWROOT/dev")"
has "...said, one database" "INFO Your other database 'dev' is now in ~/.exasol/launcher/deployments, where Exasol Personal 2.5 keeps it." "$(said)"
DOWNLOAD="$WORK/exasol-2.5.0"

echo "the start after the update fails without the limit: the file is put back:"
reset_home
seed "$OLDROOT/default" exa-s1 8563 running
kit030 "$OLDROOT/default" 2.4.0 exa-s1
echo 1 > "$STUB_STATE/start-fails"
upd
check "updated (the launcher and the name stand)" "personal|updated|$NEW" "$(row)|$(manifest_get runtime.deployment_dir)"
has "said, as the lift says it" "The 20-session limit was not removed, because the database did not start without it. The file is as it was, and the database is running again." "$(said)"
check "...the file as it was, not recorded as lifted, running" "yes||running" \
    "$(yn grep -q maxConnectionsLicenseLimit "$NEW/$CONF_REL")|$(manifest_get runtime.session_limit 2>/dev/null)|$(state exa-s1)"
hasnt "...and the update does not start it a second time" "Bringing the database back up" "$(said)"

echo "owner user: a database the user let the 0.3.0 kit use, run by their own 2.4.0:"
reset_home
THEIRS="$WORK/userbin/exasol"
seed "$OLDROOT/default" exa-usr 8563 running
seed "$OLDROOT/dev" exa-dev 8564
user030 "$OLDROOT/default" "$THEIRS" 2.4.0
upd
check "succeeds, updated" "0|personal|updated" "$UPD_RC|$(row)"
check "their launcher, at its own path, is as it was (#41)" "$(sha "$WORK/exasol-2.4.0")|2.4.0" "$(sha "$THEIRS")|$("$THEIRS" version)"
check "...theirs stays theirs, and the kit runs its own checked release from the kit folder" \
    "kit|$EXAKIT_PERSONAL_KIT_BIN|$PIN|$THEIRS|$PIN|no" \
    "$(manifest_get components.personal.ownership)|$(manifest_get components.personal.ownership_path)|$(manifest_get components.personal.ownership_sha256 2>/dev/null)|$(manifest_get components.personal.user_launcher)|$(sha "$EXAKIT_PERSONAL_KIT_BIN")|$(yn test -e "$EXAKIT_BIN_DIR/exasol")"
check "their database is starter-kit-local, still theirs" "yes|no|user|$NEW|$NEW" \
    "$(yn test -d "$NEW")|$(yn test -e "$OLDROOT/default")|$(manifest_get runtime.ownership)|$(manifest_get runtime.ownership_path)|$(manifest_get runtime.deployment_dir)"
check "...never managed, so never destroyed" no "$(fresh; yn exakit_component_is_managed database)"
check "...its id recorded (0.3.0 kept none for theirs)" exa-usr "$(manifest_get runtime.deployment_id)"
check "...its limit lifted" "no|lifted" "$(yn grep -q maxConnectionsLicenseLimit "$NEW/$CONF_REL")|$(manifest_get runtime.session_limit)"
check "one restart: stopped by their 2.4, started by the kit's 2.5" "2.4.0 stop --deployment-dir $OLDROOT/default
2.5.0 start --deployment-dir $NEW|running" "$(calls 'st(op|art)')|$(state exa-usr)"
has "nothing 2.5 ran before the rename" "[dev $NAME ]" "$(first_25)"
check "the download came before the stop" yes \
    "$([ "$(grep -n 'Downloading Exasol launcher' "$SAID" | head -1 | cut -d: -f1)" -lt "$(grep -n 'OK Database stopped' "$SAID" | head -1 | cut -d: -f1)" ] && echo yes)"
has "said: where the kit's launcher is" "INFO The kit's Exasol launcher is now in $(ui_tilde "$(dirname "$EXAKIT_PERSONAL_KIT_BIN")"). Run it with: exakit exasol" "$(said)"
hasnt "...nothing about a launcher of theirs being updated" "our Exasol Personal launcher" "$(said)"
has "...line 5" "$L5" "$(said)"
check "their other database: moved by the kit's 2.5, never stopped or started" "yes|stopped|0" \
    "$(yn test -d "$NEWROOT/dev")|$(state exa-dev)|$(sed 's/ \[.*//' "$STUB_CALLS" | grep -cE '^[0-9.]+ (stop|start) .*/dev$')"
check "a second update: nothing to do (the kit's own launcher is current)" "personal|current" "$(upd; row)"
# THEIR LAUNCHER IS NEVER TOUCHED (#41): matrix_place, above.
# The four places of the matrix, each in a process of its own (its own HOME and
# kit home): what each said, and its counts.
_matrix_pids=""
for _place in kitbin home path link; do
    RENAME_MATRIX_PLACE="$_place" RENAME_MATRIX_RESULT="$WORK/matrix.$_place.count" bash "$0" > "$WORK/matrix.$_place.out" 2>&1 &
    _matrix_pids="$_matrix_pids $!"
done
for _p in $_matrix_pids; do wait "$_p"; done
for _place in kitbin home path link; do
    cat "$WORK/matrix.$_place.out"
    if [ -f "$WORK/matrix.$_place.count" ]; then
        read -r _mp _mf < "$WORK/matrix.$_place.count"
        PASS=$((PASS + _mp)); FAIL=$((FAIL + _mf))
    else
        check "matrix $_place ran to its end" yes no
    fi
done
# Their download fails its checksum: nothing changed.
reset_home
seed "$OLDROOT/default" exa-dl 8563 running
user030 "$OLDROOT/default" "$THEIRS" 2.4.0
DL_SHA="$(sha "$THEIRS")"
DOWNLOAD="$WORK/corrupt"
upd
has "a download that fails its check: said" "Exasol Personal was not updated to 2.5.0, because the new launcher could not be installed. The launcher and the database are as they were." "$(said)"
check "...nothing stopped, nothing renamed, theirs as it was" "|yes|$DL_SHA|running" \
    "$(calls 'st(op|art)')|$(yn test -d "$OLDROOT/default")|$(sha "$THEIRS")|$(state exa-dl)"
# The rename target exists: put back, theirs as it was.
reset_home
seed "$OLDROOT/default" exa-ut 8563 running
user030 "$OLDROOT/default" "$THEIRS" 2.4.0
UT_SHA="$(sha "$THEIRS")"
mkdir -p "$OLD"
upd
has "the target exists: said" "because ~/.exasol/personal/deployments/starter-kit-local already exists. Nothing was changed." "$(said)"
check "...theirs as it was, still running" "$UT_SHA|running|personal|deferred" "$(sha "$THEIRS")|$(state exa-ut)|$(row)"
# EXAKIT_CONFIRM_RUNTIME_UPDATE=0 keeps it as it is.
reset_home
seed "$OLDROOT/default" exa-no 8563 running
user030 "$OLDROOT/default" "$THEIRS" 2.4.0
EXAKIT_CONFIRM_RUNTIME_UPDATE=0; export EXAKIT_CONFIRM_RUNTIME_UPDATE
upd
unset EXAKIT_CONFIRM_RUNTIME_UPDATE
check "EXAKIT_CONFIRM_RUNTIME_UPDATE=0: left alone, the row waits for --yes" "personal|deferred|exakit update --yes|running" \
    "$(row 1-2,5)|$(state exa-no)"
# Their launcher at 2.5.0 already, their database still default in the 2.5
# root: renamed, their launcher untouched.
reset_home
seed "$NEWROOT/default" exa-u25 8563 running
user030 "$NEWROOT/default" "$THEIRS" 2.5.0
manifest_set runtime.deployment_id exa-u25
U25_SHA="$(sha "$THEIRS")"
upd
check "their 2.5.0: renamed, their launcher untouched, the kit's own takes over" "yes|$U25_SHA|kit|user" \
    "$(yn test -d "$NEW")|$(sha "$THEIRS")|$(manifest_get components.personal.ownership)|$(manifest_get runtime.ownership)"
check "...one restart" 2 "$(calls 'st(op|art)' | grep -c .)"
# The same, a download that fails its check: theirs runs the database as
# before, its receipt as it was, nothing in the kit folder.
reset_home
seed "$NEWROOT/default" exa-u25b 8563 running
user030 "$NEWROOT/default" "$THEIRS" 2.5.0
manifest_set runtime.deployment_id exa-u25b
DOWNLOAD="$WORK/exasol-2.4.0"
U25_SHA="$(sha "$THEIRS")"
upd
DOWNLOAD="$WORK/exasol-2.5.0"
check "their 2.5.0, a bad download: theirs as it was, its receipt too, no kit launcher" "$U25_SHA|user|$THEIRS|no|running" \
    "$(sha "$THEIRS")|$(manifest_get components.personal.ownership)|$(manifest_get components.personal.ownership_path)|$(yn test -e "$EXAKIT_PERSONAL_KIT_BIN")|$(state exa-u25b)"
# A plan downloads nothing.
reset_home
seed "$NEWROOT/default" exa-u25p 8563 running
user030 "$NEWROOT/default" "$THEIRS" 2.5.0
manifest_set runtime.deployment_id exa-u25p
upd personal --plan
check "their 2.5.0, a plan: nothing downloaded, no kit launcher" "no|no|user" \
    "$(yn test -e "$WORK/downloads")|$(yn test -e "$EXAKIT_PERSONAL_KIT_BIN")|$(manifest_get components.personal.ownership)"
# A database of the kit's own that ran on the user's 2.5: the kit's own launcher
# goes into the kit folder at the update, theirs stays as it is.
reset_home
seed "$NEWROOT/default" exa-kdb 8563 running
user030 "$NEWROOT/default" "$THEIRS" 2.5.0
exakit_record_ownership database kit "$NEWROOT/default"
manifest_set runtime.deployment_id exa-kdb
KDB_SHA="$(sha "$THEIRS")"
upd
check "kit database, their 2.5.0: the kit's own launcher in the kit folder, theirs untouched" "$KDB_SHA|2.5.0|kit|$THEIRS|kit" \
    "$(sha "$THEIRS")|$("$EXAKIT_PERSONAL_KIT_BIN" version)|$(manifest_get components.personal.ownership)|$(manifest_get components.personal.user_launcher)|$(manifest_get runtime.ownership)"
# A kit database run by the user's own 2.4 (0.3.0 used their launcher):
# their launcher stays, and the kit's database moves into the kit's private
# home under the kit's own 2.5 (Q15, below in full).
reset_home
seed "$OLDROOT/default" exa-mix 8563 running
user030 "$OLDROOT/default" "$THEIRS" 2.4.0
exakit_record_ownership database kit "$OLDROOT/default"
MIX_SHA="$(sha "$THEIRS")"
upd
check "kit database, their 2.4: their launcher kept, the database moved and running (Q15)" "$MIX_SHA|no|running|personal|updated" \
    "$(sha "$THEIRS")|$(yn test -d "$OLDROOT/default")|$(state exa-mix)|$(row)"

echo "owner user: the MCP server the 0.3.0 kit set up beside their database goes at uninstall, one of theirs never:"
# mcp030: what a 0.3.0 kit recorded about the MCP server it set up beside the
# database: no record of the folder it wrote it in (0.3.1 adds sidecar_dir).
mcp030() {
    manifest_set components.mcp_server.backend sidecar
    manifest_set components.mcp_server.port 4896
    manifest_set components.mcp_server.url http://127.0.0.1:4896/mcp
    manifest_set components.mcp_server.connection.user mcp_readonly
    manifest_set components.mcp_server.connection.password_file "$EXAKIT_HOME/credentials/mcp_readonly_password"
}
# sidecar <dir> <login|secret> [host port]: the `mcp` sidecar saved in the
# deployment (JSON, which is YAML): signing in as <login>, as the kit writes
# it, or from the deployment's own secret, as the launcher's own (the user's).
sidecar() {
    if [ "$2" = secret ]; then
        _sc_user='{"name": "EXA_USER", "valueFrom": {"secretKeyRef": {"name": "exasol-database", "key": "username"}}}'
    else
        _sc_user="{\"name\": \"EXA_USER\", \"value\": \"$2\"}"
    fi
    printf '{"version": 1, "sidecars": {"mcp": {"enabled": true, "container": {"image": "docker.io/exasol/mcp-server:2.2.0", "env": [%s, {"name": "EXA_PASSWORD", "value": "not-shown"}], "ports": [{"name": "mcp", "containerPort": 4896, "hostPort": %s, "hostIP": "127.0.0.1"}]}}}}\n' \
        "$_sc_user" "${3:-4896}" > "$1/sidecars.yaml"
}
# uninstall_dry: what `exakit uninstall --dry-run` lists, on this machine.
uninstall_dry() {
    fresh
    ( launchctl() { :; }; systemctl() { :; }; exakit_uninstall_run 1 ) 2>&1 </dev/null
}
reset_home
seed "$OLDROOT/default" exa-mcp 8563 running
user030 "$OLDROOT/default" "$THEIRS" 2.4.0
mcp030
sidecar "$OLDROOT/default" mcp_readonly
check "before the update: not provably the kit's (0.3.0 kept no record of its folder)" no "$(fresh; yn mcp_sidecar_is_kits)"
upd
check "updated" "0|personal|updated" "$UPD_RC|$(row)"
# claimed_after_start: yes when the claim's proof (uv run ... is-kits) ran
# after the one start, so its downloads never kept the database down.
claimed_after_start() {
    awk '/^2\.5\.0 start /{s=NR} /^uv .*is-kits/{u=NR} END{print (s && u && u > s) ? "yes" : "no (start " s ", claim " u ")"}' "$STUB_CALLS"
}
check "the claim runs after the one start" yes "$(claimed_after_start)"
check "the sidecar's folder recorded as the kit's, where the database is now" "$NEW" "$(manifest_get components.mcp_server.sidecar_dir)"
check "...so it is the kit's to remove" yes "$(fresh; yn mcp_sidecar_is_kits)"
un="$(uninstall_dry)"
has "exakit uninstall removes it" "will remove: the MCP server the kit set up beside your database (sidecar 'mcp')" "$un"
hasnt "...and keeps their database" "will remove: local Exasol personal deployment" "$un"
: > "$STUB_CALLS"
( fresh; exakit_mcp_operation() { :; }; _exakit_uninstall_component mcp_configs 0 ) >/dev/null 2>&1
has "...the MCP part of the uninstall switches it off and removes it" "2.5.0 sidecar disable mcp --remove --deployment-dir $NEW" \
    "$(calls 'sidecar disable')"
# Theirs: the launcher's own MCP server, signing in from the deployment's secret.
reset_home
seed "$OLDROOT/default" exa-mcq 8563 running
user030 "$OLDROOT/default" "$THEIRS" 2.4.0
mcp030
sidecar "$OLDROOT/default" secret
upd
check "a sidecar of their own: the update goes through, nothing is recorded" "personal|updated|" \
    "$(row)|$(manifest_get components.mcp_server.sidecar_dir)"
check "...never the kit's" no "$(fresh; yn mcp_sidecar_is_kits)"
hasnt "...the uninstall leaves it" "sidecar 'mcp'" "$(uninstall_dry)"
: > "$STUB_CALLS"
( fresh; exakit_mcp_operation() { :; }; _exakit_uninstall_component mcp_configs 0 ) >/dev/null 2>&1
check "...and the MCP part of the uninstall never switches it off" "" "$(calls 'sidecar disable')"
# The kit's login on another port (the user moved it, or set up their own): not proved, not claimed.
reset_home
seed "$OLDROOT/default" exa-mcr 8563 running
user030 "$OLDROOT/default" "$THEIRS" 2.4.0
mcp030
sidecar "$OLDROOT/default" mcp_readonly 4999
upd
check "the kit's login on another port: nothing recorded" "personal|updated|" "$(row)|$(manifest_get components.mcp_server.sidecar_dir)"
# Their launcher at 2.5.0 already (no launcher to replace): claimed after the
# one start too.
reset_home
seed "$NEWROOT/default" exa-mcs 8563 running
user030 "$NEWROOT/default" "$THEIRS" 2.5.0
manifest_set runtime.deployment_id exa-mcs
mcp030
sidecar "$NEWROOT/default" mcp_readonly
upd
check "their 2.5.0: renamed, the sidecar's folder recorded, after the one start" "personal|updated|$NEW|yes" \
    "$(row)|$(manifest_get components.mcp_server.sidecar_dir)|$(claimed_after_start)"
# The one question's rename claims with the database stopped: never a download.
reset_home
seed "$NEW" exa-mco 8563
user030 "$NEW" "$THEIRS" 2.5.0
mcp030
sidecar "$NEW" mcp_readonly
: > "$STUB_CALLS"; rm -f "$WORK/ensure_uv"
( fresh; mcp_sidecar_claim offline )
check "offline: claimed with the uv the kit has, as a read-only query, uv offline" "$NEW|ensure_uv readonly=1|1" \
    "$(manifest_get components.mcp_server.sidecar_dir)|$(cat "$WORK/ensure_uv")|$(grep -c '^uv run --offline ' "$STUB_CALLS")"
manifest_del components.mcp_server.sidecar_dir
: > "$STUB_CALLS"; rm -f "$WORK/ensure_uv"
( fresh; mcp_sidecar_claim )
check "...and the update's claim may download (its database runs again by then)" "$NEW|ensure_uv readonly=|0" \
    "$(manifest_get components.mcp_server.sidecar_dir)|$(cat "$WORK/ensure_uv")|$(grep -c -- '--offline' "$STUB_CALLS")"
check "...the one question's rename asks for the offline claim" 1 \
    "$(grep -c 'mcp_sidecar_claim offline$' "$ROOT/setup/lib/runtime-personal.sh")"

echo "--plan and --backup: what the update would do is said, and nothing is changed:"
# same <label> <id> <folder> <launcher> <its sha> [<state>]: nothing was
# stopped, started, downloaded, renamed, swapped, edited or claimed.
# The user's own 2.4, their database running, the MCP server the 0.3.0 kit
# set up beside it: an update would replace their launcher, rename, lift,
# restart and claim the MCP server. A plan does none of it.
reset_home
seed "$OLDROOT/default" exa-p1 8563 running
user030 "$OLDROOT/default" "$THEIRS" 2.4.0
mcp030
sidecar "$OLDROOT/default" mcp_readonly
P1_SHA="$(sha "$THEIRS")"
upd personal --plan
check "owner user --plan: answers 0, the row waits for the update itself" "0|personal|deferred|exakit update personal" \
    "$UPD_RC|$(row 1-2,5)"
same "owner user --plan" exa-p1 "$OLDROOT/default" "$THEIRS" "$P1_SHA"
check "owner user --plan: their launcher is still 2.4.0, their receipt as it was" "2.4.0|user|" \
    "$("$THEIRS" version)|$(manifest_get components.personal.ownership)|$(manifest_get components.personal.ownership_sha256 2>/dev/null)"
hasnt "...nothing about their launcher" "our Exasol Personal launcher" "$(said)"
has "...the rename" "INFO The database 'default' is renamed to 'starter-kit-local'." "$(said)"
has "...the limit" "INFO Its 20-session limit is removed." "$(said)"
has "...the one restart" "INFO The database stops and starts again once." "$(said)"
has "...and how to apply it" "INFO Apply it with: exakit update personal" "$(said)"
hasnt "...never that it did it" "$L5" "$(said)"
hasnt "...nor that their launcher was updated" "is updated to" "$(said)"
upd personal --backup
check "owner user --backup: answers 0, the row waits" "0|personal|deferred" "$UPD_RC|$(row)"
same "owner user --backup" exa-p1 "$OLDROOT/default" "$THEIRS" "$P1_SHA"
has "...it says there is nothing to back up first" "INFO This update neither deletes nor migrates the tables in your database, so there is nothing to back up first." "$(said)"
# The real update after them still has all of it to do.
upd personal
check "the update itself after the plan: updated, renamed, claimed" "personal|updated|yes|$NEW" \
    "$(row)|$(yn test -d "$NEW")|$(manifest_get components.mcp_server.sidecar_dir)"
# The kit's launcher replaced by hand with 2.5.0 (not the kit's any more),
# the 0.3.0 database still default in the 2.5 root.
reset_home
seed "$NEWROOT/default" exa-p3 8563 running
kit030 "$NEWROOT/default" 2.4.0 exa-p3
cp "$WORK/exasol-2.5.0" "$EXAKIT_BIN_DIR/exasol"
P3_SHA="$(sha "$EXAKIT_BIN_DIR/exasol")"
upd personal --plan
check "a launcher that is not the kit's, --plan: the row waits" "0|personal|deferred" "$UPD_RC|$(row)"
same "not the kit's launcher --plan" exa-p3 "$NEWROOT/default" "$EXAKIT_BIN_DIR/exasol" "$P3_SHA"
has "...it says the rename" "INFO The database 'default' is renamed to 'starter-kit-local'." "$(said)"
hasnt "...and replaces no launcher" "is replaced in place" "$(said)"
upd personal --backup
same "not the kit's launcher --backup" exa-p3 "$NEWROOT/default" "$EXAKIT_BIN_DIR/exasol" "$P3_SHA"
has "...--backup: nothing to back up first" "nothing to back up first" "$(said)"
# The kit's own launcher at 2.5.0 already, the database still default.
reset_home
seed "$NEWROOT/default" exa-p4 8563 running
kit030 "$NEWROOT/default" 2.5.0 exa-p4
P4_SHA="$(sha "$EXAKIT_BIN_DIR/exasol")"
upd personal --plan
check "a current launcher, --plan: the row waits" "0|personal|deferred" "$UPD_RC|$(row)"
same "current launcher --plan" exa-p4 "$NEWROOT/default" "$EXAKIT_BIN_DIR/exasol" "$P4_SHA"
has "...it says the restart" "INFO The database stops and starts again once." "$(said)"
upd personal --backup
same "current launcher --backup" exa-p4 "$NEWROOT/default" "$EXAKIT_BIN_DIR/exasol" "$P4_SHA"
# Nothing to do with a current launcher: current, as without the flag.
reset_home
seed "$NEW" exa-p5 8563 running
printf '[DB_PARAMS]\nother = 1\n' > "$NEW/$CONF_REL"
kit030 "$NEW" 2.5.0 exa-p5
upd personal --plan
check "nothing to do, --plan: current, nothing said about a rename" "0|personal|current|no" \
    "$UPD_RC|$(row)|$(yn grep -q 'is renamed to' "$SAID")"
# The kit's own 2.4: personal_update's plan, now with the database part, and
# the row waits rather than saying it was updated.
reset_home
seed "$OLDROOT/default" exa-p6 8563 running
kit030 "$OLDROOT/default" 2.4.0 exa-p6
P6_SHA="$(sha "$EXAKIT_BIN_DIR/exasol")"
upd personal --plan
check "the kit's own 2.4, --plan: the row waits, nothing updated" "0|personal|deferred|no" \
    "$UPD_RC|$(row)|$(yn grep -q 'Update finished - updated' "$SAID")"
same "the kit's own 2.4 --plan" exa-p6 "$OLDROOT/default" "$EXAKIT_BIN_DIR/exasol" "$P6_SHA"
has "...its plan says the rename too" "INFO The database 'default' is renamed to 'starter-kit-local'." "$(said)"
has "Q18b: the launcher line, without a semicolon" "INFO The launcher program is replaced. The database keeps its data." "$(said)"
check "Q18b: ...the old line is gone" no "$(yn grep -q 'The launcher binary is replaced' "$SAID")"
before "...before how to apply it" "is renamed to" "Apply it with: exakit update personal"

echo "the 0.3.0 kit's launcher at ~/.local/bin/exasol is removed only when it is the file the kit recorded:"
reset_home
kit030 "$OLDROOT/default" 2.4.0
LB_REC="$(manifest_get components.personal.ownership_sha256)"
printf '\n# edited by hand\n' >> "$EXAKIT_BIN_DIR/exasol"
LB_SHA="$(sha "$EXAKIT_BIN_DIR/exasol")"
personal_retire_bin_launcher "$EXAKIT_BIN_DIR/exasol" "$LB_REC"
check "edited since the kit recorded it: left as it was" "$LB_SHA" "$(sha "$EXAKIT_BIN_DIR/exasol")"
cp "$WORK/exasol-2.4.0" "$EXAKIT_BIN_DIR/exasol"
personal_retire_bin_launcher "$EXAKIT_BIN_DIR/exasol" "$LB_REC"
check "...the recorded file: removed" no "$(yn test -e "$EXAKIT_BIN_DIR/exasol")"
reset_home
seed "$OLDROOT/default" exa-lb 8563 running
kit030 "$OLDROOT/default" 2.4.0
printf '\n# edited by hand\n' >> "$EXAKIT_BIN_DIR/exasol"
LB_SHA="$(sha "$EXAKIT_BIN_DIR/exasol")"
upd
check "...and through exakit update: a launcher no longer the kit's is not updated, and left as it was" "personal|skipped|no|$LB_SHA" \
    "$(row)|$(yn test -e "$EXAKIT_PERSONAL_KIT_BIN")|$(sha "$EXAKIT_BIN_DIR/exasol")"

fi
if [ "$RENAME_HALF" = 2 ]; then
echo "Q15: the kit's own database on the user's own 2.4 moves into the kit's private home:"
# A 0.3.0 kit deployed its `default` with the 2.4 it found on PATH (owner
# kit, launcher receipt user). The update gives it the kit's own 2.5 in its
# private home (mode P): stopped by their 2.4, moved, renamed, started by the
# kit's 2.5. Their 2.4 and their other deployment are never touched.
PRIV="$EXAKIT_HOME/personal"
PRIVNEW="$PRIV/home/.exasol/launcher/deployments"
mixed030() {
    cp "$WORK/exasol-$3" "$2"
    manifest_set runtime.type personal
    manifest_set runtime.version "$3"
    manifest_set runtime.deployment_dir "$1"
    manifest_set runtime.launcher "$2"
    manifest_set runtime.dsn 127.0.0.1:8563
    exakit_record_ownership personal user "$2"
    exakit_record_ownership database kit "$1"
}
reset_home; rm -rf "$PRIV"
THEIRS="$WORK/userbin/exasol"
seed "$OLDROOT/default" exa-mx 8563 running
seed "$OLDROOT/demo" exa-demo 8564
mixed030 "$OLDROOT/default" "$THEIRS" 2.4.0
THEIRS_SHA="$(sha "$THEIRS")"
upd personal --plan
check "Q15 --plan: the row waits, nothing moved, nothing stopped" "0|personal|deferred|yes||no" \
    "$UPD_RC|$(row)|$(yn test -d "$OLDROOT/default")|$(calls 'st(op|art)')|$(yn test -e "$PRIV")"
has "Q15 --plan: ...says the kit's own 2.5 in its own folder" "INFO Exasol Personal 2.4.0 is on this computer. The starter kit uses its own Exasol Personal 2.5.0 in its own folder, so yours is not changed." "$(said)"
has "Q15 --plan: ...and the rename" "is renamed to 'starter-kit-local'." "$(said)"
upd personal
check "Q15: updated" "0|personal|updated" "$UPD_RC|$(row)"
check "Q15: in the private home as starter-kit-local, its id and data kept" "yes|exa-mx|tables of exa-mx" \
    "$(yn test -d "$PRIVNEW/$NAME")|$(sed -n 's/.*"deploymentId": "\([^"]*\)".*/\1/p' "$PRIVNEW/$NAME/.exasolLauncherState.json")|$(cat "$PRIVNEW/$NAME/local/runtime/exa/data.bin")"
check "Q15: ...its port kept" "8563" "$(personal_saved_db_port "$PRIVNEW/$NAME")"
check "Q15: the old folder gone, their demo where it was, their 2.4 untouched" "no|yes|$THEIRS_SHA" \
    "$(yn test -e "$OLDROOT/default")|$(yn test -d "$OLDROOT/demo")|$(sha "$THEIRS")"
check "Q15: records: the folder, the kit's database, the kit's wrapper" "$PRIVNEW/$NAME|kit|kit|$PRIV/bin/exasol" \
    "$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.ownership)|$(manifest_get components.personal.ownership)|$(manifest_get components.personal.ownership_path)"
check "Q15: stopped once by their 2.4, started once by the kit's 2.5" "2.4.0 stop --deployment-dir $OLDROOT/default
2.5.0 start --deployment-dir $PRIVNEW/$NAME" "$(calls 'st(op|art)')"
check "Q15: running, its limit lifted" "running|no" "$(state exa-mx)|$(yn grep -q maxConnectionsLicenseLimit "$PRIVNEW/$NAME/$CONF_REL")"
# A new launcher that does not run: everything put back, started by their 2.4.
reset_home; rm -rf "$PRIV"
seed "$OLDROOT/default" exa-mx2 8563 running
mixed030 "$OLDROOT/default" "$THEIRS" 2.4.0
DOWNLOAD="$WORK/exasol-2.5.0-broken"
PIN="$(sha "$WORK/exasol-2.5.0-broken")"
upd personal
PIN="$(sha "$WORK/exasol-2.5.0")"
check "Q15 put back: the row waits, the folder back, no private home" "personal|deferred|yes|no" \
    "$(row)|$(yn test -d "$OLDROOT/default")|$(yn test -e "$PRIV")"
check "Q15 put back: ...records as they were, running again by their 2.4" "$OLDROOT/default|user|running" \
    "$(manifest_get runtime.deployment_dir)|$(manifest_get components.personal.ownership)|$(state exa-mx2)"
has "Q15 put back: ...said" "WARN Exasol Personal was not updated to 2.5.0, because the new launcher did not run on this computer. The launcher and the database are as they were." "$(said)"

echo "the installer run again over a 0.3.0 kit:"
# The launcher step, as setup-macos.sh and setup-linux.sh run it.
inst_launcher() {
    : > "$STUB_CALLS"; : > "$SAID"
    fresh
    ( EXAKIT_PERSONAL_VERSION=2.5.0; export EXAKIT_PERSONAL_VERSION
      personal_launcher_mode_decide
      personal_install_launcher ) </dev/null >>"$SAID" 2>&1
    INST_RC=$?
}
reset_home
seed "$OLDROOT/default" exa-i1 8563 running
kit030 "$OLDROOT/default" 2.4.0
inst_launcher
check "the launcher step: done" 0 "$INST_RC"
check "the same steps: renamed, moved, followed, the launcher 2.5.0" "yes|$NEW|$PIN|kit" \
    "$(yn test -d "$NEW")|$(manifest_get runtime.deployment_dir)|$(sha "$EXAKIT_PERSONAL_KIT_BIN")|$(manifest_get components.personal.ownership)"
check "...one restart, stopped by the old launcher" "2.4.0 stop --deployment-dir $OLDROOT/default
2.5.0 start --deployment-dir $NEW|running" "$(calls 'st(op|art)')|$(state exa-i1)"
has "...line 5" "$L5" "$(said)"
hasnt "...nothing 2.5 before the rename" "default" "$(first_25)"
check "...the limit lifted" lifted "$(manifest_get runtime.session_limit)"
reset_home
seed "$OLDROOT/default" exa-i2 8563
kit030 "$OLDROOT/default" 2.4.0
inst_launcher
check "stopped: the same steps, then started once (Q8)" "yes|$NEW|2.5.0 start --deployment-dir $NEW|running" \
    "$(yn test -d "$NEW")|$(manifest_get runtime.deployment_dir)|$(calls 'st(op|art)')|$(state exa-i2)"
# The runtime step done: a launcher at 2.5.0 already, default in its root.
inst_runtime() {
    : > "$STUB_CALLS"; : > "$SAID"
    fresh
    ( eval "$STEP_LINES" ) </dev/null >>"$SAID" 2>&1
}
for _inst in setup-macos.sh setup-linux.sh; do
    STEP_LINES="$(sed -n '/^    personal_clear_stale_record$/,/^    personal_lift_session_limit || true$/p' "$ROOT/setup/$_inst" | grep -v '^ *#' | grep -v personal_clear_stale_record)"
    check "$_inst: the rename before the lift, on the database it reuses" "personal_update_current || true
personal_lift_session_limit || true" "$(printf '%s\n' "$STEP_LINES" | sed 's/^ *//')"
done
reset_home
seed "$NEWROOT/default" exa-i3 8563 running
kit030 "$NEWROOT/default" 2.5.0 exa-i3
inst_runtime
check "runtime step: renamed in the 2.5 root, one restart, the limit lifted" "yes|$NEW|2|lifted|running" \
    "$(yn test -d "$NEW")|$(manifest_get runtime.deployment_dir)|$(calls 'st(op|art)' | grep -c .)|$(manifest_get runtime.session_limit)|$(state exa-i3)"
inst_runtime
check "...run again: nothing" "" "$(calls 'st(op|art)')"
# Owner user, through the installer.
reset_home
seed "$OLDROOT/default" exa-i4 8563 running
user030 "$OLDROOT/default" "$THEIRS" 2.4.0
inst_launcher
check "owner user: their launcher as it was, the kit's own recorded, the database renamed and theirs" "$(sha "$WORK/exasol-2.4.0")|kit|yes|user|running" \
    "$(sha "$THEIRS")|$(manifest_get components.personal.ownership)|$(yn test -d "$NEW")|$(manifest_get runtime.ownership)|$(state exa-i4)"
check "...the kit installs none on PATH" no "$(yn test -e "$EXAKIT_BIN_DIR/exasol")"
reset_home
seed "$OLDROOT/default" exa-i5 8563 running
user030 "$OLDROOT/default" "$THEIRS" 2.4.0
I5_SHA="$(sha "$THEIRS")"
( exakit_core_rerun_active() { return 0; }; inst_launcher )
check "an installer exakit update started: the update decided it, nothing here" "$I5_SHA|yes" \
    "$(sha "$THEIRS")|$(yn test -d "$OLDROOT/default")"

echo "the real status, in a shell whose PATH does not name ~/.local/bin:"
# The suite's personal_status is a stand-in. Here the kit's own decides, over
# the stub launcher's state, and the launcher is found only through the records
# (a bare shell, cron, an agent: ~/.local/bin/exakit by its path).
STUB_STATUS="$(declare -f personal_status)"
STUB_FRESH="$(declare -f fresh)"
STUB_PATH="$PATH"
eval "$(sed -n '/^personal_status() {$/,/^}$/p' "$ROOT/setup/lib/runtime-personal.sh")"
port_in_use() { grep -q running "$STUB_STATE"/* 2>/dev/null; }
personal_db_answers() { grep -q running "$STUB_STATE"/* 2>/dev/null; }
personal_starting() { return 1; }
personal_deployment_wedged() { return 1; }
eval "real_$STUB_FRESH"
fresh() { real_fresh; unset PERSONAL_LEGACY_RECEIPT; }
no_receipts() {
    for _nr in components.personal.ownership components.personal.ownership_path components.personal.ownership_sha256 \
        runtime.ownership runtime.ownership_path; do manifest_del "$_nr"; done
}
for _case in "off PATH" "on PATH, no receipts" "off PATH, no receipts"; do
    reset_home
    seed "$OLDROOT/default" exa-rs 8563 running
    kit030 "$OLDROOT/default" 2.4.0
    case "$_case" in *"no receipts"*) no_receipts ;; esac
    case "$_case" in off*) PATH="$WORK/userbin:$_path" ;; esac
    hash -r
    check "$_case: found, and said to run" "$EXAKIT_BIN_DIR/exasol|running" "$(fresh; personal_cli)|$(fresh; personal_status)"
    upd
    check "$_case: stopped by the old launcher on the 0.3.0 folder, before the rename" "2.4.0 stop --deployment-dir $OLDROOT/default" "$(calls stop)"
    check "$_case: updated, renamed, running, the limit lifted" "0|personal|updated|yes|running|no" \
        "$UPD_RC|$(row)|$(yn test -d "$NEW")|$(state exa-rs)|$(yn grep -q maxConnectionsLicenseLimit "$NEW/$CONF_REL")"
    check "$_case: the launcher and the database are still the kit's" "kit kit" \
        "$(fresh; exakit_component_ownership personal) $(fresh; exakit_component_ownership database)"
    case "$_case" in
        *"no receipts"*) check "$_case: an old launcher the kit cannot prove is left" yes "$(yn test -e "$EXAKIT_BIN_DIR/exasol")" ;;
        *) check "$_case: the old launcher is retired" no "$(yn test -e "$EXAKIT_BIN_DIR/exasol")" ;;
    esac
    PATH="$STUB_PATH"; hash -r
done
reset_home
seed "$OLDROOT/default" exa-rs 8563 running
user030 "$OLDROOT/default" "$EXAKIT_BIN_DIR/exasol" 2.4.0
PATH="$WORK/userbin:$_path"; hash -r
upd
check "owner user, their 2.4 off PATH: stopped with it, then updated" "2.4.0 stop --deployment-dir $OLDROOT/default|personal|updated|running" \
    "$(calls stop)|$(row)|$(state exa-rs)"
PATH="$STUB_PATH"; hash -r
# Anything but the launcher's own "stopped" is not touched.
for _word in "" operation_in_progress database_connection_failed interrupted; do
    reset_home
    seed "$OLDROOT/default" exa-uk 8563
    kit030 "$OLDROOT/default" 2.4.0
    sed -i.bak -e "s/s=stopped ;; esac\$/s=$_word ;; esac/" "$EXAKIT_BIN_DIR/exasol" && rm -f "$EXAKIT_BIN_DIR/exasol.bak"
    exakit_record_ownership personal kit "$EXAKIT_BIN_DIR/exasol"
    upd
    check "a state of '$_word': not renamed, nothing installed" "yes|no|no|personal|deferred" \
        "$(yn test -d "$OLDROOT/default")|$(yn test -e "$OLD")|$(yn test -e "$EXAKIT_PERSONAL_KIT_BIN")|$(row)"
    has "...said as it was said" "WARN The database did not stop, so it was not updated. Nothing was changed." "$(said)"
done
eval "$STUB_STATUS"
eval "$STUB_FRESH"

echo "a deliberate no holds back the private move and the rename on a 2.5 launcher:"
for _how in "EXAKIT_CONFIRM_RUNTIME_UPDATE=0" "--json"; do
    for _arm in private current limit; do
        reset_home; rm -rf "$PRIV"
        if [ "$_arm" = private ]; then
            _no_dir="$OLDROOT/default"; seed "$_no_dir" exa-no 8563 running
            mixed030 "$_no_dir" "$THEIRS" 2.4.0
        elif [ "$_arm" = current ]; then
            _no_dir="$NEWROOT/default"; seed "$_no_dir" exa-no 8563 running
            kit030 "$_no_dir" 2.5.0
        else
            # Named already, only the 20-session limit to remove.
            _no_dir="$NEW"; seed "$_no_dir" exa-no 8563 running
            kit030 "$_no_dir" 2.5.0 exa-no
        fi
        if [ "$_how" = --json ]; then upd --json; else EXAKIT_CONFIRM_RUNTIME_UPDATE=0; export EXAKIT_CONFIRM_RUNTIME_UPDATE; upd; fi
        unset EXAKIT_CONFIRM_RUNTIME_UPDATE EXAKIT_UPDATE_JSON
        check "$_how, $_arm: not stopped, not moved" "yes||no|running" \
            "$(yn test -d "$_no_dir")|$(calls 'st(op|art)')|$(yn test -e "$PRIV/libexec")|$(state exa-no)"
        # --json answers on stdout, with rows of its own.
        if [ "$_how" = --json ]; then has "$_how, $_arm: the row waits for --yes" '"remedy": "exakit update --yes"' "$(cat "$SAID")"
        else check "$_how, $_arm: the row waits for --yes" "personal|deferred|exakit update --yes" "$(row 1-2,5)"; fi
    done
done

# The installer's runtime step after a held-back rename: no restart either.
reset_home
seed "$NEWROOT/default" exa-nr 8563 running
kit030 "$NEWROOT/default" 2.5.0 exa-nr
EXAKIT_CONFIRM_RUNTIME_UPDATE=0; export EXAKIT_CONFIRM_RUNTIME_UPDATE
inst_runtime
unset EXAKIT_CONFIRM_RUNTIME_UPDATE
check "the installer's runtime step with a no: not stopped, not renamed, the limit as it was" "|yes|yes|running" \
    "$(calls 'st(op|art)')|$(yn test -d "$NEWROOT/default")|$(yn grep -q maxConnectionsLicenseLimit "$NEWROOT/default/$CONF_REL")|$(state exa-nr)"

echo "Q15: the move is one step, or nothing:"
reset_home; rm -rf "$PRIV"
seed "$OLDROOT/default" exa-dev 8563 running
mixed030 "$OLDROOT/default" "$THEIRS" 2.4.0
eval "keep_$(declare -f _personal_path_device)"
_personal_path_device() { case "$1" in "$PRIV"*) echo 2 ;; *) echo 1 ;; esac; }
upd personal
eval "$(declare -f keep__personal_path_device | sed '1s/keep_//')"
check "two filesystems: refused before the stop, nothing moved or installed" "personal|deferred|yes||no|running" \
    "$(row)|$(yn test -d "$OLDROOT/default")|$(calls 'st(op|art)')|$(yn test -e "$PRIV")|$(state exa-dev)"
has "...said" "WARN Exasol Personal was not updated to 2.5.0, because its folder could not be moved. The launcher and the database are as they were." "$(said)"
# A put-back that cannot move the folder: the database is kept where it is,
# recorded there, and nothing is deleted.
reset_home; rm -rf "$PRIV"
seed "$OLDROOT/default" exa-pb 8563
mixed030 "$OLDROOT/default" "$THEIRS" 2.4.0
DOWNLOAD="$WORK/exasol-2.5.0-broken"; PIN="$(sha "$WORK/exasol-2.5.0-broken")"
eval "keep_$(declare -f _personal_move_folder)"
_personal_move_folder() { case "$2" in "$PRIV"*) keep__personal_move_folder "$@" ;; *) return 1 ;; esac; }
upd personal
PIN="$(sha "$WORK/exasol-2.5.0")"; DOWNLOAD="$WORK/exasol-2.5.0"
_pb="$(find "$PRIV" -name data.bin 2>/dev/null | head -1)"
check "a put-back that cannot move it back: the tables are there, and the record names the folder" "tables of exa-pb|${_pb%/local/runtime/exa/data.bin}|kit" \
    "$(cat "$_pb" 2>/dev/null)|$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.ownership)"
hasnt "...never said to be as it was" "are as they were" "$(said)"
# Killed in the move: the next command finds the database.
for _at in installed moved; do
    reset_home; rm -rf "$PRIV"
    seed "$OLDROOT/default" exa-kl 8563
    mixed030 "$OLDROOT/default" "$THEIRS" 2.4.0
    _personal_move_folder() { [ "$_at" = moved ] && keep__personal_move_folder "$@"; kill -9 "$(exec sh -c 'echo $PPID')"; }
    eval "keep_$(declare -f _personal_private_move_begin)"
    _personal_private_move_begin() { keep__personal_private_move_begin "$@" && manifest_set runtime.private_move_pid 999999; }
    upd personal >/dev/null 2>&1
    eval "$(declare -f keep__personal_private_move_begin | sed '1s/keep_//')"
    eval "$(declare -f keep__personal_move_folder | sed '1s/keep_//')"
    check "killed ($_at): the private launcher is there, the move unfinished" "yes|$OLDROOT/default" \
        "$(yn test -x "$PRIV/libexec/exasol")|$(manifest_get runtime.private_move_from)"
    check "killed ($_at): the next process has the database back, the kit's, on their 2.4" "$OLDROOT/default|kit|$THEIRS||tables of exa-kl" \
        "$(fresh; personal_private_move_recover; personal_deploy_dir_refresh; printf '%s|%s|%s|%s|%s' "$EXAKIT_PERSONAL_DEPLOY_DIR" "$(exakit_component_ownership database)" "$(personal_cli)" "$(exakit_personal_db_state)" "$(cat "$OLDROOT/default/local/runtime/exa/data.bin")")"
    check "killed ($_at): no private home left, no note left" "no|" "$(yn test -e "$PRIV")|$(manifest_get runtime.private_move_from)"
    upd personal
    check "killed ($_at): the next update goes through" "personal|updated|running" "$(row)|$(state exa-kl)"
done
# A move whose process is alive is left alone.
reset_home; rm -rf "$PRIV"
seed "$OLDROOT/default" exa-al 8563
mixed030 "$OLDROOT/default" "$THEIRS" 2.4.0
_personal_private_move_begin "$OLDROOT/default" exa-al "$THEIRS"
sleep 600 & _mover=$!
manifest_set runtime.private_move_pid "$_mover"; manifest_set runtime.private_move_started "$(exakit_process_start_time "$_mover")"
check "a move in progress is not taken back" "$OLDROOT/default" "$(personal_private_move_recover; manifest_get runtime.private_move_from)"
kill "$_mover" 2>/dev/null; wait "$_mover" 2>/dev/null

echo "Q15: a move that was not finished, or not struck out, is never taken back from under a database:"
# read_only: another exakit process that only reads, as `exakit status` loads
# the libraries: nothing may move or go by it.
read_only() {
    bash -c '. "$1/setup/lib/common.sh"; . "$1/setup/lib/detect.sh"; . "$1/setup/lib/runtime-personal.sh"
             personal_deploy_dir_refresh; personal_status' _ "$ROOT" >/dev/null 2>&1 </dev/null
}
# The move's note cannot be struck out (the kit home not writable at that one
# moment): the record names the new place, so the update stands, and nothing
# a later command runs takes the running database's folder or launcher away.
reset_home; rm -rf "$PRIV"
seed "$OLDROOT/default" exa-ns 8563 running
seed "$OLDROOT/demo" exa-demo2 8564
mixed030 "$OLDROOT/default" "$THEIRS" 2.4.0
eval "keep_$(declare -f manifest_del)"
manifest_del() { case "$1" in runtime.private_move_*) return 0 ;; esac; keep_manifest_del "$@"; }
upd personal
eval "$(declare -f keep_manifest_del | sed '1s/keep_//')"
check "the note stays: updated, running in the private home" "personal|updated|running|yes|$OLDROOT/default" \
    "$(row)|$(state exa-ns)|$(yn test -d "$PRIVNEW/$NAME")|$(manifest_get runtime.private_move_from)"
manifest_set runtime.private_move_pid 999999     # that update is over
read_only
check "...a read moves and deletes nothing" "yes|no|yes|yes" \
    "$(yn test -d "$PRIVNEW/$NAME")|$(yn test -e "$OLDROOT/default")|$(yn test -x "$PRIV/libexec/exasol")|$(yn test -x "$PRIV/bin/exasol")"
upd
check "...the next update strikes it out, and nothing else" "personal|current|running|yes|" \
    "$(row)|$(state exa-ns)|$(yn test -d "$PRIVNEW/$NAME")|$(manifest_get runtime.private_move_from)$(calls 'st(op|art)')"
# unfinished <id> <state>: the note of a dead update, the folder already moved
# and taken over by the kit's 2.5, the records still the old ones.
unfinished() {
    reset_home; rm -rf "$PRIV"
    seed "$OLDROOT/default" "$1" 8563
    mixed030 "$OLDROOT/default" "$THEIRS" 2.4.0
    ( fresh; _personal_private_move_begin "$OLDROOT/default" "$1" "$THEIRS"
      manifest_set runtime.private_move_pid 999999
      personal_use_mode P; EXAKIT_PERSONAL_VERSION=2.5.0; EXAKIT_FORCE_COMPONENT_INSTALL=1; personal_install_launcher ) >/dev/null 2>&1
    mkdir -p "$PRIVNEW"; mv "$OLDROOT/default" "$PRIVNEW/default"
    echo "$2" > "$STUB_STATE/$1"
}
unfinished exa-rd stopped
read_only
check "unfinished, stopped: a read changes nothing" "yes|$OLDROOT/default|$OLDROOT/default" \
    "$(yn test -d "$PRIVNEW/default")|$(manifest_get runtime.private_move_from)|$(manifest_get runtime.deployment_dir)"
# ANOTHER PROCESS HAS THE DEAD UPDATE'S PID (handed out again after a restart):
# the start time tells them apart.
unfinished exa-rp stopped
sleep 600 & _reused=$!
manifest_set runtime.private_move_pid "$_reused"
( fresh; personal_private_move_recover )
check "unfinished, its pid another process's now: taken back" "yes|no||$OLDROOT/default" \
    "$(yn test -d "$OLDROOT/default")|$(yn test -e "$PRIV")|$(manifest_get runtime.private_move_from)|$(manifest_get runtime.deployment_dir)"
kill "$_reused" 2>/dev/null; wait "$_reused" 2>/dev/null
unfinished exa-rn running
( fresh; personal_private_move_recover )
check "unfinished, and it runs: never moved, recorded where it runs, under the kit's launcher" "yes|no|$PRIVNEW/default|kit|kit|yes|" \
    "$(yn test -d "$PRIVNEW/default")|$(yn test -e "$OLDROOT/default")|$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.ownership)|$(manifest_get components.personal.ownership)|$(yn test -x "$PRIV/libexec/exasol")|$(manifest_get runtime.private_move_from)"
upd
check "...and the next update goes through" "personal|updated|running|yes|2.5.0" \
    "$(row)|$(state exa-rn)|$(yn test -d "$PRIVNEW/$NAME")|$(manifest_get runtime.version)"
unfinished exa-ot stopped
seed "$PRIVNEW/other" exa-other 8610
( fresh; personal_private_move_recover )
check "unfinished, another deployment in the private home: kept there with its launcher, nothing moved" "yes|yes|yes|$PRIVNEW/default|" \
    "$(yn test -d "$PRIVNEW/default")|$(yn test -d "$PRIVNEW/other")|$(yn test -x "$PRIV/libexec/exasol")|$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.private_move_from)"
unfinished exa-uk stopped
for _uk in "$PRIV/libexec/exasol" "$THEIRS"; do printf '#!/bin/sh\nexit 1\n' > "$_uk"; done
( fresh; personal_private_move_recover )
check "unfinished, and no launcher says stopped: nothing moved, nothing deleted, the note stays" "yes|no|yes|$OLDROOT/default" \
    "$(yn test -d "$PRIVNEW/default")|$(yn test -e "$OLDROOT/default")|$(yn test -e "$PRIV/libexec/exasol")|$(manifest_get runtime.private_move_from)"
out="$( ( fresh; personal_launcher_mode_decide >/dev/null 2>&1; EXAKIT_REUSE_DB=0 personal_choose_database; printf 'RC=%s\n' "$?" ) 2>&1 )"
has "...and the installer puts no empty database in its place" "RC=1" "$out"
has "...said" "The database did not stop, so it was not updated. Nothing was changed." "$out"
check "...the record still names the database" "$OLDROOT/default" "$(manifest_get runtime.deployment_dir)"
# The version on record is the one before the move again (UP2-06).
unfinished exa-vr stopped
manifest_set runtime.version 2.5.0; manifest_set desired.runtime.personal 2.5.0
( fresh; personal_private_move_recover )
check "taken back late: the record names the version it runs again" "2.4.0||yes" \
    "$(manifest_get runtime.version)|$(manifest_get desired.runtime.personal)|$(yn test -d "$OLDROOT/default")"
# Started by the user while the new launcher downloaded: not moved under it.
reset_home; rm -rf "$PRIV"
seed "$OLDROOT/default" exa-dl 8563 running
mixed030 "$OLDROOT/default" "$THEIRS" 2.4.0
eval "keep_$(declare -f personal_install_launcher)"
personal_install_launcher() { keep_personal_install_launcher "$@"; echo running > "$STUB_STATE/exa-dl"; }
upd personal
eval "$(declare -f keep_personal_install_launcher | sed '1s/keep_//')"
check "started during the download: not moved, not started twice, put back" "personal|deferred|yes|no|running|" \
    "$(row)|$(yn test -d "$OLDROOT/default")|$(yn test -e "$PRIV")|$(state exa-dl)|$(manifest_get runtime.private_move_from)"
check "...started by nobody else" "" "$(calls start)"

echo "a launcher of the user's that moved (UPG-08): run where it is now, and their other 2.4 database stays:"
moved030() { # the kit's own database on the user's 2.4, whose file is elsewhere on PATH now
    reset_home; rm -rf "$PRIV"
    seed "$OLDROOT/default" exa-mv 8563 running
    seed "$OLDROOT/theirs" exa-theirs 8600
    mkdir -p "$WORK/oldplace"
    mixed030 "$OLDROOT/default" "$WORK/oldplace/exasol" 2.4.0
    mv "$WORK/oldplace/exasol" "$WORK/userbin/exasol"
}
moved030
check "found by its name, the database running" "$WORK/userbin/exasol|running" "$( ( fresh; printf '%s|%s' "$(personal_cli)" "$(personal_status)" ) )"
inst_launcher
check "the installer again: moved into the private home, running, their other one where it was" "yes|running|yes|no" \
    "$(yn test -d "$PRIVNEW/$NAME")|$(state exa-mv)|$(yn test -d "$OLDROOT/theirs")|$(yn test -e "$NEWROOT/theirs")"
moved030
upd
check "exakit update: the same, never called current" "personal|updated|yes|running|yes" \
    "$(row)|$(yn test -d "$PRIVNEW/$NAME")|$(state exa-mv)|$(yn test -d "$OLDROOT/theirs")"
moved030
cp "$WORK/exasol-2.5.0" "$WORK/userbin/exasol"
check "a 2.5 of theirs on PATH is never the one" "$EXAKIT_PERSONAL_KIT_BIN" "$( ( fresh; personal_cli ) )"

echo "a launcher of a kit from before receipts is kept, a first update that was put back included (RGR-07):"
reset_home
seed "$OLDROOT/default" exa-lg 8563 running
kit030 "$OLDROOT/default" 2.4.0
for _lg in runtime.ownership runtime.ownership_path runtime.ownership_sha256 components.personal.ownership components.personal.ownership_path components.personal.ownership_sha256; do manifest_del "$_lg"; done
unset PERSONAL_LEGACY_RECEIPT
DOWNLOAD="$WORK/exasol-2.5.0-broken"; PIN="$(sha "$WORK/exasol-2.5.0-broken")"
upd
PIN="$(sha "$WORK/exasol-2.5.0")"; DOWNLOAD="$WORK/exasol-2.5.0"
unset PERSONAL_LEGACY_RECEIPT                    # a new process
upd
check "put back, then updated: the file at the old kit's path is still there" "personal|updated|yes" "$(row)|$(yn test -e "$EXAKIT_BIN_DIR/exasol")"

echo "an id that reads as a number goes through the update, as text:"
for _idc in kit:3e082473 user:3e082473 q15:3e082473 kit:0e123456 user:01234567 q15:30824735; do
    _idw="${_idc%%:*}"; _id="${_idc#*:}"
    reset_home; rm -rf "$PRIV"
    seed "$OLDROOT/default" "$_id" 8563 running
    case "$_idw" in
        kit)  kit030 "$OLDROOT/default" 2.4.0 ;;
        user) user030 "$OLDROOT/default" "$WORK/userbin/exasol" 2.4.0 ;;
        q15)  mixed030 "$OLDROOT/default" "$WORK/userbin/exasol" 2.4.0 ;;
    esac
    upd
    _idd="$NEW"; _ido="$_idw"; [ "$_idw" != q15 ] || { _idd="$PRIVNEW/$NAME"; _ido=kit; }
    check "$_idw, $_id: updated, running, its id as text" "personal|updated|running|$_idd|\"$_id\"|$_ido|" \
        "$(row)|$(state "$_id")|$(manifest_get runtime.deployment_dir)|$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["runtime"]["deployment_id"]))' "$EXAKIT_MANIFEST")|$(manifest_get runtime.ownership)|$(fresh; exakit_personal_db_state)"
    upd
    check "$_idw, $_id: ...and current after it" "personal|current" "$(row)"
done

echo "Q15 with an id that reads as a number, under the kit's real status (U7, live on WSL):"
# The live run said "Leaving personal as it is" for Q15: its record of the id
# was Infinity (written by a build before a18a389e) or the id as text now. The
# real personal_status decides, as on the machine.
Q15_STUB_STATUS="$(declare -f personal_status)"
eval "$(sed -n '/^personal_status() {$/,/^}$/p' "$ROOT/setup/lib/runtime-personal.sh")"
port_in_use() { grep -q running "$STUB_STATE"/* 2>/dev/null; }
personal_db_answers() { grep -q running "$STUB_STATE"/* 2>/dev/null; }
personal_starting() { return 1; }
personal_deployment_wedged() { return 1; }
for _rec in text infinity; do
    reset_home; rm -rf "$PRIV"
    seed "$OLDROOT/default" 3e082473 8563 running
    seed "$OLDROOT/demo" exa-demo 8564
    mixed030 "$OLDROOT/default" "$WORK/userbin/exasol" 2.4.0
    _q15_sha="$(sha "$WORK/userbin/exasol")"
    if [ "$_rec" = text ]; then manifest_set runtime.deployment_id 3e082473
    else python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["runtime"]["deployment_id"]=float("inf"); json.dump(d,open(p,"w"),indent=2)' "$EXAKIT_MANIFEST"; fi
    upd
    hasnt "Q15, id 3e082473 recorded as $_rec: never left as it is" "Leaving personal as it is" "$(said)"
    check "Q15, id 3e082473 recorded as $_rec: updated into the private home, running, the kit's, its id as text" \
        "personal|updated|running|$PRIVNEW/$NAME|kit|3e082473|" \
        "$(row)|$(state 3e082473)|$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.ownership)|$(manifest_get runtime.deployment_id)|$(fresh; exakit_personal_db_state)"
    check "Q15, id 3e082473 recorded as $_rec: their 2.4 and their demo as they were" "$_q15_sha|yes" "$(sha "$WORK/userbin/exasol")|$(yn test -d "$OLDROOT/demo")"
    upd
    check "Q15, id 3e082473 recorded as $_rec: ...and current after it" "personal|current" "$(row)"
done
eval "$Q15_STUB_STATUS"

echo "an update cut short is finished by the next one, never called current:"
# updk: `exakit update` as upd, killed (kill -9) by the case at one point.
killed() { kill -9 "$(cat "$WORK/main.pid")"; kill -9 "$(exec sh -c 'echo $PPID')"; }
updk() {
    eval "keep_$(declare -f exakit_update)"
    exakit_update() { exec sh -c 'echo $PPID' > "$WORK/main.pid" & wait $!; eval "$(declare -f keep_exakit_update | sed '1s/keep_//')"; exakit_update "$@"; }
    upd "$@" 2>/dev/null
    eval "$(declare -f keep_exakit_update | sed '1s/keep_//')"
}
for _who in kit user; do
    for _at in placed receipt; do
        reset_home
        seed "$OLDROOT/default" "exa-cs-$_who" 8563 running
        if [ "$_who" = kit ]; then kit030 "$OLDROOT/default" 2.4.0; else user030 "$OLDROOT/default" "$WORK/userbin/exasol" 2.4.0; fi
        case "$_at" in
            placed)  mv() { command mv "$@" || return 1; case "$*" in *"$EXAKIT_PERSONAL_KIT_BIN") killed ;; esac; } ;;
            receipt) eval "keep_$(declare -f manifest_set)"
                     manifest_set() { keep_manifest_set "$@"; case "$1|$2" in components.personal.ownership\|unknown) killed ;; esac; } ;;
        esac
        updk
        unset -f mv
        [ "$_at" != receipt ] || eval "$(declare -f keep_manifest_set | sed '1s/keep_//')"
        rm -f "$EXAKIT_HOME/.update.lock"
        check "owner $_who, killed at $_at: the launcher is there, the database stopped" "137|yes|stopped" \
            "$UPD_RC|$(yn test -x "$EXAKIT_PERSONAL_KIT_BIN")|$(state "exa-cs-$_who")"
        upd
        check "owner $_who, killed at $_at: the next update finishes it" "personal|updated|running|$PIN|kit|2.5.0|$_who" \
            "$(row)|$(state "exa-cs-$_who")|$(sha "$EXAKIT_PERSONAL_KIT_BIN")|$(manifest_get components.personal.ownership)|$(manifest_get runtime.version)|$(manifest_get runtime.ownership)"
        check "...the kit's own 0.3.0 launcher retired, the user's as it was" "$([ "$_who" = kit ] && echo no || echo yes)" \
            "$(yn test -e "$([ "$_who" = kit ] && echo "$EXAKIT_BIN_DIR/exasol" || echo "$WORK/userbin/exasol")")"
    done
    # Killed at the one start, which can take minutes: the record is written.
    reset_home
    seed "$OLDROOT/default" "exa-st-$_who" 8563 running
    if [ "$_who" = kit ]; then kit030 "$OLDROOT/default" 2.4.0; else user030 "$OLDROOT/default" "$WORK/userbin/exasol" 2.4.0; fi
    eval "keep_$(declare -f personal_start)"
    personal_start() { killed; }
    updk
    eval "$(declare -f keep_personal_start | sed '1s/keep_//')"
    rm -f "$EXAKIT_HOME/.update.lock"
    check "owner $_who, killed at the start: recorded, stopped" "137|2.5.0|stopped" "$UPD_RC|$(manifest_get runtime.version)|$(state "exa-st-$_who")"
    EXAKIT_CONFIRM_RUNTIME_UPDATE=0; export EXAKIT_CONFIRM_RUNTIME_UPDATE
    upd
    unset EXAKIT_CONFIRM_RUNTIME_UPDATE
    check "...a deliberate no does not start it" "personal|deferred|stopped" "$(row)|$(state "exa-st-$_who")"
    upd
    check "owner $_who, killed at the start: the next update starts it" "personal|current|running" "$(row)|$(state "exa-st-$_who")"
    [ "$_who" = user ] || check "...and retires the old launcher" no "$(yn test -e "$EXAKIT_BIN_DIR/exasol")"
    ( fresh; personal_stop ) >/dev/null 2>&1
    upd
    check "...a stop the user asks for after that is kept" "personal|current|stopped" "$(row)|$(state "exa-st-$_who")"
done

echo "EXAKIT_CONFIRM_RUNTIME_UPDATE=0 holds back every way in:"
for _run in running stopped; do
    reset_home
    seed "$OLDROOT/default" exa-no0 8563 "$_run"
    kit030 "$OLDROOT/default" 2.4.0
    EXAKIT_CONFIRM_RUNTIME_UPDATE=0; export EXAKIT_CONFIRM_RUNTIME_UPDATE
    upd personal
    check "exakit update personal, by name, $_run: held back" "0|personal|deferred|exakit update --yes" "$UPD_RC|$(row)|$(row 5)"
    check "...nothing stopped, renamed, replaced or started" "|yes|no|$_run|2.4.0" \
        "$(calls 'st(op|art)')|$(yn test -d "$OLDROOT/default")|$(yn test -e "$EXAKIT_PERSONAL_KIT_BIN")|$(state exa-no0)|$(manifest_get runtime.version)"
    has "...said" "was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)." "$(said)"
    inst_launcher
    unset EXAKIT_CONFIRM_RUNTIME_UPDATE
    check "the installer again, $_run: held back too" "|yes|no|$_run|2.4.0" \
        "$(calls 'st(op|art)')|$(yn test -d "$OLDROOT/default")|$(yn test -e "$EXAKIT_PERSONAL_KIT_BIN")|$(state exa-no0)|$(manifest_get runtime.version)"
done
upd personal
check "...and without it the named update goes through" "2.5.0|running|yes" "$(manifest_get runtime.version)|$(state exa-no0)|$(yn test -d "$NEW")"

echo "what the update says is full sentences, never with a semicolon:"
UPD_SRC="$(awk '/^# --- the update from a 0.3.0 kit/{on=1} /^personal_update\(\) \{/{on=0} on' "$ROOT/setup/lib/runtime-personal.sh")"
check "the update's lines are there" yes "$([ "$(printf '%s\n' "$UPD_SRC" | grep -cE '(warn|info|ok) "')" -gt 10 ] && echo yes)"
check "...none with a semicolon" "" "$(printf '%s\n' "$UPD_SRC" | grep -E '(warn|info|ok) "' | grep ';')"

fi
if [ -n "$_half_pid" ]; then
    wait "$_half_pid"
    cat "$WORK/half2.out"
    if [ -f "$WORK/half2.count" ]; then
        read -r _hp _hf < "$WORK/half2.count"
        PASS=$((PASS + _hp)); FAIL=$((FAIL + _hf))
    else
        check "the second half ran to its end" yes no
    fi
elif [ -n "${RENAME_HALF_RESULT:-}" ]; then
    printf '%s %s\n' "$PASS" "$FAIL" > "$RENAME_HALF_RESULT"
    exit 0
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "personal-update-rename.sh: $PASS passed, 0 failed"
else
    echo "personal-update-rename.sh: $PASS passed, $FAIL failed"
    exit 1
fi
