#!/usr/bin/env bash
# personal-named-deploy.sh - the kit's database is the named deployment
# starter-kit-local, and a user's own Exasol Personal is never taken by
# accident: the folder resolver, the launcher modes (K, U, P) and the mode P
# wrapper, the database port of a new starter-kit-local, the one question for
# a new user with Exasol Personal 2.5 databases (the terminal answer, every
# EXAKIT_REUSE_DB form, no terminal), the rename of a database they pick, with
# its undo, and a starter-kit-local an earlier uninstall kept.
#
#   bash tests/personal-named-deploy.sh
#
# All in a scratch HOME with a stub launcher: no real launcher, database,
# container, port or kit home is touched. Ports in use are a list
# (port_in_use is stubbed), so a database on this machine changes nothing.
# Under `set -o pipefail`, as exakit and the setup scripts run.
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" EXAKIT_HOME="$WORK/home/kit" EXAKIT_BIN_DIR="$WORK/home/bin"
export EXAKIT_VERSION_POLICY=pinned EXAKIT_NO_UPDATE_NOTICE=1 EXAKIT_NO_FANCY=1
export TMPDIR="$WORK/tmp"
unset EXAKIT_PERSONAL_DEPLOY_DIR EXAKIT_PERSONAL_BIN EXAKIT_PERSONAL_MODE EXAKIT_PERSONAL_LAUNCHER_HOME \
    EXAKIT_REUSE_DB EXAKIT_REPLACE_DB XDG_CACHE_HOME XDG_DATA_HOME XDG_CONFIG_HOME DOCKER_CONFIG
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$TMPDIR" "$WORK/userbin"
# The user's own launcher, when a case has one, is in userbin (on PATH). No
# folder of this machine's PATH that holds an `exasol` stays on it: no real
# launcher is ever run.
_path=""
_rest="$PATH:"
while [ -n "$_rest" ]; do
    _d="${_rest%%:*}"; _rest="${_rest#*:}"
    [ -n "$_d" ] && [ ! -e "$_d/exasol" ] || continue
    _path="${_path:+$_path:}$_d"
done
export PATH="$WORK/userbin:$_path"

NAME=starter-kit-local
NEWROOT="$HOME/.exasol/launcher/deployments"
OLDROOT="$HOME/.exasol/personal/deployments"
NEW="$NEWROOT/$NAME"
OLD="$OLDROOT/$NAME"
PRIVATE="$EXAKIT_HOME/personal/home"

# The stub launcher. version: STUB_VERSION. deployments list --json: STUB_LIST
# (unset: the command is unknown, as to 2.4). status --json: STUB_STATUS_<n>
# for the folder named <n> (dashes as underscores), else what STUB_LIST says of
# it, and "stopped" once it was stopped (not with STUB_STOP_LIES: a stop that
# answers 0 and stops nothing). stop and start log, stop
# fails with STUB_STOP_RC. install local --help names --ports and
# --container-engine. Every call is logged in STUB_CALLS.
# A launcher 2.4.0 (write_stub24) answers 2.4.0 whatever STUB_VERSION says,
# and has no `deployments` command.
# STUB_MIGRATE=1: launcher 2.5's own move, before every command: each folder
# of $HOME/.exasol/personal/deployments that does not run (no .stub-running
# in it: start makes one, stop removes it) moves to the same name in
# $HOME/.exasol/launcher/deployments, unless that name is taken there.
write_stub() {
    cat > "$1" <<'STUB'
#!/bin/sh
STUB_BAKED=""
[ -n "${STUB_CALLS:-}" ] && echo "$*" >> "$STUB_CALLS"
dir=""; prev=""
for a in "$@"; do [ "$prev" = "--deployment-dir" ] && dir="$a"; prev="$a"; done
if [ "${STUB_MIGRATE:-0}" = 1 ]; then
    for d in "$HOME/.exasol/personal/deployments"/*; do
        [ -d "$d" ] && [ ! -e "$d/.stub-running" ] || continue
        [ -e "$HOME/.exasol/launcher/deployments/${d##*/}" ] && continue
        mkdir -p "$HOME/.exasol/launcher/deployments" && mv "$d" "$HOME/.exasol/launcher/deployments/${d##*/}" && \
            { [ -z "${STUB_CALLS:-}" ] || echo "MIGRATED ${d##*/}" >> "$STUB_CALLS"; }
    done
fi
case "${1:-}" in
    version|--version) echo "${STUB_BAKED:-${STUB_VERSION:-2.5.0}}" ;;
    deployments)
        [ -z "$STUB_BAKED" ] && [ -n "${STUB_LIST+x}" ] || { echo 'Error: unknown command "deployments" for "exasol"' >&2; exit 1; }
        printf '%s\n' "$STUB_LIST" ;;
    status)
        key="$(basename "$dir" | tr '-' '_')"
        st="$(printf '%s\n' "${STUB_LIST:-}" | tr '{' '\n' | grep -F "\"path\": \"$dir\"" | sed -n 's/.*"status": "\([^"]*\)".*/\1/p' | head -1)"
        [ -n "$st" ] || st=not_initialized
        eval "st=\${STUB_STATUS_$key:-$st}"
        [ ! -e "$dir/.stub-stopped" ] || [ -n "${STUB_STOP_LIES:-}" ] || st=stopped
        printf '{"deploymentDir": "%s", "status": "%s"}\n' "$dir" "$st" ;;
    stop)
        [ "${STUB_STOP_RC:-0}" = 0 ] && [ "${STUB_MIGRATE:-0}" = 1 ] && [ -n "$dir" ] && rm -f "$dir/.stub-running"
        [ "${STUB_STOP_RC:-0}" = 0 ] && [ -d "$dir" ] && : > "$dir/.stub-stopped"
        exit "${STUB_STOP_RC:-0}" ;;
    start)
        [ "${STUB_MIGRATE:-0}" = 1 ] && [ -d "$dir" ] && : > "$dir/.stub-running"
        [ -z "$dir" ] || rm -f "$dir/.stub-stopped"
        exit 0 ;;
    info) [ -n "$dir" ] && [ -d "$dir" ] || exit 1; echo info ;;
    --help) printf 'Available Commands:\n  start       Start\n  stop        Stop\n' ;;
    install)
        if [ "${2:-}" = local ] && [ "${3:-}" = --help ]; then
            printf 'Flags:\n      --container-engine string   engine\n      --ports string   ports\n'
        else
            printf 'Commands:\n  local  Local\n'
        fi ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$1"
}
write_stub24() {
    write_stub "$1"
    sed -i.bak 's/^STUB_BAKED=""$/STUB_BAKED=2.4.0/' "$1" && rm -f "$1.bak"
}
write_stub "$WORK/stub-exasol"

. "$ROOT/setup/lib/common.sh"
. "$ROOT/setup/lib/detect.sh"
. "$ROOT/setup/lib/runtime-personal.sh"
info(){ printf 'INFO %s\n' "$*"; }; ok(){ printf 'OK %s\n' "$*"; }; warn(){ printf 'WARN %s\n' "$*"; }
info_step(){ :; }; ok_step(){ :; }
fetch(){ echo 'Unexpected download' >&2; return 91; }
# Ports in use: a list, never this machine's.
BUSY=""
port_in_use() { case " $BUSY " in *" $1 "*) return 0 ;; esac; return 1; }

PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1))
    else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
has() { case "$3" in *"$2"*) check "$1" yes yes ;; *) check "$1" "has: $2" "$(printf '%s' "$3" | tail -12)" ;; esac; }
hasnt() { case "$3" in *"$2"*) check "$1" "not: $2" "$(printf '%s' "$3" | grep -F -- "$2" | head -3)" ;; *) check "$1" yes yes ;; esac; }

# fresh: a new process on a machine as the case sets it up.
fresh() {
    unset _EXAKIT_PERSONAL_LIST_DECIDED _EXAKIT_PERSONAL_LIST_ASKED _EXAKIT_PERSONAL_DEPLOY_FOLLOWED \
        _EXAKIT_PERSONAL_DEPLOY_ID_SEEN _EXAKIT_PERSONAL_DEPLOY_REC _EXAKIT_PERSONAL_DEPLOY_AT _EXAKIT_PERSONAL_DEPLOY_LOST \
        PERSONAL_PICKED_PORT EXAKIT_PERSONAL_LAUNCHER_HOME
    DETECT_PERSONAL_LAUNCHER_LISTED=0; DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS=""; PERSONAL_LAUNCHER_ROWS=""
    EXAKIT_PERSONAL_MODE=""; EXAKIT_PERSONAL_BIN="$EXAKIT_PERSONAL_KIT_BIN"
    EXAKIT_PERSONAL_DEPLOY_DIR=""
}
reset_home() {
    rm -rf "$HOME/.exasol" "$EXAKIT_HOME/personal" "$EXAKIT_BIN_DIR/exasol" "$WORK/userbin/exasol"
    printf '{}\n' > "$EXAKIT_MANIFEST"
    unset STUB_LIST STUB_MIGRATE
    fresh
}
# seed <dir> <id> <port>: a deployment as the launcher leaves it.
seed() {
    mkdir -p "$1/local/runtime/exa" "$1/infrastructure"
    printf '{"deploymentId": "%s", "connection": {"host": "127.0.0.1", "dbPort": %s, "username": "sys"}}\n' "$2" "$3" > "$1/deployment.json"
    printf '{"deploymentId": "%s"}\n' "$2" > "$1/.exasolLauncherState.json"
    printf 'name: Exasol Local\nbackend: local\nlocal:\n  cpuCount: 2\n  ports: db:%s\n' "$3" > "$1/infrastructure/infrastructure.yaml"
    printf '[DB_PARAMS]\nmaxConnectionsLicenseLimit = 20\nother = 1\n' > "$1/local/runtime/exa/exasol.conf"
}
# list <name> <path> <status> <infra> ...: the launcher's answer.
list() {
    _l="["; _sep=""
    while [ "$#" -ge 4 ]; do
        _l="$_l$_sep{\"name\": \"$1\", \"path\": \"$2\", \"status\": \"$3\", \"infrastructure\": \"$4\", \"installation\": \"local\"}"
        _sep=", "; shift 4
    done
    printf '%s]' "$_l"
}
kit_launcher() { mkdir -p "$(dirname "$EXAKIT_PERSONAL_KIT_BIN")"; cp "$WORK/stub-exasol" "$EXAKIT_PERSONAL_KIT_BIN"; }
user_launcher() { cp "$WORK/stub-exasol" "$WORK/userbin/exasol"; }
record_kit() {
    manifest_set runtime.type personal
    manifest_set runtime.deployment_dir "$1"
    exakit_record_ownership database kit "$1"
    [ -z "${2:-}" ] || manifest_set runtime.deployment_id "$2"
}
# run_step1: Step 1/4 as the installer runs it (personal_install_launcher,
# its downgrade guard and all), the pinned launcher's download stubbed to the
# 2.5 stub. Only in a subshell: it redefines the download helpers there.
run_step1() {
    EXAKIT_PERSONAL_VERSION=2.5.0
    personal_s3_source() { printf 'https://example.test/exasol\n%s' "$(shasum -a 256 "$WORK/stub-exasol" | awk '{print $1}')"; }
    fetch_soft() { cp "$WORK/stub-exasol" "$2"; }
    ensure_path_hint() { :; }
    push_rollback() { :; }
    personal_install_launcher
}
# drive_deploy: the deploy step (personal_deploy_local) as the installer runs
# it, in a subshell, with no container engine to judge (macOS), the health
# wait and the record stubbed, and a terminal that would answer any question:
# every question asked is printed as "ASKED <question>" and answered no. The
# launcher's calls land in STUB_CALLS.
drive_deploy() {
    (
        personal_engine_platform() { return 1; }
        personal_install_podman() { return 0; }
        personal_podman_running() { return 0; }
        personal_wsl_podman_network_ok() { return 0; }
        personal_wait_ready_or_deploy() { return 0; }
        personal_record_manifest() { echo "RECORDED $1"; }
        personal_note_guest_rebuild() { :; }
        personal_stop_runner_of_failed_deployment() { return 0; }
        personal_reap_orphan_daemon() { return 1; }
        push_rollback() { :; }
        confirm() { echo "ASKED $1"; return 1; }
        # An answer given in the environment is taken, as confirm_env takes it.
        confirm_env() { [ "$1" = EXAKIT_REPLACE_DB ] && [ "${EXAKIT_REPLACE_DB:-}" = 1 ] && return 0; echo "ASKED $2"; return 1; }
        _exakit_prompt_tty() { printf 'stdin\n'; }
        personal_deploy_local; printf 'RC=%s\n' "$?"
    ) 2>&1 </dev/null
}
export STUB_CALLS="$WORK/calls"

echo "the resolver: the kit's own name, never a user's deployment by its place:"
reset_home
detect_personal_deploy_resolve ""
check "the constant" "$NAME" "$EXAKIT_PERSONAL_DEPLOYMENT"
check "fresh: the 2.5 root's starter-kit-local" "$NEW" "$DETECT_PERSONAL_DEPLOY_DIR"
seed "$NEWROOT/default" exa-user 8563
kit_launcher
export STUB_LIST="$(list default "$NEWROOT/default" database_ready local)"
personal_deploy_dir_refresh
check "a user's default listed first: not the kit's folder" "$NEW" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "...nor its status" "" "${DETECT_PERSONAL_DEPLOY_STATUS:-}"
check "...nothing is missing on a first install" "" "$(exakit_personal_db_state)"
fresh
personal_deploy_dir_refresh
check "a user's default, no list (2.4): not the kit's folder" "$NEW" "$EXAKIT_PERSONAL_DEPLOY_DIR"
seed "$OLD" exa-kit 8570
fresh
personal_deploy_dir_refresh
check "the kit's own in the legacy root: found there" "$OLD" "$EXAKIT_PERSONAL_DEPLOY_DIR"
seed "$NEW" exa-kit2 8571
check "both roots: the 2.5 one, as the launcher looks" "$NEW" "$(detect_personal_deploy_dir)"
check "a listed folder of another name given: itself" "$NEWROOT/default" "$(detect_personal_deploy_dir "$NEWROOT/default")"
check "a printed listing has no default first" "$NEWROOT/default	database_ready" "$(STUB_LIST="$(list zeta "$NEWROOT/zeta" stopped local default "$NEWROOT/default" database_ready local)" personal_launcher_deployments again | tail -1)"

echo "a recorded folder that is gone is followed by its id, whatever its name:"
reset_home
kit_launcher
seed "$NEW" exa-030 8580                       # a 0.3.0 kit's default, renamed and moved since
record_kit "$OLDROOT/default" exa-030
fresh
personal_deploy_dir_refresh
check "0.3.0 default record: followed to starter-kit-local" "$NEW" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "...the record follows" "$NEW" "$(manifest_get runtime.deployment_dir)"
check "...the receipt follows" "$NEW" "$(manifest_get runtime.ownership_path)"
check "...the name follows" "$NAME" "$(manifest_get runtime.deployment_name)"
check "...still the kit's" kit "$(exakit_component_ownership database)"
reset_home
kit_launcher
seed "$NEWROOT/default" exa-030 8581            # moved by the user's own 2.5, not renamed
record_kit "$OLDROOT/default" exa-030
fresh
personal_deploy_dir_refresh
check "0.3.0 default moved, not renamed: followed by id" "$NEWROOT/default" "$EXAKIT_PERSONAL_DEPLOY_DIR"
reset_home
kit_launcher
seed "$NEWROOT/default" exa-user 8582           # the user's own default, another id
record_kit "$OLDROOT/default"                   # 0.3.0 recorded no id
fresh
personal_deploy_dir_refresh
check "no id, the user's default in its place: the kit's folder stays the recorded one" "$OLDROOT/default" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "...the record is left" "$OLDROOT/default" "$(manifest_get runtime.deployment_dir)"
check "...said missing, the folder found is the same name in the other root" "$OLDROOT/default|$NEWROOT/default" "$(exakit_personal_kit_missing)"
check "...the database state names both" "kit_database_missing|$OLDROOT/default|$NEWROOT/default" "$(exakit_personal_db_state)"
reset_home
kit_launcher
seed "$NEWROOT/dev" exa-dev 8583
record_kit "$NEW" exa-kit                       # the kit's own gone
export STUB_LIST="$(list dev "$NEWROOT/dev" stopped local)"
fresh
personal_deploy_dir_refresh
check "kit's own gone, a user's dev listed: the kit's folder stays its own" "$NEW" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "...said missing, with the deployment listed" "kit_database_missing|$NEW|$NEWROOT/dev" "$(exakit_personal_db_state)"
check "...the guard says so (exit 3)" 3 "$(exakit_kit_database_guard >/dev/null 2>&1; echo $?)"
has "...and the hint says the installer asks which database to use" "the installer asks which database to use" \
    "$(exakit_kit_database_guard 1 2>/dev/null)"
reset_home
record_kit "$NEW" exa-kit
fresh
personal_deploy_dir_refresh
check "kit's own gone, nothing else: no state" "" "$(exakit_personal_db_state)"

echo "the prune and the cache compare the launcher's root and home:"
reset_home
seed "$NEW" exa-kit 8590
record_kit "$NEW" exa-kit
fresh
check "prune: deployments, launcher, .exasol for the 2.5 root" \
    "$NEWROOT $HOME/.exasol/launcher $HOME/.exasol" "$(personal_prunable_state_dirs | tr '\n' ' ' | sed 's/ $//')"
reset_home
seed "$NEWROOT/default" exa-030 8591
record_kit "$NEWROOT/default" exa-030
fresh
check "prune: the same for a 0.3.0 default in the 2.5 root" \
    "$NEWROOT $HOME/.exasol/launcher $HOME/.exasol" "$(personal_prunable_state_dirs | tr '\n' ' ' | sed 's/ $//')"

echo "the launcher modes, decided before Step 1/4:"
decide() {
    ( personal_launcher_mode_decide
      printf 'MODE=%s BIN=%s CLI=%s DIR=%s\n' "$EXAKIT_PERSONAL_MODE" "$EXAKIT_PERSONAL_BIN" "$(personal_cli)" "$EXAKIT_PERSONAL_DEPLOY_DIR" ) 2>&1
}
reset_home
out="$(decide)"
has "K: no launcher, no legacy deployment" "MODE=K BIN=$EXAKIT_PERSONAL_KIT_BIN" "$out"
has "K: the kit's folder in the real home" "DIR=$NEW" "$out"
reset_home
user_launcher
out="$(STUB_VERSION=2.5.3 decide)"
has "U: the user's 2.5.x" "MODE=U" "$out"
has "U: the kit runs its own launcher in the kit folder, never theirs" "CLI=$EXAKIT_PERSONAL_KIT_BIN" "$out"
hasnt "U: no line about it" "INFO" "$out"
reset_home
user_launcher
out="$(STUB_VERSION=2.4.0 decide)"
has "P: next to the user's 2.4" "MODE=P BIN=$EXAKIT_HOME/personal/bin/exasol CLI=$EXAKIT_HOME/personal/bin/exasol" "$out"
has "P: the folder is in the private home" "DIR=$PRIVATE/.exasol/launcher/deployments/$NAME" "$out"
has "P: one line says why" "INFO Exasol Personal 2.4.0 is on this computer. The starter kit uses its own Exasol Personal 2.5.0 in its own folder, so yours is not changed." "$out"
reset_home
user_launcher
out="$(STUB_VERSION=2.6.1 decide)"
has "P: next to a newer line (2.6)" "MODE=P" "$out"
reset_home
write_stub24 "$EXAKIT_BIN_DIR/exasol"             # the user's own 2.4, at the kit's path, no receipt
cp "$EXAKIT_BIN_DIR/exasol" "$WORK/theirs24"
out="$(decide)"
has "P: the user's 2.4 at the kit's own path (no receipt)" "MODE=P" "$out"
# Step 1 in that mode: the kit's own 2.5 goes to its own folder, theirs stays.
( personal_launcher_mode_decide >/dev/null 2>&1; run_step1 >/dev/null 2>&1 )
check "...Step 1 then leaves their launcher there as it was" "$(cat "$WORK/theirs24")" "$(cat "$EXAKIT_BIN_DIR/exasol")"
check "...and puts the kit's own 2.5 in the kit's folder, run by its wrapper" "yes|2.5.0" \
    "$([ -x "$EXAKIT_HOME/personal/libexec/exasol" ] && echo yes)|$("$EXAKIT_HOME/personal/bin/exasol" version 2>/dev/null)"
reset_home
seed "$OLDROOT/old24" exa-old 8563
out="$(decide)"
has "P: no launcher, but a 2.4 deployment of theirs" "MODE=P" "$out"
# An existing install keeps its launcher and its home: a database record of
# the kit's own, or of one the user let the 0.3.0 kit use (owner user, run by
# their 2.4), and a receipt of the kit's own launcher with no database (Step 1
# brings that one to the pin).
reset_home
user_launcher
manifest_set runtime.type personal
manifest_set runtime.deployment_dir "$OLDROOT/default"
exakit_record_ownership database user "$OLDROOT/default"
exakit_record_ownership personal user "$WORK/userbin/exasol"
out="$(STUB_VERSION=2.4.0 decide)"
has "owner user (a database record): an existing install keeps its launcher and home, never P" "MODE= BIN=$EXAKIT_PERSONAL_KIT_BIN" "$out"
reset_home
write_stub24 "$EXAKIT_BIN_DIR/exasol"
exakit_record_ownership personal kit "$EXAKIT_BIN_DIR/exasol"
out="$(decide)"
has "the kit's own launcher, no database: kept, never P" "MODE= BIN=$EXAKIT_PERSONAL_KIT_BIN" "$out"
# A 0.3.0 kit told "No" (no database) kept only the receipt of the user's own
# launcher it found: the installer run again works as for a new user.
no030() {
    manifest_set runtime.launcher "$WORK/userbin/exasol"
    exakit_record_ownership personal user "$WORK/userbin/exasol"
}
reset_home
write_stub24 "$WORK/userbin/exasol"
no030
out="$(decide)"
has "0.3.0 answered No, the user's 2.4: P, the kit's own 2.5 in its own home" "MODE=P BIN=$EXAKIT_HOME/personal/bin/exasol" "$out"
has "...one line says why" "INFO Exasol Personal 2.4.0 is on this computer. The starter kit uses its own Exasol Personal 2.5.0 in its own folder, so yours is not changed." "$out"
reset_home
user_launcher
no030
out="$(STUB_VERSION=2.5.1 decide)"
has "0.3.0 answered No, the user's 2.5: U, their launcher as it is" "MODE=U" "$out"
has "...the kit runs their launcher" "CLI=$WORK/userbin/exasol" "$out"
reset_home
user_launcher
no030
out="$(STUB_VERSION=2.6.0 decide)"
has "0.3.0 answered No, the user's 2.6: P" "MODE=P" "$out"
# Driven: the mode, Step 1 and the deploy step, as the installer runs them.
# Their 2.4 and their default stay theirs, the kit's own 2.5 deploys its own
# starter-kit-local in its own home, and the screen says so (approved line 4).
reset_home
write_stub24 "$WORK/userbin/exasol"
cp "$WORK/userbin/exasol" "$WORK/theirs24"
seed "$OLDROOT/default" exa-theirs 8563
no030
: > "$STUB_CALLS"
( personal_launcher_mode_decide >/dev/null 2>&1; run_step1 >/dev/null 2>&1; drive_deploy ) > "$WORK/no030.out" 2>&1
out="$(cat "$WORK/no030.out")"
check "...the deploy step goes through" 1 "$(grep -c '^RC=0$' "$WORK/no030.out")"
check "...install local by the kit's own 2.5, into its own home, on a port of its own (theirs saved 8563)" 1 \
    "$(grep -c "^install local --ports db:8564 --deployment-dir $PRIVATE/.exasol/launcher/deployments/$NAME\$" "$STUB_CALLS")"
has "...approved line 4" "INFO Deploying the starter kit's own database '$NAME'. Your Exasol Personal is not changed." "$out"
check "...their 2.4 as it was, their default where it was" "$(cat "$WORK/theirs24")|yes" \
    "$(cat "$WORK/userbin/exasol")|$([ -d "$OLDROOT/default" ] && echo yes)"
check "...the kit's launcher receipt is its own wrapper now" "kit|$EXAKIT_HOME/personal/bin/exasol" \
    "$(manifest_get components.personal.ownership)|$(manifest_get components.personal.ownership_path)"
hasnt "...no question asked" "ASKED" "$out"
# A 0.3.0 kit told "No" to a STOPPED database of theirs had already written
# that database's receipt (runtime.ownership user, its folder) before its
# "Start the existing database and keep its data?", and never runtime.type or
# runtime.deployment_dir. A receipt alone is no database record either.
stopped030() {
    exakit_record_ownership database user "$OLDROOT/default"
    no030
}
reset_home
write_stub24 "$WORK/userbin/exasol"
cp "$WORK/userbin/exasol" "$WORK/theirs24"
seed "$OLDROOT/default" exa-theirs 8563
stopped030
out="$(decide)"
has "0.3.0 No to a stopped database of theirs, their 2.4: P" "MODE=P BIN=$EXAKIT_HOME/personal/bin/exasol" "$out"
: > "$STUB_CALLS"
( personal_launcher_mode_decide >/dev/null 2>&1; run_step1 >/dev/null 2>&1; drive_deploy ) > "$WORK/stopped030.out" 2>&1
out="$(cat "$WORK/stopped030.out")"
check "...driven: the kit's own 2.5 deploys in its own home" "1|1" \
    "$(grep -c '^RC=0$' "$WORK/stopped030.out")|$(grep -c "^install local --ports db:8564 --deployment-dir $PRIVATE/.exasol/launcher/deployments/$NAME\$" "$STUB_CALLS")"
check "...their 2.4 and their default untouched, never started or stopped" "$(cat "$WORK/theirs24")|yes|0" \
    "$(cat "$WORK/userbin/exasol")|$([ -d "$OLDROOT/default" ] && echo yes)|$(grep -cE '^(start|stop) .*default' "$STUB_CALLS")"
hasnt "...nothing asked" "ASKED" "$out"
# A TICK LEFT BY A 0.3.0 RUN THAT USED THEIR LAUNCHER (found live, round 4
# R4c): a 0.3.0 kit answered No ticked Step 1 with the user's launcher on
# PATH. In mode P that tick is not the kit's launcher, so Step 1 runs and
# installs the kit's own 2.5 behind its wrapper. With the tick kept, Step 1
# was skipped and the deploy ran a wrapper that was never installed. Every
# other mode keeps its tick as before.
tick_step1() {   # the mode, the launcher step's artifact state, and whether Step 1 runs
    ( personal_launcher_mode_decide >/dev/null 2>&1
      printf 'MODE=%s STATE=%s\n' "$EXAKIT_PERSONAL_MODE" "$(step_artifact_state launcher)"
      if begin_step launcher "Step 1/4  Exasol launcher" >/dev/null 2>&1; then echo STEP1=runs; else echo STEP1=skipped; fi ) 2>&1
}
reset_home                                       # the running case: no database receipt
write_stub24 "$WORK/userbin/exasol"
cp "$WORK/userbin/exasol" "$WORK/theirs24"
no030
mark_step launcher >/dev/null 2>&1
out="$(tick_step1)"
has "0.3.0 No (running case), Step 1 ticked by that run, their 2.4: P, the kit's own launcher missing" "MODE=P STATE=missing" "$out"
has "...so Step 1 runs" "STEP1=runs" "$out"
said_step1() { ( personal_launcher_mode_decide >/dev/null 2>&1; begin_step launcher "Step 1/4  Exasol launcher" 2>&1 ) 2>&1; }
hasnt "Q27: ...and the 'Recorded as done' line is not said for that tick" "Recorded as done" "$(said_step1)"
( personal_launcher_mode_decide >/dev/null 2>&1
  if begin_step launcher "Step 1/4  Exasol launcher" >/dev/null 2>&1; then run_step1 >/dev/null 2>&1; mark_step launcher >/dev/null 2>&1; fi )
check "...and installs the kit's own 2.5 behind its wrapper, in its own home" "yes|2.5.0" \
    "$([ -x "$EXAKIT_HOME/personal/libexec/exasol" ] && echo yes)|$("$EXAKIT_HOME/personal/bin/exasol" version 2>/dev/null)"
check "...their 2.4 as it was" "$(cat "$WORK/theirs24")" "$(cat "$WORK/userbin/exasol")"
reset_home                                       # the stopped case: the database receipt 0.3.0 wrote first
write_stub24 "$WORK/userbin/exasol"
stopped030
mark_step launcher >/dev/null 2>&1
out="$(tick_step1)"
has "0.3.0 No (stopped case), Step 1 ticked, their 2.4: P, the kit's own launcher missing" "MODE=P STATE=missing" "$out"
has "...so Step 1 runs" "STEP1=runs" "$out"
reset_home                                       # a newer line is mode P too
user_launcher
no030
mark_step launcher >/dev/null 2>&1
out="$(STUB_VERSION=2.6.0 tick_step1)"
has "0.3.0 No, Step 1 ticked, their 2.6: P, the kit's own launcher missing" "MODE=P STATE=missing" "$out"
has "...so Step 1 runs" "STEP1=runs" "$out"
reset_home                                       # their 2.5: U, their launcher is the one the kit runs
user_launcher
no030
mark_step launcher >/dev/null 2>&1
out="$(STUB_VERSION=2.5.1 tick_step1)"
has "0.3.0 No, Step 1 ticked, their 2.5 (U): the kit's own launcher missing" "MODE=U STATE=missing" "$out"
has "...so Step 1 runs" "STEP1=runs" "$out"
hasnt "Q27: ...and the 'Recorded as done' line is not said for that tick" "Recorded as done" "$(STUB_VERSION=2.5.1 said_step1)"
check "...and then the kit runs its own, never theirs" "$EXAKIT_PERSONAL_KIT_BIN|yes" \
    "$( ( STUB_VERSION=2.5.1; export STUB_VERSION; personal_launcher_mode_decide >/dev/null 2>&1; unset STUB_VERSION; run_step1 >/dev/null 2>&1; personal_cli ) )|$([ -x "$EXAKIT_PERSONAL_KIT_BIN" ] && echo yes)"
reset_home                                       # K: no launcher anywhere, a tick only
mark_step launcher >/dev/null 2>&1
out="$(tick_step1)"
has "...K with a tick and no launcher: missing, Step 1 runs (as before)" "MODE=K STATE=missing" "$out"
has "...Step 1 runs" "STEP1=runs" "$out"
has "Q27: ...K still says 'Recorded as done' (its own launcher went missing)" "Recorded as done" "$(said_step1)"
reset_home                                       # owner user: a database record, their launcher
user_launcher
manifest_set runtime.type personal
manifest_set runtime.deployment_dir "$OLDROOT/default"
exakit_record_ownership database user "$OLDROOT/default"
exakit_record_ownership personal user "$WORK/userbin/exasol"
mark_step launcher >/dev/null 2>&1
out="$(tick_step1)"
has "...owner user (a database record): no mode, their launcher on PATH counts" "MODE= STATE=present" "$out"
reset_home                                       # owner kit: its own launcher and database recorded
kit_launcher
exakit_record_ownership personal kit "$EXAKIT_PERSONAL_KIT_BIN"
record_kit "$NEW"
mark_step launcher >/dev/null 2>&1
out="$(tick_step1)"
has "...owner kit: no mode, its own launcher present" "MODE= STATE=present" "$out"
has "...Step 1 stays done" "STEP1=skipped" "$out"
reset_home
user_launcher
seed "$NEWROOT/default" exa-theirs 8563          # their own 2.5 moved it since
stopped030
export STUB_LIST="$(list default "$NEWROOT/default" stopped local)"
out="$( ( STUB_VERSION=2.5.2; export STUB_VERSION
          personal_launcher_mode_decide >/dev/null 2>&1
          _exakit_prompt_tty() { :; }
          personal_choose_database; _rc=$?
          printf 'MODE=%s RC=%s NEXT=%s\n' "$EXAKIT_PERSONAL_MODE" "$_rc" "$PERSONAL_DB_NEW_NEXT_TO_THEIRS" ) 2>&1 )"
has "...their 2.5: U, and the one question lists their database" "INFO Exasol Personal 2.5 is on this computer, with 1 database of yours." "$out"
has "...no terminal: a new one (D1), mode U" "MODE=U RC=0 NEXT=1" "$out"
unset STUB_LIST
reset_home
user_launcher
stopped030
out="$(STUB_VERSION=2.6.0 decide)"
has "...their 2.6: P" "MODE=P" "$out"
reset_home
user_launcher
manifest_set runtime.deployment_id exa-only
exakit_record_ownership personal user "$WORK/userbin/exasol"
out="$(STUB_VERSION=2.4.0 decide)"
has "a recorded deployment id alone is a database record: an existing install, never P" "MODE= BIN=$EXAKIT_PERSONAL_KIT_BIN" "$out"
reset_home
mkdir -p "$EXAKIT_HOME/personal/bin" "$EXAKIT_HOME/personal/libexec"; write_stub "$EXAKIT_HOME/personal/bin/exasol"
write_stub "$EXAKIT_HOME/personal/libexec/exasol"
out="$(decide)"
has "an existing mode P install: P from the binary behind its wrapper" "MODE=P" "$out"
reset_home
kit_launcher
out="$(decide)"
hasnt "the kit's own launcher in the kit folder (mode K) is not mode P" "MODE=P" "$out"

echo "mode P is never forgotten in a home whose path JSON escapes:"
for _hn in "José" "a\"b" 'c\d' "O'Brien"; do
    _hk="$WORK/esc/$_hn/kit"; rm -rf "$WORK/esc"; mkdir -p "$_hk"
    out="$( EXAKIT_HOME="$_hk"; EXAKIT_MANIFEST="$_hk/manifest.json"; export EXAKIT_HOME EXAKIT_MANIFEST
            printf '{}\n' > "$EXAKIT_MANIFEST"
            manifest_set runtime.launcher_home "$_hk/personal/home" >/dev/null 2>&1
            detect_personal_private_mode && printf 'P '
            # ... with no JSON reader (the preflight sources detect.sh alone)
            ( unset -f manifest_get; detect_personal_private_mode ) && printf 'P '
            manifest_set runtime.launcher_home "$WORK/another/home" >/dev/null 2>&1
            detect_personal_private_mode || printf 'not' )"
    case "$_hn" in 'a"b') check "$_hn: mode P by the JSON reader" "P" "${out%% *}" ;;
                   *) check "$_hn: mode P, and only for its own home" "P P not" "$out" ;; esac
done
reset_home
EXAKIT_PERSONAL_MODE=P
mkdir -p "$EXAKIT_HOME/personal/bin"; write_stub "$EXAKIT_HOME/personal/bin/exasol"
seed "$OLDROOT/mydb" exa-mydb 8563
: > "$STUB_CALLS"
( STUB_MIGRATE=1; export STUB_MIGRATE; personal_use_mode P; personal_launcher_deployments ) >/dev/null 2>&1
check "mode P, a bare launcher in the wrapper's place: never asked, the user's 2.4 database not moved" "|yes" \
    "$(cat "$STUB_CALLS")|$([ -d "$OLDROOT/mydb" ] && echo yes)"
fresh

echo "mode P is never forgotten (one marker: the binary in libexec, or the private home on record):"
mode_p_install() {
    reset_home
    user_launcher; seed "$OLDROOT/mydb" exa-mydb 8563
    ( export STUB_VERSION=2.4.0; personal_launcher_mode_decide; unset STUB_VERSION; run_step1 ) >/dev/null 2>&1
    fresh
}
for _lost in "libexec" "the whole folder"; do
    mode_p_install
    check "$_lost gone: the private home is on record from Step 1" "$PRIVATE" "$(manifest_get runtime.launcher_home)"
    case "$_lost" in libexec) rm -f "$EXAKIT_HOME/personal/libexec/exasol" ;; *) rm -rf "$EXAKIT_HOME/personal" ;; esac
    fresh
    check "$_lost gone: Step 1 is not done" missing "$(EXAKIT_PERSONAL_MODE=P; step_artifact_state launcher)"
    out="$(STUB_VERSION=2.4.0 decide)"
    has "$_lost gone: still mode P" "MODE=P" "$out"
    : > "$STUB_CALLS"
    ( export STUB_MIGRATE=1; personal_use_mode P; run_step1 ) >/dev/null 2>&1
    check "$_lost gone: installed again in the private home, the user's 2.4 databases not moved" "yes|yes|0" \
        "$([ -x "$EXAKIT_HOME/personal/libexec/exasol" ] && echo yes)|$([ -d "$OLDROOT/mydb" ] && echo yes)|$(grep -c 'MIGRATED mydb' "$STUB_CALLS")"
    check "$_lost gone: the kit's receipt, the wrapper runs" "kit|$EXAKIT_HOME/personal/bin/exasol|yes" \
        "$(manifest_get components.personal.ownership)|$(manifest_get components.personal.ownership_path)|$(personal_wrapper_runs && echo yes)"
done
# A launcher in the kit folder with no receipt is the kit's by its place.
reset_home
kit_launcher
printf '# left\n' >> "$EXAKIT_PERSONAL_KIT_BIN"
run_step1 >/dev/null 2>&1
check "a kit-folder launcher with no receipt: installed over, recorded as the kit's" "kit|0" \
    "$(manifest_get components.personal.ownership)|$(grep -c '^# left' "$EXAKIT_PERSONAL_KIT_BIN")"

echo "the mode P wrapper:"
reset_home
EXAKIT_PERSONAL_MODE=P
personal_write_wrapper
W="$EXAKIT_HOME/personal/bin/exasol"
check "written and executable" yes "$([ -x "$W" ] && echo yes || echo no)"
check "POSIX sh" yes "$(sh -n "$W" && echo yes || echo no)"
check "starts with #!/bin/sh" "#!/bin/sh" "$(head -1 "$W")"
has "runs the kit's binary with the private home" "HOME='$PRIVATE' exec '$EXAKIT_HOME/personal/libexec/exasol' \"\$@\"" "$(cat "$W")"
mkdir -p "$EXAKIT_HOME/personal/libexec"
cat > "$EXAKIT_HOME/personal/libexec/exasol" <<'ECHO'
#!/bin/sh
printf 'HOME=%s\nDATA=%s\nCONFIG=%s\nDOCKER=%s\nCACHE=%s\nARGS=%s\n' "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$DOCKER_CONFIG" "${XDG_CACHE_HOME-unset}" "$*"
ECHO
chmod +x "$EXAKIT_HOME/personal/libexec/exasol"
out="$("$W" status --json)"
has "the launcher sees the private home" "HOME=$PRIVATE" "$out"
has "...the user's Podman storage" "DATA=$HOME/.local/share" "$out"
has "...config" "CONFIG=$HOME/.config" "$out"
has "...and Docker contexts" "DOCKER=$HOME/.docker" "$out"
has "...and every argument" "ARGS=status --json" "$out"
check "...its own cache in the private home" "CACHE=$PRIVATE/.cache" "$(printf '%s\n' "$out" | grep '^CACHE=')"
out="$(XDG_DATA_HOME=/mine XDG_CACHE_HOME="$HOME/.cache-mine" "$W")"
has "a value of the user's is kept" "DATA=/mine" "$out"
check "...but never their cache: the launcher's own is private" "CACHE=$PRIVATE/.cache" "$(printf '%s\n' "$out" | grep '^CACHE=')"
# The kit's cache folder (what the uninstall removes) is the one the wrapper
# gives the launcher, never the user's XDG_CACHE_HOME (Linux: uname stubbed).
check "the cache the kit removes, mode P on Linux: the private one" "$PRIVATE/.cache/exasol/launcher/resources" \
    "$( uname() { echo Linux; }; EXAKIT_PERSONAL_LAUNCHER_HOME="$PRIVATE" XDG_CACHE_HOME="$HOME/.cache-mine" personal_launcher_cache_dir )"
check "...mode K or U on Linux: the user's XDG_CACHE_HOME, as their own launcher uses it" "$HOME/.cache-mine/exasol/launcher/resources" \
    "$( uname() { echo Linux; }; EXAKIT_HOME="$WORK/no-wrapper" EXAKIT_PERSONAL_LAUNCHER_HOME="" XDG_CACHE_HOME="$HOME/.cache-mine" personal_launcher_cache_dir )"
check "the private home exists" yes "$([ -d "$PRIVATE" ] && echo yes || echo no)"
# A home with a quote in it is still one word.
( HOME="$WORK/it's home"; EXAKIT_PERSONAL_WRAPPER="$WORK/q/exasol"; EXAKIT_PERSONAL_PRIVATE_HOME="$WORK/q/home"
  personal_write_wrapper )
check "a quote in a path stays one word" yes "$(sh -n "$WORK/q/exasol" && grep -q "it'\\\\''s home" "$WORK/q/exasol" && echo yes || echo no)"
check "the resolver and Python agree on the private home" "$PRIVATE" "$(detect_personal_deploy_roots; printf '%s' "$DETECT_PERSONAL_LAUNCHER_HOME")"

echo "the kit's own launcher in mode P (the download stubbed):"
reset_home
user_launcher                              # the user's 2.4 on PATH, never touched
(
    EXAKIT_PERSONAL_VERSION=2.5.0
    personal_use_mode P
    personal_s3_source() { printf 'https://example.test/exasol\n%s' "$(shasum -a 256 "$WORK/stub-exasol" | awk '{print $1}')"; }
    fetch_soft() { cp "$WORK/stub-exasol" "$2"; }
    PATHS="$WORK/pathhint"; : > "$PATHS"
    ensure_path_hint() { echo "$*" >> "$PATHS"; }
    push_rollback() { :; }
    personal_refuse_launcher_downgrade() { :; }
    personal_install_launcher >/dev/null 2>&1
    printf 'RC=%s\n' "$?"
    printf 'HINT=%s\n' "$(cat "$PATHS")"
    printf 'RECEIPT=%s %s\n' "$(manifest_get components.personal.ownership)" "$(manifest_get components.personal.ownership_path)"
    personal_record_manifest healthy >/dev/null 2>&1
    printf 'LAUNCHER=%s HOME=%s\n' "$(manifest_get runtime.launcher)" "$(manifest_get runtime.launcher_home)"
) > "$WORK/p.out" 2>&1
out="$(cat "$WORK/p.out")"
has "installed" "RC=0" "$out"
check "the binary is off PATH, in the kit's folder" yes "$([ -x "$EXAKIT_HOME/personal/libexec/exasol" ] && echo yes || echo no)"
check "the wrapper is the launcher" yes "$([ -x "$EXAKIT_HOME/personal/bin/exasol" ] && echo yes || echo no)"
check "nothing at the kit's PATH folder" no "$([ -e "$EXAKIT_BIN_DIR/exasol" ] && echo yes || echo no)"
check "no PATH hint for the launcher" "HINT=" "$(printf '%s\n' "$out" | grep '^HINT=')"
hasnt "...none at all" "HINT=$EXAKIT_BIN_DIR" "$out"
has "the receipt names the wrapper" "RECEIPT=kit $EXAKIT_HOME/personal/bin/exasol" "$out"
has "runtime.launcher is the wrapper, runtime.launcher_home the private home" "LAUNCHER=$EXAKIT_HOME/personal/bin/exasol HOME=$PRIVATE" "$out"
check "the user's launcher is as it was" "$(cat "$WORK/stub-exasol")" "$(cat "$WORK/userbin/exasol")"
# Python sees the same (marketplace/runtime.py).
check "Python: the same home, from the wrapper" "$PRIVATE" "$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
from runtime import personal_launcher_home; print(personal_launcher_home())' "$ROOT/marketplace")"

echo "the port of a new starter-kit-local:"
reset_home
kit_launcher
personal_pick_port
check "nothing anywhere: 8563" 8563 "$PERSONAL_PICKED_PORT"
check "...personal_db_port says it before the deploy" 8563 "$(personal_db_port)"
seed "$NEWROOT/default" exa-user 8563            # the user's, stopped, saved 8563
fresh; personal_pick_port
check "a user's stopped database saved 8563: the next" 8564 "$PERSONAL_PICKED_PORT"
seed "$OLDROOT/old" exa-old 8565
rm -f "$OLDROOT/old/infrastructure/infrastructure.yaml"   # deployment.json only
BUSY="8564"
fresh; personal_pick_port
check "8563 saved, 8564 in use, 8565 saved (deployment.json): 8566" 8566 "$PERSONAL_PICKED_PORT"
fresh; EXAKIT_PERSONAL_PORT_LAST=8565 personal_pick_port
check "none free: non-zero, no port" "1|" "$?|$PERSONAL_PICKED_PORT"
BUSY=""
fresh; PERSONAL_PICKED_PORT=8564
check "the flag the launcher takes" "--ports db:8564" "$(personal_ports_flag)"
( kit_launcher; sed -i.bak 's/--ports string/--other string/' "$EXAKIT_PERSONAL_KIT_BIN"
  check "a launcher without --ports gets none" "" "$(personal_ports_flag)"; exit "$FAIL" ) || FAIL=$((FAIL + 1))
# install local is given it: the deploy step, driven, as the launcher sees it.
reset_home
kit_launcher
seed "$NEWROOT/default" exa-user 8563            # the user's, stopped, saved 8563
: > "$STUB_CALLS"
out="$(drive_deploy)"
has "the deploy step goes through" "RC=0" "$out"
check "install local is given the port picked, for the kit's folder" 1 \
    "$(grep -c "^install local --ports db:8564 --deployment-dir $NEW\$" "$STUB_CALLS")"
check "...one install local, no other" 1 "$(grep '^install local' "$STUB_CALLS" | grep -vc -- '--help')"
# Mode P counts the user's databases in the real home too.
reset_home
seed "$NEWROOT/default" exa-user 8563
EXAKIT_PERSONAL_LAUNCHER_HOME="$PRIVATE"; EXAKIT_PERSONAL_MODE=P
personal_pick_port
check "mode P: the user's real-home database keeps its port" 8564 "$PERSONAL_PICKED_PORT"
fresh
# Nothing is adopted by its port.
reset_home
kit_launcher
BUSY="8563"
exakit_db_reachable() { return 0; }
manifest_set components.exapump.profile kit
check "a database answering on 8563 with no deployment of the kit's: not running" no \
    "$(personal_deployment_running && echo yes || echo no)"
unset -f exakit_db_reachable
BUSY=""
# exakit start names the port of the kit's database when it is held: its own
# code (setup/exakit), driven over a database whose deployment saved 8571.
eval "$(awk '/^_start_database_run\(\)/{f=1} f{print} f&&/^}$/{exit}' "$ROOT/setup/exakit")"
reset_home
kit_launcher
seed "$NEW" exa-kit 8571
record_kit "$NEW" exa-kit
start_says() {  # <port holder>: what `exakit start` dies with
    ( HOLDER="$1"
      _runtime_type() { echo personal; }
      personal_deployment_running() { return 1; }
      personal_status() { echo conflict; }
      personal_reap_orphan_daemon() { PERSONAL_PORT_HOLDER="$HOLDER"; PERSONAL_PORT_HOLDER_PID=4242; PERSONAL_PORT_HOLDER_WAIT=30; return 1; }
      personal_port_holder_hint() { :; }
      die() { printf 'DIE %s\n' "$*"; exit 1; }
      _start_database_run ) 2>&1
}
for h in other runner_other runner_young runner_live; do
    has "exakit start, the port held ($h): the kit's port, not 8563" "DIE Port 8571 is held by" "$(start_says "$h")"
done

echo "the one question: which database the starter kit uses:"
# A user's Exasol Personal 2.5 with databases (mode U).
setup_theirs() {
    reset_home
    user_launcher
    kit_launcher                                   # Step 1 put the kit's own 2.5 in the kit folder
    seed "$NEWROOT/default" exa-default 8563
    seed "$NEWROOT/dev" exa-dev 8564
    seed "$NEWROOT/slow" exa-slow 8565
    seed "$NEWROOT/broken" exa-broken 8566
    seed "$NEWROOT/cloud1" exa-cloud 8567
    seed "$NEWROOT/$NAME.not" exa-x 8568
    export STUB_LIST="$(list broken "$NEWROOT/broken" deployment_failed local cloud1 "$NEWROOT/cloud1" stopped aws \
        default "$NEWROOT/default" database_ready local dev "$NEWROOT/dev" stopped local \
        slow "$NEWROOT/slow" not_initialized "" )"
    export STUB_STATUS_slow=stopped
    EXAKIT_PERSONAL_MODE=U
}
setup_theirs
TAB="$(printf '\t')"
cands="$(personal_reuse_candidates)"
check "candidates: local ones that finished deploying, by name, with their state" \
    "default${TAB}running${TAB}$NEWROOT/default
dev${TAB}stopped${TAB}$NEWROOT/dev
slow${TAB}stopped${TAB}$NEWROOT/slow" "$cands"
check "...the not_initialized one was asked again with 30 s" 1 "$(grep -c "status --json --timeout 30 --deployment-dir $NEWROOT/slow" "$STUB_CALLS")"
answer() { _a="$( ( _exakit_prompt_tty() { :; }; personal_reuse_answer "$cands" ) 2>&1 )"; printf '%s|rc=%s' "$_a" "$?"; }
check "no terminal, no EXAKIT_REUSE_DB: a new one (D1)" "new|rc=0" "$(answer)"
for v in 0 n no new; do
    check "EXAKIT_REUSE_DB=$v: a new one" "new|rc=0" "$(EXAKIT_REUSE_DB=$v answer)"
done
check "EXAKIT_REUSE_DB=dev: dev" "dev|rc=0" "$(EXAKIT_REUSE_DB=dev answer)"
check "EXAKIT_REUSE_DB=1 (0.3.0): default" "default|rc=0" "$(EXAKIT_REUSE_DB=1 answer)"
out="$(EXAKIT_REUSE_DB=nope answer)"
has "EXAKIT_REUSE_DB=nope: refused, exit 2" "|rc=2" "$out"
has "...naming the ones it can be" "EXAKIT_REUSE_DB=nope is not a database the kit can use. Set it to one of these names: default, dev, slow. Or set it to 0 for a new database." "$out"
out="$(EXAKIT_REUSE_DB=cloud1 answer)"
has "a cloud deployment is never one" "|rc=2" "$out"
out="$(EXAKIT_REUSE_DB=broken answer)"
has "one that never finished deploying is never one" "|rc=2" "$out"
one="dev${TAB}stopped${TAB}$NEWROOT/dev"
check "EXAKIT_REUSE_DB=yes with one database (not default): that one" "dev" \
    "$( ( _exakit_prompt_tty() { :; }; EXAKIT_REUSE_DB=yes personal_reuse_answer "$one" ) 2>&1)"
two="dev${TAB}stopped${TAB}$NEWROOT/dev
slow${TAB}stopped${TAB}$NEWROOT/slow"
out="$( ( _exakit_prompt_tty() { :; }; EXAKIT_REUSE_DB=1 personal_reuse_answer "$two" ) 2>&1; printf '|rc=%s' "$?")"
has "EXAKIT_REUSE_DB=1 with two and no default: refused" "|rc=2" "$out"
has "...naming them" "Set it to one of these names: dev, slow." "$out"
tty_answer() { ( _exakit_prompt_tty() { printf 'stdin\n'; }; printf '%s' "$1" | personal_reuse_answer "$cands" ) 2>"$WORK/q.err"; }
check "terminal, Enter: a new one" new "$(tty_answer '
')"
check "terminal, 2: default" default "$(tty_answer '2
')"
check "terminal, 4: slow" slow "$(tty_answer '4
')"
check "terminal, x then 3: dev" dev "$(tty_answer 'x
3
')"
has "...asked again with a hint" "Answer with a number from 1 to 4." "$(cat "$WORK/q.err")"
tty_answer '1
' >/dev/null
q="$(sed 's/\x1b\[[0-9;]*m//g' "$WORK/q.err")"
has "the question, approved wording" "Which database should the starter kit use?" "$q"
has "...line 1" "1) A new database 'starter-kit-local' (recommended)" "$q"
has "...line 2" "2) default (running)" "$q"
has "...line 3" "3) dev (stopped)" "$q"
has "...line 4" "4) slow (stopped)" "$q"
has "...the prompt" "Choose 1-4 [1]:" "$q"
check "EXAKIT_REUSE_DB answers before the terminal" dev "$( ( _exakit_prompt_tty() { printf 'stdin\n'; }; printf '1\n' | EXAKIT_REUSE_DB=dev personal_reuse_answer "$cands" ) 2>/dev/null)"
# A leading zero is the same number: 01 is 1, 02 is 2. All zeros is asked
# again, and so is a number too long to be a choice, with no shell error.
check "terminal, 01: a new one" new "$(tty_answer '01
')"
check "terminal, 02: default" default "$(tty_answer '02
')"
check "terminal, 004: slow" slow "$(tty_answer '004
')"
check "terminal, 0 then 3: dev" dev "$(tty_answer '0
3
')"
has "...0 asked again with the hint" "Answer with a number from 1 to 4." "$(cat "$WORK/q.err")"
check "terminal, 00 then 2: default" default "$(tty_answer '00
2
')"
check "terminal, a number too long then 1: a new one" new "$(tty_answer '99999999999999999999
1
')"
hasnt "...no shell error" "integer" "$(cat "$WORK/q.err")"
nine=""
for _n in a b c d e f g h i; do nine="$nine${nine:+
}db$_n${TAB}stopped${TAB}$NEWROOT/db$_n"; done
check "terminal, 08 of ten choices: the seventh of theirs (not octal)" dbg \
    "$( ( _exakit_prompt_tty() { printf 'stdin\n'; }; printf '08\n' | personal_reuse_answer "$nine" ) 2>/dev/null)"
check "terminal, 09 of ten choices: the eighth of theirs" dbh \
    "$( ( _exakit_prompt_tty() { printf 'stdin\n'; }; printf '09\n' | personal_reuse_answer "$nine" ) 2>/dev/null)"

echo "the question in the deploy step (personal_choose_database):"
setup_theirs
out="$( ( _exakit_prompt_tty() { :; }; personal_choose_database; printf 'RC=%s NEXT=%s DIR=%s\n' "$?" "$PERSONAL_DB_NEW_NEXT_TO_THEIRS" "$EXAKIT_PERSONAL_DEPLOY_DIR" ) 2>&1)"
has "line 1, approved" "INFO Exasol Personal 2.5 is on this computer, with 3 databases of yours." "$out"
has "no terminal: a new one, next to theirs, in the kit's folder" "RC=0 NEXT=1 DIR=$NEW" "$out"
check "...theirs are not touched" "yes|yes" "$([ -d "$NEWROOT/default" ] && echo yes)|$([ -d "$NEWROOT/dev" ] && echo yes)"
check "...none was stopped" 0 "$(grep -c '^stop ' "$STUB_CALLS")"
setup_theirs
rm -rf "$NEWROOT/dev" "$NEWROOT/slow"
export STUB_LIST="$(list default "$NEWROOT/default" stopped local)"
out="$( ( _exakit_prompt_tty() { :; }; personal_choose_database ) 2>&1)"
has "one database: the singular" "with 1 database of yours." "$out"
# Mode P never asks, never lists theirs.
setup_theirs
EXAKIT_PERSONAL_MODE=P; EXAKIT_PERSONAL_LAUNCHER_HOME="$PRIVATE"
: > "$STUB_CALLS"
printf '2\n' > "$WORK/two"
out="$( ( _exakit_prompt_tty() { printf 'stdin\n'; }; personal_choose_database < "$WORK/two"; printf 'RC=%s NEXT=%s\n' "$?" "$PERSONAL_DB_NEW_NEXT_TO_THEIRS" ) 2>&1)"
has "mode P: no question, a new one next to theirs" "RC=0 NEXT=1" "$out"
hasnt "...no list line" "databases of yours" "$out"
out="$( ( EXAKIT_REUSE_DB=dev personal_choose_database ) 2>&1; printf '|rc=%s' "$?")"
has "mode P: EXAKIT_REUSE_DB=dev cannot be used: refused" "|rc=2" "$out"
has "...saying so" "EXAKIT_REUSE_DB=dev is not a database the kit can use on this computer. Unset it, or set it to 0, for a new database." "$out"
fresh
# A first install with nothing of theirs: no line, no question.
reset_home
kit_launcher
export STUB_LIST="[]"
EXAKIT_PERSONAL_MODE=K
out="$( ( _exakit_prompt_tty() { printf 'stdin\n'; }; personal_choose_database; printf 'RC=%s NEXT=%s\n' "$?" "$PERSONAL_DB_NEW_NEXT_TO_THEIRS" ) 2>&1 </dev/null)"
check "nothing of theirs: nothing said, nothing asked" "RC=0 NEXT=0" "$out"
# An existing install is never asked.
setup_theirs
seed "$NEW" exa-kit 8570
record_kit "$NEW" exa-kit
out="$( ( _exakit_prompt_tty() { printf 'stdin\n'; }; printf '2\n' | personal_choose_database; printf 'RC=%s\n' "$?" ) 2>&1)"
check "the kit's own recorded: no question" "RC=0" "$out"
setup_theirs
manifest_set components.personal.ownership user      # a first run that ended after the launcher step
out="$( ( _exakit_prompt_tty() { :; }; personal_choose_database ) 2>&1)"
has "only a launcher receipt (no database yet): still asked" "with 3 databases of yours." "$out"

echo "REN: one of theirs becomes starter-kit-local:"
setup_theirs
: > "$STUB_CALLS"
out="$( ( _exakit_prompt_tty() { :; }; EXAKIT_REUSE_DB=default personal_choose_database; printf 'RC=%s DIR=%s\n' "$?" "$EXAKIT_PERSONAL_DEPLOY_DIR" ) 2>&1)"
has "renamed, recorded, said (approved line 3)" "OK Your database 'default' is now 'starter-kit-local'. The kit uses it and never deletes it." "$out"
has "the kit's folder is the renamed one" "RC=0 DIR=$NEW" "$out"
check "it ran, so it was stopped by its folder" 1 "$(grep -c "^stop --deployment-dir $NEWROOT/default\$" "$STUB_CALLS")"
check "the folder renamed in place, its data with it" "no|yes" \
    "$([ -e "$NEWROOT/default" ] && echo yes || echo no)|$(grep -q exa-default "$NEW/.exasolLauncherState.json" && echo yes)"
check "recorded as the user's" "user|$NEW" "$(manifest_get runtime.ownership)|$(manifest_get runtime.ownership_path)"
check "...its folder, name and id" "$NEW|$NAME|exa-default" \
    "$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.deployment_name)|$(manifest_get runtime.deployment_id)"
check "...the kit's database, not managed: never destroyed" "user|no" \
    "$(exakit_component_ownership database)|$(exakit_component_is_managed database && echo yes || echo no)"
check "its 20-session limit gone, the rest kept, a backup beside it" "no|yes|yes" \
    "$(grep -q maxConnectionsLicenseLimit "$NEW/local/runtime/exa/exasol.conf" && echo yes || echo no)|$(grep -q 'other = 1' "$NEW/local/runtime/exa/exasol.conf" && echo yes)|$([ -f "$NEW/local/runtime/exa/exasol.conf.before-session-limit" ] && echo yes)"
check "...recorded as lifted" lifted "$(manifest_get runtime.session_limit)"
check "their other databases untouched" "yes|yes" "$([ -d "$NEWROOT/dev" ] && echo yes)|$([ -d "$NEWROOT/slow" ] && echo yes)"
check "...none of them stopped" 1 "$(grep -c '^stop ' "$STUB_CALLS")"
setup_theirs
out="$( ( _exakit_prompt_tty() { printf 'stdin\n'; }; printf '3\n' | personal_choose_database; printf 'RC=%s\n' "$?" ) 2>&1)"
has "terminal 3: dev renamed" "Your database 'dev' is now 'starter-kit-local'." "$out"
check "...a stopped one is not stopped again" 0 "$(grep -c "^stop --deployment-dir $NEWROOT/dev" "$STUB_CALLS")"
setup_theirs
: > "$STUB_CALLS"
printf '01\n' > "$WORK/zero1"
out="$( ( _exakit_prompt_tty() { printf 'stdin\n'; }; personal_choose_database < "$WORK/zero1"; printf 'RC=%s NEXT=%s\n' "$?" "$PERSONAL_DB_NEW_NEXT_TO_THEIRS" ) 2>&1)"
has "terminal 01: a new one, as 1, the step goes on" "RC=0 NEXT=1" "$out"
hasnt "...never a rename of nothing" "Your database ''" "$out"
check "...none of theirs stopped or renamed" "0|yes" \
    "$(grep -c '^stop ' "$STUB_CALLS")|$([ -d "$NEWROOT/default" ] && echo yes)"
setup_theirs
out="$( ( _exakit_prompt_tty() { printf 'stdin\n'; }; printf '03\n' | personal_choose_database; printf 'RC=%s\n' "$?" ) 2>&1)"
has "terminal 03: dev renamed, as 3" "Your database 'dev' is now 'starter-kit-local'." "$out"
# Q12: the one picked has a saved port something else holds now. While it is
# stopped it moves to the next free port (neither in use nor saved by another).
setup_theirs
: > "$STUB_CALLS"
out="$( ( BUSY="8564"; _exakit_prompt_tty() { :; }; EXAKIT_REUSE_DB=dev personal_choose_database; printf 'RC=%s\n' "$?" ) 2>&1)"
has "Q12: dev's port 8564 held: renamed, then moved to 8569 by the launcher" "RC=0" "$out"
check "Q12: ...config set while stopped, on the renamed folder" 1 "$(grep -c "^config set --ports db:8569 --deployment-dir $NEW\$" "$STUB_CALLS")"
has "Q12: ...said in one line" "INFO Port 8564 is in use by another database, so your database 'starter-kit-local' now uses port 8569." "$out"
setup_theirs
: > "$STUB_CALLS"
out="$( ( _exakit_prompt_tty() { :; }; EXAKIT_REUSE_DB=dev personal_choose_database ) 2>&1)"
check "Q12: ...a free saved port is kept, nothing set" 0 "$(grep -c '^config set' "$STUB_CALLS")"

echo "REN undo: nothing of theirs changes when the rename cannot happen:"
setup_theirs
mkdir -p "$NEW"                          # the target exists (an empty folder: no database, not kept)
: > "$STUB_CALLS"
out="$( ( personal_reuse_rename default "$NEWROOT/default" running; printf 'RC=%s\n' "$?" ) 2>&1)"
has "target exists: refused, said" "WARN Your database 'default' was not renamed, because ~/.exasol/launcher/deployments/$NAME already exists. Nothing was changed." "$out"
has "...the step ends" "RC=1" "$out"
check "...nothing stopped, nothing moved" "0|yes" "$(grep -c '^stop ' "$STUB_CALLS")|$([ -d "$NEWROOT/default" ] && echo yes)"
out="$( ( _exakit_prompt_tty() { :; }; personal_choose_database; printf 'RC=%s\n' "$?" ) 2>&1)"
hasnt "an empty starter-kit-local folder is no kept database" "from an earlier install" "$out"
setup_theirs
: > "$NEWROOT/default/.dirmutex.exclusive"       # a launcher command holds it
: > "$STUB_CALLS"
out="$( ( EXAKIT_REUSE_DB=default personal_choose_database; printf 'RC=%s\n' "$?" ) 2>&1)"
has "locked: refused" "because another Exasol Personal command is using it. Nothing was changed." "$out"
check "...it ran, so it was started again" "1|1" "$(grep -c "^stop --deployment-dir $NEWROOT/default" "$STUB_CALLS")|$(grep -c "^start --deployment-dir $NEWROOT/default" "$STUB_CALLS")"
check "...its folder and record as they were" "yes|no||" \
    "$([ -d "$NEWROOT/default" ] && echo yes)|$([ -e "$NEW" ] && echo yes || echo no)|$(manifest_get runtime.ownership)|$(manifest_get runtime.deployment_dir)"
check "...its limit line kept" yes "$(grep -q maxConnectionsLicenseLimit "$NEWROOT/default/local/runtime/exa/exasol.conf" && echo yes)"
setup_theirs
: > "$STUB_CALLS"
out="$( ( STUB_STOP_RC=1 EXAKIT_REUSE_DB=default personal_choose_database; printf 'RC=%s\n' "$?" ) 2>&1)"
has "it does not stop: not renamed" "WARN Your database 'default' did not stop, so it was not renamed. Nothing was changed." "$out"
check "...nothing moved" yes "$([ -d "$NEWROOT/default" ] && [ ! -e "$NEW" ] && echo yes)"
# THE LAUNCHER'S OWN WORD, ASKED NOW, decides, not the one listed before the
# question (RGR-01): started while the question waited, it is stopped first.
setup_theirs
: > "$STUB_CALLS"
out="$( ( export STUB_STATUS_dev=database_ready; EXAKIT_REUSE_DB=dev personal_choose_database; printf 'RC=%s\n' "$?" ) 2>&1)"
has "listed stopped, running by the time it is picked: renamed" "RC=0" "$out"
check "...after it was stopped" 1 "$(grep -c "^stop --deployment-dir $NEWROOT/dev\$" "$STUB_CALLS")"
# Everything that is not "stopped" touches nothing: a stop that answered 0 and
# stopped nothing, no answer, an error, an operation in progress.
for _ren in lies not_initialized deployment_failed operation_in_progress interrupted ""; do
    setup_theirs
    : > "$STUB_CALLS"
    case "$_ren" in
        lies) out="$( ( export STUB_STOP_LIES=1 STUB_STATUS_default=database_ready; EXAKIT_REUSE_DB=default personal_choose_database; printf 'RC=%s\n' "$?" ) 2>&1)" ;;
        *)    out="$( ( _ren_word="$_ren"; _personal_status_of() { printf '%s' "$_ren_word"; }
                        EXAKIT_REUSE_DB=default personal_choose_database; printf 'RC=%s\n' "$?" ) 2>&1)" ;;
    esac
    has "the launcher's word is '${_ren:-nothing}': not renamed" "WARN Your database 'default' did not stop, so it was not renamed. Nothing was changed." "$out"
    check "...the folder, its port and the record as they were" "RC=1|yes|no|0||" \
        "$(printf '%s\n' "$out" | grep -o 'RC=.*')|$([ -d "$NEWROOT/default" ] && echo yes)|$([ -e "$NEW" ] && echo yes || echo no)|$(grep -c '^config set' "$STUB_CALLS")|$(manifest_get runtime.ownership)|$(manifest_get runtime.deployment_dir)"
done
# The helpers phase B reuses: a rename and its undo, the records with it.
reset_home
seed "$OLDROOT/default" exa-030 8600
record_kit "$OLDROOT/default" exa-030
fresh
personal_rename_deployment "$OLDROOT/default" "$OLD"
check "rename: done" "0|yes|no" "$?|$([ -d "$OLD" ] && echo yes)|$([ -e "$OLDROOT/default" ] && echo yes || echo no)"
check "...the record, receipt and name in one step" "$OLD|$OLD|$NAME" \
    "$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.ownership_path)|$(manifest_get runtime.deployment_name)"
check "...the owner kept" kit "$(manifest_get runtime.ownership)"
personal_rename_deployment "$OLD" "$OLDROOT/default"
check "undo: back, and the records with it" "0|yes|$OLDROOT/default|$OLDROOT/default|default" \
    "$?|$([ -d "$OLDROOT/default" ] && echo yes)|$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.ownership_path)|$(manifest_get runtime.deployment_name)"
mkdir -p "$OLD"
personal_rename_deployment "$OLDROOT/default" "$OLD"
check "a target that exists: refused, nothing changed" "1|exists|$OLDROOT/default" "$?|$PERSONAL_RENAME_ERROR|$(manifest_get runtime.deployment_dir)"
rmdir "$OLD"
personal_rename_deployment "$WORK/none" "$OLD"
check "a source that is not there: refused" "1|missing" "$?|$PERSONAL_RENAME_ERROR"

echo "a starter-kit-local an earlier install kept (D5):"
setup_theirs
seed "$NEW" exa-kept 8570
: > "$STUB_CALLS"
out="$( ( _exakit_prompt_tty() { printf 'stdin\n'; }; personal_choose_database < "$WORK/two"; printf 'RC=%s DIR=%s\n' "$?" "$EXAKIT_PERSONAL_DEPLOY_DIR" ) 2>&1)"
has "used, said, no question" "INFO Found the database 'starter-kit-local' from an earlier install. The kit uses it and never deletes it." "$out"
hasnt "...no question" "Which database" "$out"
has "...it is the kit's folder" "RC=0 DIR=$NEW" "$out"
check "...recorded as the user's, with its id" "user|$NEW|exa-kept" \
    "$(manifest_get runtime.ownership)|$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.deployment_id)"
check "...never managed, so never destroyed" no "$(exakit_component_is_managed database && echo yes || echo no)"
check "...theirs untouched" "yes|0" "$([ -d "$NEWROOT/default" ] && echo yes)|$(grep -c '^stop ' "$STUB_CALLS")"

echo "the 0.3.0 kit database missing: the installer asks, and the record follows the answer:"
reset_home
user_launcher
kit_launcher                                   # Step 1 put the kit's own 2.5 in the kit folder
seed "$NEWROOT/default" exa-moved 8563          # the kit's 0.3.0 default, moved by the user's 2.5, no id
record_kit "$OLDROOT/default"
export STUB_LIST="$(list default "$NEWROOT/default" stopped local)"
EXAKIT_PERSONAL_MODE=""
out="$( ( EXAKIT_REUSE_DB=default personal_choose_database; printf 'RC=%s DIR=%s\n' "$?" "$EXAKIT_PERSONAL_DEPLOY_DIR" ) 2>&1)"
has "listed, picked, renamed" "Your database 'default' is now 'starter-kit-local'." "$out"
check "...its data kept, owner user" "exa-moved|user|$NEW" \
    "$(manifest_get runtime.deployment_id)|$(manifest_get runtime.ownership)|$(manifest_get runtime.deployment_dir)"
fresh
check "...no longer missing" "" "$(exakit_personal_db_state)"
reset_home
user_launcher
kit_launcher                                   # Step 1 put the kit's own 2.5 in the kit folder
seed "$NEWROOT/default" exa-moved 8563
record_kit "$OLDROOT/default"
export STUB_LIST="$(list default "$NEWROOT/default" stopped local)"
out="$( ( EXAKIT_REUSE_DB=0 personal_choose_database; printf 'RC=%s DIR=%s\n' "$?" "$EXAKIT_PERSONAL_DEPLOY_DIR" ) 2>&1)"
has "a new one instead: the kit's own folder, never the record's old one" "RC=0 DIR=$NEW" "$out"
check "...the record points at it" "$NEW" "$(manifest_get runtime.deployment_dir)"
check "...theirs untouched" yes "$([ -d "$NEWROOT/default" ] && echo yes)"

echo "the 0.3.0 kit database missing as a 0.3.0 kit has it: its own launcher 2.4.0, theirs moved its default:"
h1_home() {
    reset_home
    write_stub24 "$EXAKIT_BIN_DIR/exasol"        # the 0.3.0 kit's own launcher 2.4.0, its receipt
    exakit_record_ownership personal kit "$EXAKIT_BIN_DIR/exasol"
    manifest_set runtime.launcher "$EXAKIT_BIN_DIR/exasol"
    manifest_set runtime.version 2.4.0
    record_kit "$OLDROOT/default"                # 0.3.0 kept no id
    user_launcher                                # a 2.5 installed by hand, on PATH ...
    seed "$NEWROOT/default" exa-moved 8563       # ... and run: it moved the kit's default
    export STUB_LIST="$(list default "$NEWROOT/default" stopped local)"
    : > "$STUB_CALLS"
}
h1_home
check "the state: the kit's database missing" "kit_database_missing|$OLDROOT/default|$NEWROOT/default" "$(exakit_personal_db_state)"
out="$( ( personal_launcher_mode_decide >/dev/null 2>&1; run_step1 >/dev/null 2>&1
          printf 'KIT=%s OWNER=%s OLD=%s\n' "$("$EXAKIT_PERSONAL_KIT_BIN" version)" "$(exakit_component_ownership personal)" "$([ -e "$EXAKIT_BIN_DIR/exasol" ] && echo kept || echo retired)"
          _exakit_prompt_tty() { :; }; EXAKIT_REUSE_DB=default personal_choose_database
          printf 'RC=%s DIR=%s\n' "$?" "$EXAKIT_PERSONAL_DEPLOY_DIR" ) 2>&1)"
has "Step 1 brings the kit's own launcher to 2.5.0 in the kit folder, still the kit's, the 0.3.0 one at ~/.local/bin retired" "KIT=2.5.0 OWNER=kit OLD=retired" "$out"
check "...nothing stopped or started for it" 0 "$(grep -cE '^(stop|start) ' "$STUB_CALLS")"
has "the one question then lists the moved default" "INFO Exasol Personal 2.5 is on this computer, with 1 database of yours." "$out"
has "EXAKIT_REUSE_DB=default: renamed (approved line 3)" "OK Your database 'default' is now 'starter-kit-local'. The kit uses it and never deletes it." "$out"
has "...the kit's folder is the renamed one" "RC=0 DIR=$NEW" "$out"
check "...its data kept, the user's, recorded at starter-kit-local" "exa-moved|user|$NEW|$NEW" \
    "$(manifest_get runtime.deployment_id)|$(manifest_get runtime.ownership)|$(manifest_get runtime.ownership_path)|$(manifest_get runtime.deployment_dir)"
check "...renamed in place: no default left" "yes|no" "$([ -d "$NEW" ] && echo yes)|$([ -e "$NEWROOT/default" ] && echo yes || echo no)"
fresh
check "...no longer missing" "" "$(exakit_personal_db_state)"
h1_home
printf '2\n' > "$WORK/two"
out="$( ( personal_launcher_mode_decide >/dev/null 2>&1; run_step1 >/dev/null 2>&1
          _exakit_prompt_tty() { printf 'stdin\n'; }; personal_choose_database < "$WORK/two"
          printf 'RC=%s\n' "$?" ) 2>&1)"
has "a terminal: the question offers it" "2) default (stopped)" "$out"
has "...2 renames it" "Your database 'default' is now 'starter-kit-local'." "$out"
h1_home
out="$( ( personal_launcher_mode_decide >/dev/null 2>&1; run_step1 >/dev/null 2>&1
          _exakit_prompt_tty() { :; }; personal_choose_database
          printf 'RC=%s NEXT=%s DIR=%s\n' "$?" "$PERSONAL_DB_NEW_NEXT_TO_THEIRS" "$EXAKIT_PERSONAL_DEPLOY_DIR" ) 2>&1)"
has "no terminal, no EXAKIT_REUSE_DB: listed, then a new one (D1)" "with 1 database of yours." "$out"
has "...in the kit's own new folder, next to theirs" "RC=0 NEXT=1 DIR=$NEW" "$out"
check "...the moved default untouched" "yes|$NEW" "$([ -d "$NEWROOT/default" ] && echo yes)|$(manifest_get runtime.deployment_dir)"

echo "Step 1 installs the kit's launcher, then the one question asks it, in one process (mode K):"
m1_home() {
    reset_home
    seed "$NEWROOT/dev" exa-dev 8564             # 2.5 databases of theirs, their launcher not on PATH
    export STUB_LIST="$(list dev "$NEWROOT/dev" stopped local)"
}
m1_home
out="$( ( EXAKIT_PERSONAL_VERSION=2.5.0; personal_launcher_mode_decide >/dev/null 2>&1
          printf 'MODE=%s\n' "$EXAKIT_PERSONAL_MODE"
          run_step1 >/dev/null 2>&1
          _exakit_prompt_tty() { :; }; EXAKIT_REUSE_DB=dev personal_choose_database
          printf 'RC=%s DIR=%s\n' "$?" "$EXAKIT_PERSONAL_DEPLOY_DIR" ) 2>&1)"
has "mode K: no launcher of theirs on PATH" "MODE=K" "$out"
has "the launcher Step 1 installed lists theirs: EXAKIT_REUSE_DB=dev is used" "Your database 'dev' is now 'starter-kit-local'." "$out"
has "...the kit's folder is the renamed one" "RC=0 DIR=$NEW" "$out"
m1_home
printf '1\n' > "$WORK/one"
out="$( ( EXAKIT_PERSONAL_VERSION=2.5.0; personal_launcher_mode_decide >/dev/null 2>&1; run_step1 >/dev/null 2>&1
          _exakit_prompt_tty() { printf 'stdin\n'; }; personal_choose_database < "$WORK/one"
          printf 'RC=%s NEXT=%s\n' "$?" "$PERSONAL_DB_NEW_NEXT_TO_THEIRS" ) 2>&1)"
has "a terminal: the question is asked" "Which database should the starter kit use?" "$out"
has "...1: a new one, next to theirs (approved line 4 follows)" "RC=0 NEXT=1" "$out"

echo "an interrupted first deploy of the kit's own starter-kit-local is resumed as the kit's:"
m2_home() {
    reset_home
    kit_launcher
    exakit_record_ownership personal kit "$EXAKIT_BIN_DIR/exasol"   # Step 1 done
    seed "$NEW" exa-new 8563                     # install local made it, then the run ended
    export STUB_STATUS_starter_kit_local=deployment_failed
    export STUB_LIST="$(list "$NAME" "$NEW" deployment_failed local)"
    : > "$STUB_CALLS"
}
m2_home
manifest_set runtime.first_boot_pending true     # written right before the kit's install local
out="$(drive_deploy)"
hasnt "never taken for one an earlier install kept" "from an earlier install" "$out"
has "its deploy is retried as the kit's own" "The launcher records this deployment as failed - retrying its deploy." "$out"
check "...by its folder" 1 "$(grep -c "^deploy --deployment-dir $NEW\$" "$STUB_CALLS")"
has "...and goes through" "RC=0" "$out"
check "recorded as the kit's, with its id: managed" "kit|$NEW|exa-new|yes" \
    "$(manifest_get runtime.ownership)|$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.deployment_id)|$(exakit_component_is_managed database && echo yes || echo no)"
m2_home
manifest_set runtime.deployment_id exa-new       # the kit recorded its id (no receipt)
out="$( ( _exakit_prompt_tty() { :; }; personal_choose_database ) 2>&1)"
check "the kit's id recorded: the kit's, nothing said" "kit|" "$(manifest_get runtime.ownership)|$out"
m2_home
out="$( ( _exakit_prompt_tty() { :; }; personal_choose_database ) 2>&1)"
has "none of the kit's records: one an earlier install kept (D5), the user's" "from an earlier install" "$out"
check "...the user's" user "$(manifest_get runtime.ownership)"
# Mode P: the private home holds only what the kit's own launcher deployed.
reset_home
mkdir -p "$EXAKIT_HOME/personal/bin"; write_stub "$EXAKIT_HOME/personal/bin/exasol"
exakit_record_ownership personal kit "$EXAKIT_HOME/personal/bin/exasol"
seed "$PRIVATE/.exasol/launcher/deployments/$NAME" exa-p 8563
fresh; EXAKIT_PERSONAL_MODE=P; EXAKIT_PERSONAL_BIN="$EXAKIT_HOME/personal/bin/exasol"; EXAKIT_PERSONAL_LAUNCHER_HOME="$PRIVATE"
out="$( ( _exakit_prompt_tty() { :; }; personal_choose_database; printf 'RC=%s DIR=%s\n' "$?" "$EXAKIT_PERSONAL_DEPLOY_DIR" ) 2>&1)"
hasnt "mode P: a starter-kit-local in the private home is never a kept one of the user's" "from an earlier install" "$out"
check "...the kit's, managed: the uninstall removes it" "kit|$PRIVATE/.exasol/launcher/deployments/$NAME|yes" \
    "$(manifest_get runtime.ownership)|$(manifest_get runtime.deployment_dir)|$(exakit_component_is_managed database && echo yes || echo no)"
unset STUB_STATUS_starter_kit_local
fresh

echo "the kit's name taken by a starter-kit-local of the user's (the kit's own gone, theirs made in its place):"
mcu02_home() {
    reset_home
    user_launcher
    kit_launcher                                   # Step 1 put the kit's own 2.5 in the kit folder
    record_kit "$NEW" exa-kit                    # the kit's own, by its id ...
    seed "$NEW" exa-mine 8563                    # ... destroyed, theirs made under the same name
    seed "$NEWROOT/dev" exa-dev 8564
    export STUB_LIST="$(list dev "$NEWROOT/dev" stopped local "$NAME" "$NEW" stopped local)"
    EXAKIT_PERSONAL_MODE=U
}
mcu02_home
check "the state names the kit's folder twice" "kit_database_missing|$NEW|$NEW" "$(exakit_personal_db_state)"
printf '1\n' > "$WORK/one"
out="$( ( _exakit_prompt_tty() { printf 'stdin\n'; }; personal_choose_database < "$WORK/one"; printf 'RC=%s DIR=%s\n' "$?" "$EXAKIT_PERSONAL_DEPLOY_DIR" ) 2>&1)"
hasnt "no question: neither a new one nor a rename can have that name" "Which database" "$out"
has "said" "INFO A database of yours is named 'starter-kit-local', the name of the kit's own database. The kit uses it and never deletes it." "$out"
has "...used where it is" "RC=0 DIR=$NEW" "$out"
check "...recorded as the user's, with its own id: never destroyed" "user|$NEW|exa-mine|no" \
    "$(manifest_get runtime.ownership)|$(manifest_get runtime.ownership_path)|$(manifest_get runtime.deployment_id)|$(exakit_component_is_managed database && echo yes || echo no)"
check "...their dev untouched" yes "$([ -d "$NEWROOT/dev" ] && echo yes)"
fresh
check "...no longer missing" "" "$(exakit_personal_db_state)"
mcu02_home
out="$( ( EXAKIT_REUSE_DB=0 personal_choose_database; printf 'RC=%s\n' "$?" ) 2>&1)"
has "EXAKIT_REUSE_DB=0 (a new one): the same, said" "A database of yours is named 'starter-kit-local'" "$out"
check "...the user's" user "$(manifest_get runtime.ownership)"
reset_home
user_launcher
kit_launcher                                   # Step 1 put the kit's own 2.5 in the kit folder
record_kit "$NEW" exa-kit                        # the kit's own gone from the 2.5 root
seed "$OLD" exa-mine 8563                        # theirs of that name in the legacy root
export STUB_LIST="[]"
EXAKIT_PERSONAL_MODE=U
out="$( ( _exakit_prompt_tty() { :; }; personal_choose_database; printf 'RC=%s DIR=%s\n' "$?" "$EXAKIT_PERSONAL_DEPLOY_DIR" ) 2>&1)"
has "the same name in the other root: said, used where it is" "A database of yours is named 'starter-kit-local'" "$out"
check "...as the user's, never the kit's" "user|$OLD" "$(manifest_get runtime.ownership)|$(manifest_get runtime.deployment_dir)"
fresh

echo "REN of a database their 2.5 kept in its legacy root: its limit is lifted, and the record follows its move:"
reset_home
user_launcher
kit_launcher                                   # Step 1 put the kit's own 2.5 in the kit folder
export STUB_MIGRATE=1
seed "$OLDROOT/dev" exa-dev 8563
: > "$OLDROOT/dev/.stub-running"                 # it ran when their 2.5 first ran, so it stayed there
export STUB_LIST="$(list dev "$OLDROOT/dev" database_ready local)"
EXAKIT_PERSONAL_MODE=U
: > "$STUB_CALLS"
out="$( ( _exakit_prompt_tty() { :; }; EXAKIT_REUSE_DB=dev personal_choose_database; printf 'RC=%s DIR=%s\n' "$?" "$EXAKIT_PERSONAL_DEPLOY_DIR" ) 2>&1)"
echo END >> "$STUB_CALLS"
has "stopped, asked, moved on by that and renamed where it is now" "RC=0 DIR=$NEW" "$out"
hasnt "its limit is not left" "was not removed" "$out"
check "...recorded as lifted" lifted "$(manifest_get runtime.session_limit)"
check "...nothing but the launcher's own word between its stop and the edit" 0 \
    "$(sed -n '/^stop /,/^END$/p' "$STUB_CALLS" | grep -vc -e '^stop ' -e '^END$' -e '^status ' -e '^MIGRATED ')"
"$WORK/userbin/exasol" version >/dev/null      # the next command of theirs finds it there
fresh
personal_deploy_dir_refresh
check "...moved by their 2.5, followed by its id" "$NEW|$NEW" "$EXAKIT_PERSONAL_DEPLOY_DIR|$(manifest_get runtime.deployment_dir)"
check "...no limit line where it is now, the rest kept" "no|yes" \
    "$(grep -q maxConnectionsLicenseLimit "$NEW/local/runtime/exa/exasol.conf" && echo yes || echo no)|$(grep -q 'other = 1' "$NEW/local/runtime/exa/exasol.conf" && echo yes)"
# The edit alone, asked without the version: the launcher's own `version`
# moves the folder first, and the file is read where it is now.
reset_home
export STUB_MIGRATE=1
user_launcher
kit_launcher                                   # Step 1 put the kit's own 2.5 in the kit folder
seed "$OLD" exa-dev 8563
manifest_set runtime.deployment_dir "$OLD"; manifest_set runtime.deployment_id exa-dev
fresh
( personal_session_limit_remove "$OLD/local/runtime/exa/exasol.conf" )
check "without the version: moved first, edited where it is now" "0|no|yes|lifted" \
    "$?|$(grep -q maxConnectionsLicenseLimit "$NEW/local/runtime/exa/exasol.conf" && echo yes || echo no)|$([ -f "$NEW/local/runtime/exa/exasol.conf.before-session-limit" ] && echo yes)|$(manifest_get runtime.session_limit)"
unset STUB_MIGRATE
fresh

echo "EXAKIT_REUSE_DB: its own parser, not a yes or no:"
for v in "" 0 1 y n yes no new dev my_db-2; do
    check "valid at start-up: '$v'" 0 "$(EXAKIT_REUSE_DB="$v" exakit_validate_env_answers 2>/dev/null; echo $?)"
done
for v in "my db" "dev;rm" "-x" "a/b"; do
    check "refused at start-up: '$v'" 2 "$(EXAKIT_REUSE_DB="$v" exakit_validate_env_answers 2>/dev/null; echo $?)"
done
check "the deploy step asks no yes/no about EXAKIT_REUSE_DB" 0 "$(grep -c 'confirm_env EXAKIT_REUSE_DB' "$ROOT/setup/lib/runtime-personal.sh")"

echo "the old questions are gone: the deploy step, driven with a terminal, asks nothing of a database it uses:"
reset_home
kit_launcher
seed "$NEW" exa-kit 8563
record_kit "$NEW" exa-kit
export STUB_STATUS_starter_kit_local=stopped
: > "$STUB_CALLS"
out="$(drive_deploy)"
hasnt "the kit's own, stopped: nothing asked" "ASKED" "$out"
has "...started and used" "Reusing the existing Exasol deployment (started)" "$out"
check "...started by its folder" 1 "$(grep -c "^start --deployment-dir $NEW\$" "$STUB_CALLS")"
exakit_record_ownership database user "$NEW"
: > "$STUB_CALLS"
out="$(drive_deploy)"
hasnt "one of the user's, stopped: nothing asked" "ASKED" "$out"
has "...started and used" "Reusing the existing Exasol deployment (started)" "$out"
record_kit "$NEW" exa-kit
export STUB_STATUS_starter_kit_local=database_ready
out="$( personal_deployment_running() { return 0; }; drive_deploy )"
hasnt "the kit's own, running: nothing asked" "ASKED" "$out"
has "...used as it is" "OK Reusing the existing Exasol deployment" "$out"
unset STUB_STATUS_starter_kit_local

echo "a 0.3.0 record of a default that is gone, nothing in its place: the new database is starter-kit-local:"
# The installer run again (its deploy step, also its "marked done but not
# reachable" arm): the kit's own launcher at 2.5 already (Step 1), the 0.3.0
# kit's `default` destroyed by hand, no deployment of the user's anywhere.
for _g_root in "$OLDROOT" "$NEWROOT"; do
    reset_home
    kit_launcher
    exakit_record_ownership personal kit "$EXAKIT_BIN_DIR/exasol"
    record_kit "$_g_root/default" exa-gone
    manifest_set runtime.deployment_name default
    export STUB_LIST="[]"
    : > "$STUB_CALLS"
    out="$(drive_deploy)"
    check "gone from $(basename "$(dirname "$_g_root")"): install local into the kit's own folder, never default" 1 \
        "$(grep -c "^install local --ports db:8563 --deployment-dir $NEW\$" "$STUB_CALLS")"
    check "...no deployment named default made" "0|no|no" \
        "$(grep -c 'deployment-dir .*/default$' "$STUB_CALLS")|$([ -e "$OLDROOT/default" ] && echo yes || echo no)|$([ -e "$NEWROOT/default" ] && echo yes || echo no)"
    check "...the records name it, the kit's own, without the gone database's id" "$NEW|$NAME|kit|$NEW|" \
        "$(manifest_get runtime.deployment_dir)|$(manifest_get runtime.deployment_name)|$(manifest_get runtime.ownership)|$(manifest_get runtime.ownership_path)|$(manifest_get runtime.deployment_id 2>/dev/null)"
    hasnt "...no question asked" "ASKED" "$out"
done
unset STUB_LIST
# A folder the user chose, gone: kept as it is (never moved to the kit's name).
reset_home
kit_launcher
record_kit "$WORK/chosen/default" exa-chosen
export STUB_LIST="[]"
: > "$STUB_CALLS"
out="$(EXAKIT_PERSONAL_DEPLOY_DIR="$WORK/chosen/default" drive_deploy)"
check "a folder the user chose, gone: deployed again where they chose it" 1 \
    "$(grep -c "deployment-dir $WORK/chosen/default\$" "$STUB_CALLS")"
unset STUB_LIST

echo "a database made by a newer Exasol Personal than the kit's is not stopped and not renamed:"
reset_home
kit_launcher
seed "$NEWROOT/dev" exa-dev 8563
printf '2.5.3' > "$NEWROOT/dev/.exasolLauncher.version"
: > "$STUB_CALLS"
out="$( (personal_reuse_rename dev "$NEWROOT/dev" running 2.5.0; echo "RC=$?") 2>&1)"
has "...refused" "RC=1" "$out"
check "...nothing called, the folder as it was" "|yes|no" "$(cat "$STUB_CALLS")|$([ -d "$NEWROOT/dev" ] && echo yes)|$([ -e "$NEW" ] && echo yes || echo no)"

echo "the kit's records of what it made, when another database becomes the kit's:"
for _made in id noid; do
    reset_home
    kit_launcher
    seed "$NEWROOT/sales" exa-sales 8563
    record_kit "$NEWROOT/gone" "$([ "$_made" = id ] && echo exa-old)"
    manifest_set components.mcp_server.connection.user mcp_readonly
    manifest_set components.mcp_server.connection.created true
    manifest_set components.preprocessor.origin kit
    STUB_STATUS_sales=stopped; export STUB_STATUS_sales
    personal_reuse_rename sales "$NEWROOT/sales" stopped 2.5.0 >/dev/null 2>&1
    unset STUB_STATUS_sales
    check "another one picked ($_made): made in the old one, on record" "$([ "$_made" = id ] && echo exa-old || echo unknown)|$([ "$_made" = id ] && echo exa-old || echo unknown)|exa-sales" \
        "$(manifest_get components.mcp_server.connection.made_in)|$(manifest_get components.preprocessor.made_in)|$(manifest_get runtime.deployment_id)"
done
reset_home
kit_launcher
seed "$NEWROOT/default" exa-same 8563
record_kit "$OLDROOT/default"
manifest_set components.mcp_server.connection.created true
export STUB_STATUS_default=stopped
personal_reuse_rename default "$NEWROOT/default" stopped 2.5.0 >/dev/null 2>&1
unset STUB_STATUS_default
check "the 0.3.0 kit's own default, moved by a 2.5: the same database, nothing stamped" "" "$(manifest_get components.mcp_server.connection.made_in 2>/dev/null)"

echo "exakit repair-runtime rebuilds a database of the user's once confirmed, and it stays theirs (Q19):"
# The real cmd_repair_runtime (and the helpers above it in setup/exakit), in
# its own process. The kit copy it re-runs the setup from is a stand-in whose
# setup script only notes that it ran: no installer ever runs here.
_rr_from="$(grep -n '^_runtime_type() {' "$ROOT/setup/exakit" | head -n 1 | cut -d: -f1)"
_rr_to="$(grep -n '^case "${1:-}" in' "$ROOT/setup/exakit" | head -n 1 | cut -d: -f1)"
sed -n "${_rr_from},$((_rr_to - 1))p" "$ROOT/setup/exakit" > "$WORK/exakit-body.sh"
mkdir -p "$WORK/rrkit/setup"
for _rr_s in setup-macos.sh setup-linux.sh; do
    printf '#!/bin/sh\necho "REBUILT reuse=$EXAKIT_REUSE_DB owner=${EXAKIT_REBUILD_OWNER:-kit}" >> "%s"\nexit 0\n' "$WORK/rr-rebuilt" > "$WORK/rrkit/setup/$_rr_s"
done
cat > "$WORK/rr-run.sh" <<EXAKIT_RR_RUN
. "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
. "$ROOT/setup/lib/detect.sh" >/dev/null 2>&1
. "$ROOT/setup/lib/runtime-personal.sh" >/dev/null 2>&1
. "$WORK/exakit-body.sh" >/dev/null 2>&1
detect_os() { printf 'macos'; }
exakit_repo_root() { printf '%s' "$WORK/rrkit"; }
exakit_init_logging() { :; }
exakit_reset_dataset_flags() { :; }
cmd_repair_runtime "\$@"
EXAKIT_RR_RUN
# rr [args]: one repair-runtime; its exit code in RR_RC, stdout in RR_OUT,
# stderr in RR_ERR.
rr() {
    rm -f "$WORK/rr-rebuilt"
    RR_RC=0
    bash "$WORK/rr-run.sh" "$@" > "$WORK/rr.out" 2> "$WORK/rr.err" </dev/null || RR_RC=$?
    RR_OUT="$(cat "$WORK/rr.out")"; RR_ERR="$(cat "$WORK/rr.err")"
}
rr_case() { # rr_case <owner>: a database the kit records, with that owner
    reset_home
    kit_launcher
    seed "$NEW" exa-rr 8563
    record_kit "$NEW" exa-rr
    [ "$1" = kit ] || exakit_record_ownership database user "$NEW"
    manifest_set steps_completed '["launcher", "runtime"]'
    export STUB_STATUS_starter_kit_local=stopped
}
rr_case user
rr --yes
check "Q19: a database of the user's, --yes: rebuilt (EXAKIT_REUSE_DB=0), recorded as the user's after" "REBUILT reuse=0 owner=user|0" \
    "$(cat "$WORK/rr-rebuilt" 2>/dev/null)|$RR_RC"
has "Q19: ...after the same warning as the kit's own" "This rebuilds your database from empty. Every table in it is deleted and cannot be recovered." "$RR_OUT$RR_ERR"
hasnt "Q19: ...no refusal" "This database is yours, so the kit never deletes or replaces it." "$RR_OUT$RR_ERR"
rr
check "Q19: ...without --yes and no terminal: declined, exit 5, nothing rebuilt" "5|no" "$RR_RC|$([ -e "$WORK/rr-rebuilt" ] && echo yes || echo no)"
rr --json
check "Q19: ...--json without --yes: declined, nothing changed, exit 5" "5|False|declined|False" \
    "$RR_RC|$(printf '%s' "$RR_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s|%s|%s" % (d["ok"], d["status"], d["changed"]))' 2>&1)"
# The deploy step records a database it made for that rebuild as the user's.
check "Q19: the new database's owner, a rebuild of the user's" "user|kit" \
    "$(EXAKIT_REBUILD_OWNER=user _personal_new_database_owner)|$(_personal_new_database_owner)"
# The deploy step itself, over the user's stopped database: the code that
# decides it, with the variables repair-runtime sets. `destroy` removes the
# folder, as the launcher's does.
q19_deploy() { # q19_deploy [VAR=value ...]: the deploy step's words; launcher calls in STUB_CALLS, owners written in $WORK/owners
    : > "$STUB_CALLS"; : > "$WORK/owners"
    ( for _qv in "$@"; do export "${_qv?}"; done
      # No port of this machine decides it.
      port_in_use() { return 1; }
      eval "q19_real_$(declare -f manifest_set)"
      manifest_set() { [ "$1" = runtime.ownership ] && echo "$2" >> "$WORK/owners"; q19_real_manifest_set "$@"; }
      export STUB_STATUS_starter_kit_local="${Q19_STATE:-stopped}" STUB_LIST="$(list "$NAME" "$NEW" "${Q19_STATE:-stopped}" local)"
      drive_deploy )
}
q19_case() { # q19_case <owner>
    rr_case "$1"
    manifest_set runtime.deployment_id exa-rr
    sed -i.bak 's|^    \*) exit 0 ;;$|    destroy) [ -n "$dir" ] \&\& rm -rf "$dir"; exit 0 ;;\n    *) exit 0 ;;|' "$EXAKIT_PERSONAL_KIT_BIN" && rm -f "$EXAKIT_PERSONAL_KIT_BIN.bak"
    fresh
}
Q19_ENV="EXAKIT_REUSE_DB=0 EXAKIT_REPLACE_DB=1 EXAKIT_REBUILD_OWNER=user"
for Q19_STATE in stopped deployment_failed; do
    q19_case user
    out="$(q19_deploy $Q19_ENV)"
    if [ "$Q19_STATE" = stopped ]; then
        check "Q19 deploy step ($Q19_STATE): one destroy, one install local, on their folder" "1|1" \
            "$(grep -c "^destroy .*--deployment-dir $NEW\$" "$STUB_CALLS")|$(grep -c "^install local .*--deployment-dir $NEW" "$STUB_CALLS")"
    fi
    hasnt "Q19 deploy step ($Q19_STATE): ...not refused" "so the kit" "$out"
    check "Q19 deploy step ($Q19_STATE): ...theirs after, and never written as the kit's" "user|0" \
        "$(manifest_get runtime.ownership)|$(grep -c '^kit$' "$WORK/owners")"
done
Q19_STATE=stopped
# A running one is not stopped for it, the user's as little as the kit's own
# (as in 0.3.0): the same words, nothing changed.
for _q_owner in kit user; do
    q19_case "$_q_owner"
    out="$( ( personal_deployment_running() { return 0; }; q19_deploy $Q19_ENV ) )"
    has "Q19 deploy step (running, $_q_owner): told to stop it first" "Stop it first ('exakit stop')" "$out"
    check "Q19 deploy step (running, $_q_owner): nothing called, nothing changed" "0|yes|$_q_owner" \
        "$(grep -cE '^(stop|destroy|start)' "$STUB_CALLS")|$([ -d "$NEW" ] && echo yes)|$(manifest_get runtime.ownership)"
done
# Not that rebuild: refused, nothing destroyed, theirs.
q19_case user
out="$(q19_deploy EXAKIT_REUSE_DB=0 EXAKIT_REPLACE_DB=1)"
has "Q19: without repair-runtime's yes: never deleted" "This database is yours, so the kit never deletes it." "$out"
check "Q19: ...no destroy, the folder there, theirs" "0|yes|user" \
    "$(grep -c '^destroy' "$STUB_CALLS")|$([ -d "$NEW" ] && echo yes || echo no)|$(manifest_get runtime.ownership)"
q19_case user
manifest_set runtime.deployment_id exa-other
out="$(q19_deploy $Q19_ENV)"
check "Q19: another database than the one on record: no destroy, the folder there, theirs" "0|yes|user" \
    "$(grep -c '^destroy' "$STUB_CALLS")|$([ -d "$NEW" ] && echo yes || echo no)|$(manifest_get runtime.ownership)"
# Cut short right after the destroy: still theirs on record.
q19_case user
sed -i.bak 's|rm -rf "$dir"; exit 0|rm -rf "$dir"; kill -9 $PPID; exit 0|' "$EXAKIT_PERSONAL_KIT_BIN" && rm -f "$EXAKIT_PERSONAL_KIT_BIN.bak"
out="$(q19_deploy $Q19_ENV 2>&1)"
check "Q19: cut short in the rebuild: the record says theirs" "user|0" "$(manifest_get runtime.ownership)|$(grep -c '^kit$' "$WORK/owners")"
# CUT SHORT OR FAILED, AND THEN THE REMEDY THE KIT PRINTS, the installer run
# again (no variable of repair-runtime's): the new database is the user's too,
# never the kit's, so the uninstall keeps it (RGR-02).
q19_makes() { # install local makes the folder with a new id, or fails while $WORK/failnow is there
    sed -i.bak 's|^        if \[ "${2:-}" = local \] && \[ "${3:-}" = --help \]; then$|        if [ "${2:-}" = local ] \&\& [ "${3:-}" != --help ]; then [ ! -e "'"$WORK/failnow"'" ] \|\| exit 1; mkdir -p "$dir"; printf "{\\"deploymentId\\": \\"exa-new\\"}" > "$dir/.exasolLauncherState.json"\n        elif [ "${2:-}" = local ]; then|' "$EXAKIT_PERSONAL_KIT_BIN" && rm -f "$EXAKIT_PERSONAL_KIT_BIN.bak"
}
q19_again() { fresh; q19_deploy; }               # the installer run again: none of repair-runtime's variables
q19_case user
q19_makes; : > "$WORK/failnow"
out="$(q19_deploy $Q19_ENV)"
has "Q19: the deploy after the destroy failed" "Retry it by re-running the installer" "$out"
rm -f "$WORK/failnow"
check "Q19: the deploy after the destroy made nothing: theirs on record" user "$(manifest_get runtime.ownership)"
out="$(q19_again)"
check "Q19: ...the installer run again: its database is theirs too" "user|0|exa-new" \
    "$(manifest_get runtime.ownership)|$(grep -c '^kit$' "$WORK/owners")|$(manifest_get runtime.deployment_id)"
q19_case user
sed -i.bak 's|rm -rf "$dir"; exit 0|rm -rf "$dir"; kill -9 $PPID; exit 0|' "$EXAKIT_PERSONAL_KIT_BIN" && rm -f "$EXAKIT_PERSONAL_KIT_BIN.bak"
q19_makes
out="$(q19_deploy $Q19_ENV 2>&1)"
sed -i.bak 's|kill -9 $PPID; ||' "$EXAKIT_PERSONAL_KIT_BIN" && rm -f "$EXAKIT_PERSONAL_KIT_BIN.bak"
out="$(q19_again)"
check "Q19: ...killed between the destroy and the deploy, then the installer: theirs" "user|0" \
    "$(manifest_get runtime.ownership)|$(grep -c '^kit$' "$WORK/owners")"
check "Q19: ...and the note goes with the new database" "" "$(manifest_get runtime.rebuild_path)"
# WP2-05: cut short after `install local` made the new one, whose id is not on
# record yet: repair-runtime works again.
q19_case user
manifest_set runtime.rebuild_path "$NEW"; manifest_set runtime.deployment_id exa-before
out="$(q19_deploy $Q19_ENV)"
check "Q19: cut short after the new one was made: rebuilt again, theirs" "1|user|0" \
    "$(grep -c "^destroy .*--deployment-dir $NEW\$" "$STUB_CALLS")|$(manifest_get runtime.ownership)|$(grep -c '^kit$' "$WORK/owners")"
# A database of theirs they deleted by hand is no rebuild: the new one is the kit's.
q19_case user
q19_makes
rm -rf "$NEW"
out="$(q19_again)"
check "a database of theirs deleted by hand: the kit's own new one" kit "$(manifest_get runtime.ownership)"
# REPAIR-RUNTIME ON A RUNNING DATABASE says to stop it first, before anything
# else, the user's as the kit's own (W10b): no warning, no question, no setup.
for _q_owner in kit user; do
    for _q_arg in "--yes" "" "--json"; do
        rr_case "$_q_owner"
        export STUB_STATUS_starter_kit_local=database_ready
        sed 's|^cmd_repair_runtime |personal_deployment_running() { return 0; }\n&|' "$WORK/rr-run.sh" > "$WORK/rr-runs.sh"
        rm -f "$WORK/rr-rebuilt"; RR_RC=0
        bash "$WORK/rr-runs.sh" $_q_arg > "$WORK/rr.out" 2> "$WORK/rr.err" </dev/null || RR_RC=$?
        RR_OUT="$(cat "$WORK/rr.out")"; RR_ERR="$(cat "$WORK/rr.err")"
        has "repair-runtime $_q_arg, running, $_q_owner: told to stop it first" "Stop it first ('exakit stop')" "$RR_OUT$RR_ERR"
        hasnt "...before the warning" "This rebuilds your database from empty" "$RR_OUT$RR_ERR"
        check "...nothing run, nothing changed" "no|$_q_owner|$([ "$_q_arg" = --json ] && echo 3 || echo 7)|yes" \
            "$([ -e "$WORK/rr-rebuilt" ] && echo yes || echo no)|$(manifest_get runtime.ownership)|$RR_RC|$([ -d "$NEW" ] && echo yes)"
        [ "$_q_arg" != --json ] || check "...one object" "False|refused|False|exakit stop" \
            "$(printf '%s' "$RR_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s|%s|%s|%s" % (d["ok"], d["status"], d["changed"], d["remedy"]))' 2>&1)"
    done
done
export STUB_STATUS_starter_kit_local=stopped
# The kit's own database: rebuilt as before, after its warning.
rr_case kit
rr --yes
check "the kit's own database: rebuilt as before (EXAKIT_REUSE_DB=0), the kit's" "REBUILT reuse=0 owner=kit" "$(cat "$WORK/rr-rebuilt" 2>/dev/null)"
has "...after its warning" "This rebuilds your database from empty. Every table in it is deleted and cannot be recovered." "$RR_OUT$RR_ERR"
unset STUB_STATUS_starter_kit_local

echo "a deployment id is text, whatever it looks like (3e082473 is a JSON number, and became Infinity):"
raw() { python3 -c 'import json,sys
doc = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    doc = doc.get(part) if isinstance(doc, dict) else None
print(type(doc).__name__, doc)' "$EXAKIT_MANIFEST" "$1"; }
for _id in 3e082473 1e000003 0e123456 30824735 01234567 00000000 e1234567 Infinity NaN -0 1.5; do
    reset_home
    kit_launcher
    for _k in runtime.deployment_id components.preprocessor.made_in runtime.private_move_id runtime.deployment_name runtime.rebuild_path; do
        manifest_set "$_k" "$_id"
        check "$_id in $_k: written as text, read as written" "str $_id|$_id" "$(raw "$_k")|$(manifest_get "$_k")"
    done
    check "$_id: ...in a read-only command too, and in one read of many" "$_id|$_id" \
        "$(EXAKIT_READONLY_QUERY=1 manifest_get runtime.deployment_id)|$(manifest_get_many runtime.deployment_id)"
    reset_home
    kit_launcher
    seed "$NEW" "$_id" 8563
    record_kit "$NEW" "$_id"
    fresh
    check "$_id: the kit's own database, not missing, managed" "kit||yes" \
        "$(exakit_component_ownership database)|$(exakit_personal_db_state)|$(exakit_component_is_managed database && echo yes)"
    seed "$NEW" exa-another 8563
    fresh
    check "$_id: ...another one in its place is the user's" "user|kit_database_missing" \
        "$(exakit_component_ownership database)|$(exakit_personal_db_state | cut -d'|' -f1)"
    reset_home
    kit_launcher
    seed "$NEWROOT/default" "$_id" 8563
    record_kit "$OLDROOT/default" "$_id"
    fresh
    personal_deploy_dir_refresh
    check "$_id: a moved one is followed by it" "$NEWROOT/default" "$EXAKIT_PERSONAL_DEPLOY_DIR"
done
printf '{}\n' > "$EXAKIT_MANIFEST"
for _v in true false null 42 -7 '[1, 2]' '{"a": 1}' '"q"'; do
    manifest_set t.v "$_v"
    check "$_v is still JSON" "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])))' "$_v")" \
        "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["t"]["v"]))' "$EXAKIT_MANIFEST")"
done
for _v in 1e5 1E400 2.5 Infinity -Infinity NaN '[1e999]' '{"a": NaN}' 007; do
    manifest_set t.v "$_v"
    check "$_v stays text" "str $_v" "$(raw t.v)"
done
# A record an earlier build wrote: a number or Infinity is no id, and it is
# read again from the deployment's own file, the user's database too.
for _own in kit user; do
    for _bad in Infinity 1000.0 0.0 30824735 NaN; do
        reset_home
        kit_launcher
        seed "$NEW" 3e082473 8563
        record_kit "$NEW"
        [ "$_own" = kit ] || exakit_record_ownership database user "$NEW"
        python3 -c 'import json,sys
doc = json.load(open(sys.argv[1])); doc["runtime"]["deployment_id"] = float(sys.argv[2]) if sys.argv[2] != "30824735" else 30824735
json.dump(doc, open(sys.argv[1], "w"), indent=2)' "$EXAKIT_MANIFEST" "$_bad"
        check "$_own, $_bad on record: no id, not another one" "|" "$(manifest_get runtime.deployment_id)|$(exakit_personal_db_state)"
        fresh; unset _EXAKIT_PERSONAL_DEPLOY_ID_SEEN
        personal_deploy_dir_refresh
        check "$_own, $_bad on record: read again from its own file" "str 3e082473|$_own" "$(raw runtime.deployment_id)|$(exakit_component_ownership database)"
    done
done
fresh

echo "the engine recorded is the one the deployment says (E1), and a rebuild of the user's never guesses (E2):"
# An engine platform, Docker and Podman answering nothing of it: only the
# deployment's own record (local/runtime/container-engine.json), as the
# launcher reads it, says the engine.
eng() { ( personal_engine_platform() { return 0; }; personal_docker_usable() { _pdu_kind=ok; return 0; }
          docker() { return 0; }; podman() { return 0; }; "$@" ) 2>/dev/null; }
eng_db() { reset_home; kit_launcher; seed "$NEW" exa-eng 8563; record_kit "$NEW" exa-eng; printf '2.4.0' > "$NEW/.exasolLauncher.version"
           [ -z "${1:-}" ] || printf '{"engine":"%s"}' "$1" > "$NEW/local/runtime/container-engine.json"; fresh; }
eng_db docker
manifest_set runtime.engine podman
check "Docker by its own record, podman on the kit's: Docker" "docker|docker" "$(eng personal_engine_existing)|$(eng personal_engine_recorded)"
eng_db
rm -rf "$NEW/local/runtime/exa"
manifest_set runtime.engine docker
check "nothing of its own: the kit's record" docker "$(eng personal_engine_existing)"
eng_db
check "database data without a record: Podman, the launcher's rule" podman "$(eng personal_engine_existing)"
eng_db nonsense
check "a record that names neither: unknown, never a guess" "" "$(eng personal_engine_existing)"
# Picked in the one question, next to another database's engine on record.
reset_home; kit_launcher; seed "$NEWROOT/sales" exa-sales 8563
printf '{"engine":"docker"}' > "$NEWROOT/sales/local/runtime/container-engine.json"
record_kit "$NEWROOT/gone" exa-old; manifest_set runtime.engine podman
( export STUB_STATUS_sales=stopped; eng personal_reuse_rename sales "$NEWROOT/sales" stopped 2.5.0 ) >/dev/null 2>&1
check "picked: its own engine on record" "docker|$NEW" "$(manifest_get runtime.engine)|$(manifest_get runtime.deployment_dir)"
reset_home; kit_launcher; seed "$NEWROOT/sales" exa-sales 8563
rm -rf "$NEWROOT/sales/local/runtime/exa"
record_kit "$NEWROOT/gone" exa-old; manifest_set runtime.engine docker
( export STUB_STATUS_sales=stopped; eng personal_reuse_rename sales "$NEWROOT/sales" stopped 2.5.0 ) >/dev/null 2>&1
check "picked, and it does not say: another database's engine is not kept" "" "$(manifest_get runtime.engine)"
# The rebuild of the user's, with nothing that names its engine.
eng_db
rm -rf "$NEW/local/runtime/exa"
exakit_record_ownership database user "$NEW"; manifest_set runtime.engine podman
check "a rebuild of the user's, nothing names it: no engine, so nothing is destroyed" "" \
    "$(EXAKIT_REUSE_DB=0 EXAKIT_REPLACE_DB=1 EXAKIT_REBUILD_OWNER=user eng personal_engine_existing)"
printf '{"engine":"docker"}' > "$NEW/local/runtime/container-engine.json"
check "...and the one it says itself is the rebuild's" docker \
    "$(EXAKIT_REUSE_DB=0 EXAKIT_REPLACE_DB=1 EXAKIT_REBUILD_OWNER=user eng personal_engine_existing)"
check "what an update records is the deployment's word too" "docker" \
    "$(manifest_set runtime.engine podman; ( personal_engine_platform() { return 0; }; store_credential() { :; }; exakit_tls_record() { :; }; unset EXAKIT_PERSONAL_ENGINE; personal_record_manifest stopped ) >/dev/null 2>&1; manifest_get runtime.engine)"

echo "exakit exasol: the kit's own launcher, arguments as given:"
# The real setup/exakit, in a sandbox home of its own. The kit folder's
# launcher is a stub that says what it got, reads one line, and exits 3.
XX="$WORK/xx"; rm -rf "$XX"; mkdir -p "$XX/kit/personal/bin" "$XX/home"
cat > "$XX/stub" <<'XSTUB'
#!/bin/sh
printf 'N=%s\n' "$#"; for a in "$@"; do printf 'ARG=[%s]\n' "$a"; done
printf 'HOME=%s\n' "$HOME"
IFS= read -r x && printf 'IN=%s\n' "$x"
exit 3
XSTUB
chmod +x "$XX/stub"
xx_manifest() { printf '{"components":{"personal":{"ownership":"%s","ownership_path":"%s"}},"runtime":{"type":"personal"}}\n' "$1" "$2" > "$XX/kit/manifest.json"; }
xx() { printf 'hello world\n' | HOME="$XX/home" EXAKIT_HOME="$XX/kit" EXAKIT_MANIFEST="$XX/kit/manifest.json" \
        PATH="$XX/onpath:$PATH" bash "$ROOT/setup/exakit" exasol "$@" > "$XX/out" 2> "$XX/err"; XX_RC=$?; XX_OUT="$(cat "$XX/out")"; }
cp "$XX/stub" "$XX/kit/personal/bin/exasol"
xx_manifest kit "$XX/kit/personal/bin/exasol"
xx status --deployment-dir "a b" ""
check "mode K: the kit folder's launcher, the arguments exactly (4, one with a space, one empty), stdin, its exit code" \
    "N=4|ARG=[status]|ARG=[--deployment-dir]|ARG=[a b]|ARG=[]|IN=hello world|3" \
    "$(printf '%s' "$XX_OUT" | grep -E '^(N|ARG|IN)=' | tr '\n' '|')$XX_RC"
for _xx in "install local --help" "-h" "--help" "connect -h 127.0.0.1" "status --json"; do
    xx $_xx
    check "exakit exasol $_xx: the launcher gets it as typed, its own exit code" "$(for _xa in $_xx; do printf 'ARG=[%s]|' "$_xa"; done)3" \
        "$(printf '%s' "$XX_OUT" | grep '^ARG=' | tr '\n' '|')$XX_RC"
done
has "exakit help exasol: the kit's page of exakit exasol" "exakit exasol" \
    "$(HOME="$XX/home" EXAKIT_HOME="$XX/kit" EXAKIT_MANIFEST="$XX/kit/manifest.json" bash "$ROOT/setup/exakit" help exasol 2>&1 </dev/null)"
mkdir -p "$XX/onpath"; printf '#!/bin/sh\necho USERS\n' > "$XX/onpath/exasol"; chmod +x "$XX/onpath/exasol"
xx version
hasnt "...never the exasol on PATH (the user's)" "USERS" "$XX_OUT"
# Mode P: the wrapper in the kit folder runs the binary with the private home.
rm -rf "$XX/kit/personal"; mkdir -p "$XX/kit/personal/bin" "$XX/kit/personal/libexec"
cp "$XX/stub" "$XX/kit/personal/libexec/exasol"
( EXAKIT_HOME="$XX/kit"; EXAKIT_PERSONAL_PRIVATE_DIR="$XX/kit/personal"; EXAKIT_PERSONAL_WRAPPER="$XX/kit/personal/bin/exasol"
  EXAKIT_PERSONAL_PRIVATE_BIN="$XX/kit/personal/libexec/exasol"; EXAKIT_PERSONAL_PRIVATE_HOME="$XX/kit/personal/home"
  personal_write_wrapper )
xx_manifest kit "$XX/kit/personal/bin/exasol"
xx info
check "mode P: the wrapper, with the kit's private home, its exit code" "N=1|ARG=[info]|HOME=$XX/kit/personal/home|3" \
    "$(printf '%s' "$XX_OUT" | grep -E '^(N|ARG|HOME)=' | tr '\n' '|')$XX_RC"
# No launcher of the kit's: one line, exit 1, nothing run.
rm -rf "$XX/kit/personal"; printf '{}\n' > "$XX/kit/manifest.json"
xx version
check "no kit launcher: exit 1" 1 "$XX_RC"
hasnt "...nothing run" "N=" "$XX_OUT"
has "...one line says so" "The starter kit has no Exasol launcher of its own yet. Run the installer first." "$XX_OUT$(cat "$XX/err")"

echo
if [ "$FAIL" -eq 0 ]; then
    echo "personal-named-deploy.sh: $PASS passed, 0 failed"
else
    echo "personal-named-deploy.sh: $PASS passed, $FAIL failed"
    exit 1
fi
