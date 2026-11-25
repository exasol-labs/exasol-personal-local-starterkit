#!/usr/bin/env bash
# personal-scenario-x.sh - the kit next to an Exasol Personal the user
# installed by themselves (scenario X of the 0.3.0 post-GA run).
#
#   bash tests/personal-scenario-x.sh
#
# What it pins:
#   - every launcher call of the deploy names the kit's own deployment folder
#     (--deployment-dir), so the launcher's own choice - the folder it is run
#     from, or its default, which is the user's deployment - never applies
#   - the deploy's undo (destroy --remove) is armed only for a folder this run
#     creates, names that folder, and does nothing when it is not there: a 2.5
#     launcher follows a missing legacy folder to the deployment it moved
#   - the user's own Exasol Personal on the release line the kit pins (2.5.0)
#     is used: X1 (running) and X2 (stopped) find its deployment where the
#     launcher keeps it (~/.exasol/launcher/deployments), offer it, and record
#     it as the user's. X3 (the binary only) deploys fresh in that folder
#   - a launcher, whoever installed it, on a NEWER release line than the pin
#     (2.6) is used, never refused: the installers say one warning line before
#     step 0 and go on, and its database is offered and recorded as the user's
#
# A stub launcher in a scratch HOME stands in for the real one; it resolves the
# deployment folder the way launchers 2.4.0 and 2.5.0 do (an explicit
# --deployment-dir, then a deployment in the current folder, then the default;
# 2.5.0 also follows a missing legacy folder to its moved twin). Nothing here
# runs a real launcher or touches a real deployment.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/exakit-scenario-x.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
    fi
}
contains() { # contains <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s contains "%s"\n' "$1" "$2" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}
lacks() { # lacks <label> <needle> <haystack>
    case "$3" in
        *"$2"*) FAIL=$((FAIL + 1)); printf '  FAIL %s: must not contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
        *)      PASS=$((PASS + 1)); printf '  ok   %s lacks "%s"\n' "$1" "$2" ;;
    esac
}

# --- the stub launcher ---------------------------------------------------------
# STUB_VERSION: what `exasol version` prints. STUB_LAYOUT: legacy (2.4.0, default
# folder ~/.exasol/personal/deployments/default) or launcher (2.5.0, default
# ~/.exasol/launcher/deployments/default, and a missing legacy --deployment-dir is
# followed to its moved twin). STUB_INSTALL_RC: a failing `install local` that
# creates nothing. Every call goes to $STUB_DIR/calls, followed by "AT <folder>"
# for the folder it acted on.
mkdir -p "$TMP/bin"
STUB="$TMP/bin/exasol"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
echo "$*" >> "$STUB_DIR/calls"
dir=""; prev=""
for a in "$@"; do [ "$prev" = "--deployment-dir" ] && dir="$a"; prev="$a"; done
legacy="$HOME/.exasol/personal/deployments"
new="$HOME/.exasol/launcher/deployments"
root="$legacy"; [ "${STUB_LAYOUT:-legacy}" = launcher ] && root="$new"
marker() { [ -f "$1/.exasolLauncherState.json" ]; }
if [ -n "$dir" ]; then
    if [ "${STUB_LAYOUT:-legacy}" = launcher ] && [ ! -e "$dir" ] && \
       [ "$(dirname "$dir")" = "$legacy" ] && [ -d "$new/$(basename "$dir")" ]; then
        dir="$new/$(basename "$dir")"
    fi
elif marker "$PWD"; then dir="$(pwd -P)"
elif [ "${STUB_LAYOUT:-legacy}" = launcher ] && [ ! -d "$new/default" ] && [ -d "$legacy/default" ]; then dir="$legacy/default"
else dir="$root/default"
fi
case "$1" in
    version) echo "${STUB_VERSION:-2.4.0}"; exit 0 ;;
    # STUB_LIST: what `deployments list --json` prints (launcher 2.5.0 and
    # later); unset, the command is unknown, as to a 2.4.x launcher.
    deployments) [ -n "${STUB_LIST+x}" ] || exit 1; printf '%s\n' "$STUB_LIST"; exit 0 ;;
    --help)
        echo "  If you do not pass --deployment-dir and are not already inside a deployment directory,"
        echo "  the Exasol Launcher uses $root/default. Pass --deployment-dir"
        echo "Available Commands:"
        echo "  install     Initialize and deploy"
        echo "  sidecar     Manage sidecars"
        echo "  mcp         MCP server"
        exit 0 ;;
esac
for a in "$@"; do [ "$a" = "--help" ] && { printf 'Available Commands:\n  local       Local deployment\n'; exit 0; }; done
echo "AT $dir" >> "$STUB_DIR/calls"
case "$1" in
    install)
        if marker "$dir"; then
            echo "Error: deployment failed: deployment in $dir is in state \"stopped\"."; exit 1
        fi
        [ "${STUB_INSTALL_RC:-0}" = 0 ] || exit "$STUB_INSTALL_RC"
        mkdir -p "$dir" && echo '{"status":"stopped"}' > "$dir/.exasolLauncherState.json"
        exit 0 ;;
    destroy)
        [ -d "$dir" ] || { echo "Error: no deployment in $dir"; exit 1; }
        rm -rf "$dir"; echo "DESTROYED $dir" >> "$STUB_DIR/calls"; exit 0 ;;
    info|status) marker "$dir" || exit 1; echo '{"status":"stopped"}'; exit 0 ;;
    start|stop|deploy) marker "$dir" || exit 1; exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB"

# --- harness -----------------------------------------------------------------
# The real runtime module; the loggers, the progress bar, the engine and the
# ownership record stubbed. push_rollback writes the undo to $RB, and
# rollback_clear keeps it: the undo under test is the one ARMED while the
# install runs - what a die or Ctrl-C during it would fire.
cat > "$TMP/harness.sh" <<HARNESS
set -o pipefail
info(){ printf 'INFO %s\n' "\$*"; }; ok(){ printf 'OK %s\n' "\$*"; }; warn(){ printf 'WARN %s\n' "\$*"; }
error(){ printf 'ERROR %s\n' "\$*"; }
die(){ printf 'DIE %s\n' "\$*"; exit 1; }
ui_spin_begin(){ :; }; ui_spin_end(){ :; }; ui_tilde(){ printf '%s' "\$1"; }
ui_progress_state(){ :; }; ui_progress_begin(){ return 1; }; ui_progress_end(){ :; }
manifest_set(){ :; }; manifest_get(){ :; }; _exakit_log_file(){ :; }
exakit_can_run_python_any(){ command -v python3 >/dev/null 2>&1; }; run_python_any(){ python3 "\$@"; }
exakit_run_bounded(){ shift; "\$@"; }
port_in_use(){ [ "\${STUB_PORT_BUSY:-0}" = 1 ] && [ "\$1" = 8563 ]; }
run_logged(){ "\$@" >/dev/null 2>&1; }
exakit_note_failure(){ printf 'NOTE %s\n' "\$*"; }
exakit_install_command(){ printf 'install-cmd'; }
exakit_record_ownership(){ printf 'OWN %s\n' "\$*"; }
exakit_reuse_ownership(){ :; }
exakit_component_is_managed(){ return 1; }
exakit_component_ownership(){ printf '%s' "\${STUB_OWNER:-unknown}"; }
confirm_env(){ eval "_cev=\\\${\$1:-}"; case "\$_cev" in 1|y|Y|yes|YES|Yes) return 0;; 0|n|N|no|NO|No) return 1;; esac; [ "\$3" = y ]; }
push_rollback(){ printf '%s\n' "\$*" >> "\$RB"; }
rollback_clear(){ :; }
EXAKIT_BIN_DIR="\$HOME/.local/bin"
source "$ROOT/setup/lib/runtime-personal.sh"
personal_cli(){ printf '%s' "$STUB"; }
personal_engine_platform(){ return 1; }
personal_wsl_podman_network_ok(){ return 0; }
personal_install_podman(){ return 0; }
personal_podman_running(){ return 0; }
personal_auto_approve_flag(){ printf -- '--auto-approve'; }
personal_engine_flag(){ :; }
personal_set_first_boot_pending(){ :; }
_personal_deploy_collect(){ cat >/dev/null; }
_personal_deploy_print_tail(){ :; }
_personal_deploy_print_notice(){ :; }
personal_explain_failure(){ :; }
personal_foreign_db_hint(){ :; }
personal_recover_slow_first_boot(){ return 1; }
personal_wait_ready_or_deploy(){ return 0; }
personal_record_manifest(){ :; }
personal_reap_orphan_daemon(){ return 1; }
eval "\$@"
HARNESS

# fire_undo <case dir> - what run_rollback does with the armed undo: each line,
# last first, through sh -c, from the folder the installer ran in.
fire_undo() {
    [ -s "$1/rb" ] || return 0
    awk '{ l[NR] = $0 } END { for (i = NR; i >= 1; i--) print l[i] }' "$1/rb" | \
        while IFS= read -r _cmd; do (cd "$1/cwd" && STUB_DIR="$1" sh -c "$_cmd" >/dev/null 2>&1); done
}
# run_deploy <case> <ENV=val...> - personal_deploy_local in a scratch HOME, run
# from <case>/cwd (default: the HOME); then the armed undo is fired.
run_deploy() {
    _c="$TMP/$1"; shift
    mkdir -p "$_c/home" "$_c/cwd"
    : > "$_c/calls"; : > "$_c/rb"
    (
        export HOME="$_c/home" STUB_DIR="$_c" RB="$_c/rb"
        export EXAKIT_PERSONAL_DEPLOY_DIR=""
        for _kv in "$@"; do export "$_kv"; done
        (cd "$_c/cwd" && bash "$TMP/harness.sh" 'personal_deploy_local; echo "RC $?"' > "$_c/out" 2>&1)
        fire_undo "$_c"
    )
}
# A user's own deployment with a table in it.
user_db() { mkdir -p "$1" && echo '{"status":"stopped"}' > "$1/.exasolLauncherState.json" && echo 3 > "$1/MARKER"; }

echo "== launcher 2.4.0, run from inside the user's own deployment (its 'current directory' rule)"
C="$TMP/cwd"; mkdir -p "$C/home"
user_db "$C/home/mydb"
mkdir -p "$C"; ln -s "$C/home/mydb" "$C/cwd"
run_deploy cwd STUB_VERSION=2.4.0 STUB_LAYOUT=legacy STUB_INSTALL_RC=1
KIT="$C/home/.exasol/launcher/deployments/starter-kit-local"
contains "the install names the kit's folder" "install local --auto-approve --deployment-dir $KIT" "$(cat "$C/calls")"
lacks "...and never acts on the user's" "AT $(cd "$C/home/mydb" && pwd -P)" "$(cat "$C/calls")"
check "the user's deployment survives the armed undo" 3 "$(cat "$C/home/mydb/MARKER" 2>/dev/null)"
lacks "...and nothing was destroyed" "DESTROYED" "$(cat "$C/calls")"

echo "== launcher 2.4.0, the install creates the kit's folder, then the run fails"
C="$TMP/fresh"; mkdir -p "$C/home"
user_db "$C/home/mydb"
run_deploy fresh STUB_VERSION=2.4.0 STUB_LAYOUT=legacy
KIT="$C/home/.exasol/launcher/deployments/starter-kit-local"
contains "the undo names the kit's folder" "--deployment-dir \"$KIT\"" "$(cat "$C/rb")"
contains "...and removes what this run made" "DESTROYED $KIT" "$(cat "$C/calls")"
check "...and only that" 3 "$(cat "$C/home/mydb/MARKER" 2>/dev/null)"

echo "== launcher 2.4.0, the kit's folder was already there: no undo is armed"
C="$TMP/existing"; mkdir -p "$C/home/.exasol/launcher/deployments/starter-kit-local"
run_deploy existing STUB_VERSION=2.4.0 STUB_LAYOUT=legacy STUB_INSTALL_RC=1
lacks "no destroy is armed for a folder this run did not create" "destroy" "$(cat "$C/rb")"
check "...and the folder stays" yes "$([ -d "$C/home/.exasol/launcher/deployments/starter-kit-local" ] && echo yes || echo no)"

echo "== launcher 2.5.0 with the user's stopped deployment in ~/.exasol/launcher (X2)"
C="$TMP/x2"; mkdir -p "$C/home"
user_db "$C/home/.exasol/launcher/deployments/default"
run_deploy x2 STUB_VERSION=2.5.0 STUB_LAYOUT=launcher
check "the user's deployment survives the armed undo" 3 "$(cat "$C/home/.exasol/launcher/deployments/default/MARKER" 2>/dev/null)"
lacks "...and it was not destroyed" "DESTROYED $C/home/.exasol/launcher/deployments/default" "$(cat "$C/calls")"
contains "...the undo removed only the kit's own new folder" "DESTROYED $C/home/.exasol/launcher/deployments/starter-kit-local" "$(cat "$C/calls")"

# probe <case> <ENV=val...> -- <shell>: one call in the harness, in the case's HOME.
probe() {
    _c="$TMP/$1"; shift
    mkdir -p "$_c/home"
    : > "$_c/calls"
    (
        export HOME="$_c/home" STUB_DIR="$_c" RB="$_c/rb"
        export EXAKIT_PERSONAL_DEPLOY_DIR=""
        while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do export "$1"; shift; done
        shift
        cd "$_c/home" && bash "$TMP/harness.sh" "$@" 2>&1
    )
}
FOUND='personal_launcher_newer; echo "RC $? V=$PERSONAL_LAUNCHER_NEWER_VERSION"'

# ADOPT: the deploy step with the real ownership rule (a deployment the kit
# holds no receipt for is recorded as the user's) and the database's own
# answer stubbed; RUNNING=1 or 0.
sed -n '/^exakit_reuse_ownership() {$/,/^}$/p' "$ROOT/setup/lib/common.sh" > "$TMP/reuse-ownership.sh"
ADOPT='. "$REUSE_FN"; personal_deployment_running(){ [ "$RUNNING" = 1 ]; }; personal_launcher_supports(){ return 0; }; personal_note_guest_rebuild(){ :; }; personal_deploy_local; echo "RC $?"'
export REUSE_FN="$TMP/reuse-ownership.sh"

# The kit pins Exasol Personal 2.5.0. Next to the user's own 2.5.0 (mode U) the
# kit's database is a NEW deployment, starter-kit-local, beside theirs: their
# databases are listed in the one question, and with no terminal (and no
# EXAKIT_REUSE_DB) the answer is a new one (D1). Theirs is never stopped,
# started, installed over or recorded as the kit's.
SK_NEW() { printf '%s' "$1/home/.exasol/launcher/deployments/starter-kit-local"; }
LISTU() { printf '[{"name": "default", "path": "%s", "status": "%s", "infrastructure": "local", "installation": "local"}]' "$1" "$2"; }
echo "== X1: the user's own launcher 2.5.0, its deployment running on 8563"
C="$TMP/x1"; mkdir -p "$C/home"
user_db "$C/home/.exasol/launcher/deployments/default"
printf '{"dbPort": 8563}\n' > "$C/home/.exasol/launcher/deployments/default/deployment.json"
out="$(probe x1 STUB_VERSION=2.5.0 STUB_LAYOUT=launcher STUB_PORT_BUSY=1 EXAKIT_PERSONAL_VERSION=2.5.0 -- "$FOUND")"
contains "not newer than the pin" "RC 1 V=" "$out"
out="$(probe x1 STUB_VERSION=2.5.0 STUB_LAYOUT=launcher STUB_PORT_BUSY=1 EXAKIT_PERSONAL_VERSION=2.5.0 RUNNING=0 \
    STUB_LIST="$(LISTU "$C/home/.exasol/launcher/deployments/default" database_ready)" -- "$ADOPT")"
contains "their database is listed" "INFO Exasol Personal 2.5 is on this computer, with 1 database of yours." "$out"
contains "...no terminal: a new database next to it" "INFO Deploying the starter kit's own database 'starter-kit-local'. Your Exasol Personal is not changed." "$out"
contains "...in the kit's own folder" "install local --auto-approve --deployment-dir $(SK_NEW "$C")" "$(cat "$C/calls")"
contains "...and the step succeeds" "RC 0" "$out"
lacks "...without a refusal" "ERROR" "$out"
lacks "...theirs is never acted on" "AT $C/home/.exasol/launcher/deployments/default" "$(cat "$C/calls")"
lacks "...nor recorded as the kit's" "OWN database user" "$out"
check "...whose data stays" 3 "$(cat "$C/home/.exasol/launcher/deployments/default/MARKER" 2>/dev/null)"

echo "== X2: the same deployment, stopped"
C="$TMP/x2b"; mkdir -p "$C/home"
user_db "$C/home/.exasol/launcher/deployments/default"
out="$(probe x2b STUB_VERSION=2.5.0 STUB_LAYOUT=launcher EXAKIT_PERSONAL_VERSION=2.5.0 -- "$FOUND")"
contains "not newer than the pin" "RC 1 V=" "$out"
out="$(probe x2b STUB_VERSION=2.5.0 STUB_LAYOUT=launcher EXAKIT_PERSONAL_VERSION=2.5.0 RUNNING=0 \
    STUB_LIST="$(LISTU "$C/home/.exasol/launcher/deployments/default" stopped)" -- "$ADOPT")"
contains "their stopped database is listed" "with 1 database of yours." "$out"
contains "...a new database in the kit's own folder" "install local --auto-approve --deployment-dir $(SK_NEW "$C")" "$(cat "$C/calls")"
lacks "...theirs is not started" "start --auto-approve --deployment-dir $C/home/.exasol/launcher/deployments/default" "$(cat "$C/calls")"
contains "...and the step succeeds" "RC 0" "$out"
lacks "...and nothing was destroyed" "DESTROYED" "$(cat "$C/calls")"
check "...whose data stays" 3 "$(cat "$C/home/.exasol/launcher/deployments/default/MARKER" 2>/dev/null)"
out="$(probe x2b STUB_VERSION=2.5.0 STUB_LAYOUT=launcher EXAKIT_PERSONAL_VERSION=2.5.0 RUNNING=0 EXAKIT_REUSE_DB=default \
    STUB_LIST="$(LISTU "$C/home/.exasol/launcher/deployments/default" stopped)" -- 'rm -rf "'"$(SK_NEW "$C")"'"; '"$ADOPT")"
contains "EXAKIT_REUSE_DB=default: theirs becomes starter-kit-local" "OK Your database 'default' is now 'starter-kit-local'. The kit uses it and never deletes it." "$out"
contains "...recorded as the user's, in its new folder" "OWN database user $(SK_NEW "$C")" "$out"
check "...its data moved with the rename" 3 "$(cat "$(SK_NEW "$C")/MARKER" 2>/dev/null)"

echo "== X3: the user's 2.5.0 binary only, never deployed"
C="$TMP/x3"; mkdir -p "$C/home"
out="$(probe x3 STUB_VERSION=2.5.0 STUB_LAYOUT=launcher EXAKIT_PERSONAL_VERSION=2.5.0 -- "$FOUND")"
contains "not newer than the pin" "RC 1 V=" "$out"
# No folder of the user's choosing (EXAKIT_PERSONAL_DEPLOY_DIR unset), as an
# install runs: the fresh deployment goes where launcher 2.5.0 keeps it.
out="$(probe x3 STUB_VERSION=2.5.0 STUB_LAYOUT=launcher EXAKIT_PERSONAL_VERSION=2.5.0 RUNNING=0 EXAKIT_PERSONAL_DEPLOY_DIR= -- "$ADOPT")"
contains "a fresh deployment, in launcher 2.5.0's folder" "install local --auto-approve --deployment-dir $(SK_NEW "$C")" "$(cat "$C/calls")"
contains "...and the step succeeds" "RC 0" "$out"
lacks "...without a refusal" "ERROR" "$out"
check "...and the deployment is there" yes "$([ -f "$(SK_NEW "$C")/.exasolLauncherState.json" ] && echo yes || echo no)"
check "...and nothing in the older folder" no "$([ -d "$C/home/.exasol/personal/deployments/starter-kit-local" ] && echo yes || echo no)"

# A release line newer than the pin (2.6) is never used: the kit runs its own
# 2.5 in its own home (mode P), so the user's 2.6 and its databases are never
# seen, moved or touched.
# The real personal_cli, for the cases that need the kit's own choice of launcher.
sed -n '/^personal_cli() {$/,/^}$/p' "$ROOT/setup/lib/runtime-personal.sh" > "$TMP/personal-cli.sh"
export PCLI_FN="$TMP/personal-cli.sh"
echo "== a user's 2.6.0 on PATH, its deployment running on 8563: mode P"
C="$TMP/x26"; mkdir -p "$C/home/userbin"
user_db "$C/home/.exasol/launcher/deployments/default"
cp "$STUB" "$C/home/userbin/exasol"
out="$(probe x26 STUB_VERSION=2.6.0 STUB_LAYOUT=launcher STUB_PORT_BUSY=1 EXAKIT_PERSONAL_VERSION=2.5.0 PATH="$C/home/userbin:$PATH" -- \
    '. "$PCLI_FN"; personal_launcher_mode_decide; printf "MODE=%s BIN=%s HOME=%s\n" "$EXAKIT_PERSONAL_MODE" "$(personal_cli)" "$EXAKIT_PERSONAL_LAUNCHER_HOME"')"
contains "the kit uses its own launcher, in its own home" "MODE=P BIN=$C/home/.exasol-starter-kit/personal/bin/exasol HOME=$C/home/.exasol-starter-kit/personal/home" "$out"
contains "...and says so in one line" "INFO Exasol Personal 2.6.0 is on this computer. The starter kit uses its own Exasol Personal 2.5.0 in its own folder, so yours is not changed." "$out"
lacks "...a sentence without a semicolon" ";" "$(printf '%s\n' "$out" | grep '^INFO')"
lacks "...no launcher call that acts on a deployment" "AT " "$(cat "$C/calls")"
out="$(probe x26 STUB_VERSION=2.6.0 STUB_LAYOUT=launcher EXAKIT_PERSONAL_VERSION=2.5.0 RUNNING=0 EXAKIT_PERSONAL_MODE=P \
    EXAKIT_PERSONAL_LAUNCHER_HOME="$C/home/.exasol-starter-kit/personal/home" EXAKIT_PERSONAL_DEPLOY_DIR= \
    STUB_LIST="$(LISTU "$C/home/.exasol/launcher/deployments/default" database_ready)" -- "$ADOPT")"
contains "the deploy in mode P: the kit's own folder in the private home" \
    "install local --auto-approve --deployment-dir $C/home/.exasol-starter-kit/personal/home/.exasol/launcher/deployments/starter-kit-local" "$(cat "$C/calls")"
contains "...next to theirs, said" "Your Exasol Personal is not changed." "$out"
lacks "...their databases are not listed" "databases of yours" "$out"
lacks "...nor acted on" "AT $C/home/.exasol/launcher/deployments/default" "$(cat "$C/calls")"
check "...whose data stays" 3 "$(cat "$C/home/.exasol/launcher/deployments/default/MARKER" 2>/dev/null)"

echo "== a user's 2.6.0 that keeps its deployments somewhere new (its deployments list)"
C="$TMP/x26c"; mkdir -p "$C/home"
CUSTOM="$C/home/.exasol/somewhere-new/deployments/default"
user_db "$CUSTOM"
printf '{"dbPort": 8563}\n' > "$CUSTOM/deployment.json"
LIST26="[{\"name\": \"default\", \"path\": \"$CUSTOM\", \"status\": \"database_ready\", \"infrastructure\": \"local\", \"installation\": \"local\"}]"
out="$(probe x26c STUB_VERSION=2.6.0 STUB_LAYOUT=launcher STUB_LIST="$LIST26" EXAKIT_PERSONAL_VERSION=2.5.0 -- 'personal_warn_launcher_newer')"
check "an existing install still gets one warning line" "WARN Exasol Personal 2.6.0 is on this computer. This kit is tested with Exasol Personal 2.5.0 and uses the launcher it found." \
    "$(printf '%s\n' "$out" | grep -E '^(WARN|ERROR)' | paste -sd '|' -)"
# The uninstall of a kit that adopted it: the database is the user's, so it
# stays, and no launcher command removes it. A sandbox home and bin, stand-ins
# for every service manager first on PATH, and the stub launcher logging.
U="$TMP/x26c-un"; mkdir -p "$U/kit" "$U/bin" "$U/home" "$U/stub"
UCUSTOM="$U/home/.exasol/somewhere-new/deployments/default"
user_db "$UCUSTOM"
cat > "$U/kit/manifest.json" <<JSON
{"kit_level": 1, "steps_completed": ["runtime"], "runtime": {"type": "personal", "deployment_dir": "$UCUSTOM", "ownership": "user", "ownership_path": "$UCUSTOM"}}
JSON
printf '#!/bin/sh\n' > "$U/bin/exakit"; chmod +x "$U/bin/exakit"
for _s in launchctl systemctl curl podman docker; do printf '#!/bin/sh\nexit 1\n' > "$U/stub/$_s"; chmod +x "$U/stub/$_s"; done
printf '#!/bin/sh\necho "$*" >> "%s"\n[ "$1" = deployments ] && { printf %%s '"'"'%s'"'"'; exit 0; }\n[ "$1" = version ] && echo 2.6.0\nexit 0\n' \
    "$U/calls" "[{\"name\": \"default\", \"path\": \"$UCUSTOM\", \"status\": \"stopped\"}]" > "$U/stub/exasol"
chmod +x "$U/stub/exasol"
_py_dir="$(dirname "$(command -v python3)")"
out="$(HOME="$U/home" EXAKIT_HOME="$U/kit" EXAKIT_BIN_DIR="$U/bin" PATH="$U/stub:$_py_dir:/usr/bin:/bin" \
    bash "$ROOT/setup/exakit" uninstall --yes </dev/null 2>&1)"; _urc=$?
check "uninstall --yes runs to its end" "0" "$_urc"
check "...the user's database stays" 3 "$(cat "$UCUSTOM/MARKER" 2>/dev/null)"
lacks "...no launcher command removes it" "destroy" "$(cat "$U/calls" 2>/dev/null)"
check "...and the kit's own things are gone" "gone|gone" \
    "$([ -e "$U/kit" ] && echo kept || echo gone)|$([ -e "$U/bin/exakit" ] && echo kept || echo gone)"

echo "== a user's 2.6.0 at the kit's own path, that folder not on PATH (OWN-03)"
# The user's own, at $EXAKIT_BIN_DIR/exasol with no kit receipt, is theirs: a
# newer line than the pin, so the kit runs its own 2.5 in its own home (mode P)
# and the binary there is never run as the kit's, replaced or recorded.
C="$TMP/own03"; mkdir -p "$C/home/.local/bin"
cat > "$C/home/.local/bin/exasol" <<'L26'
#!/bin/sh
# the user's own Exasol Personal 2.6.0
case "$1" in
    version) echo 2.6.0 ;;
    install) printf 'Available presets:\n  local   Deploy locally\n' ;;
esac
exit 0
L26
chmod +x "$C/home/.local/bin/exasol"
_own03_sum="$(cksum < "$C/home/.local/bin/exasol")"
OWN03='. "$PCLI_FN"
exakit_reuse_ownership(){ printf "REUSE %s\n" "$*"; }
personal_launcher_mode_decide
printf "MODE=%s CLI=%s\n" "$EXAKIT_PERSONAL_MODE" "$(personal_cli)"'
out="$(probe own03 ROOT="$ROOT" EXAKIT_PERSONAL_VERSION=2.5.0 PATH="/usr/bin:/bin:$(dirname "$(command -v python3)")" -- "$OWN03")"
contains "the kit runs its own launcher, not the user's" "MODE=P CLI=$C/home/.exasol-starter-kit/personal/bin/exasol" "$out"
contains "...saying why, once" "INFO Exasol Personal 2.6.0 is on this computer. The starter kit uses its own Exasol Personal 2.5.0 in its own folder, so yours is not changed." "$out"
lacks "...records nothing about the user's" "REUSE" "$out"
check "...the binary is not touched" "$_own03_sum" "$(cksum < "$C/home/.local/bin/exasol")"

echo "== a listed user deployment the launcher records as failed (OWN-06)"
# Only the kit's own deployment is ever deployed again or offered for
# removal. The user's "experiments" in deployment_failed, with a first-boot
# flag left over from a kit install whose own first boot failed: never
# deployed, never destroyed, named and left.
C="$TMP/own06"; mkdir -p "$C/home"
EXPD="$C/home/.exasol/launcher/deployments/experiments"
user_db "$EXPD"
LIST06="[{\"name\": \"experiments\", \"path\": \"$EXPD\", \"status\": \"deployment_failed\"}]"
OWN06='. "$REUSE_FN"; personal_deployment_running(){ return 1; }; personal_launcher_supports(){ return 0; }; personal_note_guest_rebuild(){ :; }
personal_launcher_state(){ echo deployment_failed; }; personal_first_boot_pending(){ return 0; }; personal_stop_runner_of_failed_deployment(){ return 1; }
personal_deploy_local; echo "RC $?"'
out="$(probe own06 STUB_VERSION=2.5.0 STUB_LAYOUT=launcher STUB_LIST="$LIST06" EXAKIT_PERSONAL_DEPLOY_DIR= -- "$OWN06")"
# Never the kit's folder, never offered (it never finished deploying): the kit
# deploys its own starter-kit-local beside it.
lacks "it is not offered" "databases of yours" "$out"
contains "...the kit deploys its own beside it" "install local --auto-approve --deployment-dir $C/home/.exasol/launcher/deployments/starter-kit-local" "$(cat "$C/calls")"
contains "...and the step succeeds" "RC 0" "$out"
lacks "...no deploy of it" "deploy --auto-approve --deployment-dir $EXPD" "$(cat "$C/calls")"
lacks "...nor any destroy" "destroy" "$(cat "$C/calls")"
lacks "...nor any call on its folder" "AT $EXPD" "$(cat "$C/calls")"
check "...its data stays" 3 "$(cat "$EXPD/MARKER" 2>/dev/null)"
: > "$C/calls"
out="$(probe own06 STUB_VERSION=2.5.0 STUB_LAYOUT=launcher EXAKIT_PERSONAL_DEPLOY_DIR="$EXPD" -- \
    'personal_launcher_state(){ echo deployment_failed; }; personal_launcher_supports(){ return 0; }; _personal_start_engine_ok(){ return 0; }; personal_start; echo "RC $?"')"
contains "exakit start on an adopted failed deployment: named, not deployed" "DIE The launcher records the deployment at $EXPD as failed. It is not the kit's" "$out"
lacks "...no deploy of it" "deploy" "$(cat "$C/calls")"

echo "== the installer's one warning line"
C="$TMP/warn26"; mkdir -p "$C/home"
out="$(probe warn26 STUB_VERSION=2.6.0 STUB_LAYOUT=launcher EXAKIT_PERSONAL_VERSION=2.5.0 -- 'personal_warn_launcher_newer; echo "RC $?"')"
check "a 2.6.0 launcher: one warning, and the install goes on" "WARN Exasol Personal 2.6.0 is on this computer. This kit is tested with Exasol Personal 2.5.0 and uses the launcher it found.|RC 0" \
    "$(printf '%s\n' "$out" | grep -E '^(WARN|ERROR|INFO|RC)' | paste -sd '|' -)"
lacks "...a sentence without a semicolon" ";" "$(printf '%s\n' "$out" | grep '^WARN')"
lacks "...and no launcher call that acts on a deployment" "AT " "$(cat "$C/calls")"
out="$(probe warn26 STUB_VERSION=2.5.3 STUB_LAYOUT=launcher EXAKIT_PERSONAL_VERSION=2.5.0 -- 'personal_warn_launcher_newer; echo "RC $?"')"
check "a 2.5.3 launcher (the pinned line): nothing said" "RC 0" "$(printf '%s\n' "$out" | grep -E '^(WARN|ERROR|INFO|RC)' | paste -sd '|' -)"

echo "== what is not newer than the pin"
C="$TMP/ok25"; mkdir -p "$C/home"
out="$(probe ok25 STUB_VERSION=2.5.0 STUB_LAYOUT=launcher EXAKIT_PERSONAL_VERSION=2.5.0 -- "$FOUND")"
contains "the user's own launcher at the pinned version" "RC 1" "$out"
out="$(probe ok25 STUB_VERSION=2.5.3 STUB_LAYOUT=launcher EXAKIT_PERSONAL_VERSION=2.5.0 -- "$FOUND")"
contains "the user's own launcher a patch ahead, on the pinned line" "RC 1" "$out"
out="$(probe ok25 STUB_VERSION=2.5.1 STUB_LAYOUT=launcher STUB_OWNER=kit EXAKIT_PERSONAL_VERSION=2.5.0 -- "$FOUND")"
contains "the kit's own launcher a patch ahead (its own update path)" "RC 1" "$out"
out="$(probe ok25 STUB_VERSION=2.4.0 STUB_LAYOUT=legacy EXAKIT_PERSONAL_VERSION=2.5.0 -- "$FOUND")"
contains "an older launcher (the kit's update path moves it on)" "RC 1" "$out"
C="$TMP/own"; mkdir -p "$C/home/.exasol/personal/deployments/default"
user_db "$C/home/.exasol/launcher/deployments/default"
out="$(probe own STUB_VERSION=2.5.0 STUB_LAYOUT=launcher STUB_OWNER=kit EXAKIT_PERSONAL_VERSION=2.5.0 -- "$FOUND")"
contains "a 2.5 folder beside the kit's own deployment" "RC 1" "$out"
# Probed whoever owns it (review 0.3.1, item 5): Exasol Personal puts itself
# where the kit's launcher is and keeps the kit's ownership record.
C="$TMP/own26"; mkdir -p "$C/home/.exasol/personal/deployments/default"
echo '{"status":"stopped"}' > "$C/home/.exasol/personal/deployments/default/.exasolLauncherState.json"
out="$(probe own26 STUB_VERSION=2.6.0 STUB_LAYOUT=launcher STUB_OWNER=kit EXAKIT_PERSONAL_VERSION=2.5.0 -- "$FOUND")"
contains "a newer release line behind the kit's own record is newer" "RC 0 V=2.6.0" "$out"

# The kit follows a move the launcher makes (personal_deploy_dir_refresh), so
# 'version' is asked even with a deployment in the older folder.
echo "== a deployment in the older folder: 'version' is asked, the kit follows a move"
C="$TMP/legacy"; mkdir -p "$C/home/.exasol/personal/deployments/other"
out="$(probe legacy STUB_VERSION=2.6.0 STUB_LAYOUT=launcher EXAKIT_PERSONAL_VERSION=2.5.0 -- "$FOUND")"
contains "a 2.6 is found by its version" "RC 0 V=2.6.0" "$out"
out="$(probe legacy STUB_VERSION=2.5.0 STUB_LAYOUT=launcher EXAKIT_PERSONAL_VERSION=2.5.0 -- "$FOUND")"
contains "...and a 2.5 is not newer" "RC 1" "$out"
lacks "no --help layout probe" "--help" "$(cat "$C/calls")"

echo "== no runtime recorded: every remedy names the installer re-run, and status --json carries no refusal"
R="$TMP/noruntime"; mkdir -p "$R/kit" "$R/bin" "$R/home"
printf '{"kit_level": 1, "steps_completed": [], "install": {}}\n' > "$R/kit/manifest.json"
_py_dir="$(dirname "$(command -v python3)")"
rx() { HOME="$R/home" EXAKIT_HOME="$R/kit" EXAKIT_BIN_DIR="$R/bin" PATH="$_py_dir:/usr/bin:/bin" bash "$ROOT/setup/exakit" "$@" </dev/null 2>&1; }
contains "start names the installer re-run" "resumes at the unfinished step" "$(rx start)"
contains "mcp-doctor says finish the install" "Finish the install first" "$(rx mcp-doctor)"
check "status --json: no refusal key" "False" \
    "$(rx status --json 2>/dev/null | python3 -c 'import json,sys; t=sys.stdin.read(); print("refusal" in json.loads(t[t.index("{"):]))' 2>&1)"

echo "== the uninstall with no runtime recorded runs to its end (F-01)"
# A sandbox home and bin, and stand-ins for every service manager first on
# PATH, so nothing of this machine's own kit is reached.
D="$TMP/noruntime-un"; mkdir -p "$D/kit" "$D/bin" "$D/home"
cp "$R/kit/manifest.json" "$D/kit/manifest.json"
printf '#!/bin/sh\n' > "$D/bin/exakit"; chmod +x "$D/bin/exakit"
dx() { HOME="$D/home" EXAKIT_HOME="$D/kit" EXAKIT_BIN_DIR="$D/bin" PATH="$_py_dir:/usr/bin:/bin" bash "$ROOT/setup/exakit" uninstall --dry-run </dev/null 2>&1; }
out="$(dx)"
contains "the missing runtime is named" "No runtime recorded in the manifest" "$out"
contains "the MCP entries are listed" "managed MCP configuration" "$out"
lacks "no refusal wording" "Your own Exasol Personal is not touched." "$out"
Y="$TMP/noruntime-un-yes"; mkdir -p "$Y/kit" "$Y/bin" "$Y/home" "$Y/stub"
cp "$R/kit/manifest.json" "$Y/kit/manifest.json"
printf '#!/bin/sh\n' > "$Y/bin/exakit"; chmod +x "$Y/bin/exakit"
for _s in launchctl systemctl curl podman docker exasol; do printf '#!/bin/sh\nexit 1\n' > "$Y/stub/$_s"; chmod +x "$Y/stub/$_s"; done
out="$(HOME="$Y/home" EXAKIT_HOME="$Y/kit" EXAKIT_BIN_DIR="$Y/bin" PATH="$Y/stub:$_py_dir:/usr/bin:/bin" \
    bash "$ROOT/setup/exakit" uninstall --yes </dev/null 2>&1)"; _yrc=$?
check "uninstall --yes ends 0" "0" "$_yrc"
lacks "...without an unbound variable" "unbound variable" "$out"
check "...and removes the kit home and the exakit command" "gone|gone" \
    "$([ -e "$Y/kit" ] && echo kept || echo gone)|$([ -e "$Y/bin/exakit" ] && echo kept || echo gone)"

echo "== every launcher call that acts on a deployment names the kit's folder (sweep of every file)"
# Launcher 2.4.0 acts on the deployment in the CURRENT folder when no
# --deployment-dir is given, so one call without it, run from inside the user's
# own deployment folder, acts on the user's database (review 0.3.1, item 1:
# slc install, mcp status, start, sidecar disable, the uninstall's --remove).
# Every `"$(personal_cli)"` / `"$_x_cli"` call and every PowerShell
# `(Get-PersonalCli)` call whose subcommand acts on a deployment must carry the
# flag (a splatted list must be built with Get-PersonalDeployDirArgs); --help
# probes act on nothing.
_sweep="$(python3 - "$ROOT" <<'EXAKIT_SWEEP_PY'
import re, sys, glob, os
root = sys.argv[1]
acts = r'(install\s+local|deploy|start|stop|destroy|diag\s+unlock|info|status|slc|shell|sidecar|mcp\s+status)\b'
files = sorted(glob.glob(os.path.join(root, "setup/lib/*.sh")) + [os.path.join(root, "setup/exakit")] + glob.glob(os.path.join(root, "setup/*.sh")))
bad = []
for f in files:
    lines = open(f, encoding="utf-8").read().split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]; n = i
        while line.endswith("\\") and i + 1 < len(lines):
            i += 1; line = line[:-1] + " " + lines[i].strip()
        i += 1
        code = line.split("#", 1)[0] if line.lstrip().startswith("#") else line
        if line.lstrip().startswith("#"): continue
        for m in re.finditer(r'"\$\((?:personal_cli)\)"|"\$_[a-z]+_cli"', code):
            rest = code[m.end():]
            if re.match(r'\s+' + acts, rest) and "--deployment-dir" not in rest and "--help" not in rest:
                bad.append("%s:%d: %s" % (os.path.relpath(f, root), n + 1, line.strip()[:160]))
acts = r'"?(install|deploy|start|stop|destroy|diag|info|status|slc|shell|sidecar|mcp)"?\b'
files = sorted(glob.glob(os.path.join(root, "setup/lib/*.ps1")) + [os.path.join(root, "setup/exakit.ps1"), os.path.join(root, "setup/setup-windows.ps1")])
for f in files:
    lines = open(f, encoding="utf-8-sig").read().split("\n")
    for n, line in enumerate(lines):
        if line.lstrip().startswith("#"): continue
        for m in re.finditer(r'(?:Invoke-ExakitLogged|Invoke-ExakitBounded\s+-FilePath|&)\s*\(Get-PersonalCli\)', line):
            rest = line[m.end():]
            sm = re.match(r'\s+@(\w+)', rest)
            if sm:
                var = sm.group(1)
                whole = "\n".join(lines)
                if re.search(r'\$%s\s*\+=\s*(?:@\()?\s*Get-PersonalDeployDirArgs' % var, whole, re.I) or re.search(r'\$%s\s*=.*(--deployment-dir|Get-PersonalDeployDirArgs)' % var, whole, re.I):
                    continue
                bad.append("%s:%d: %s (splat %s without the folder nearby)" % (os.path.relpath(f, root), n + 1, line.strip()[:140], var))
                continue
            am = re.match(r'\s*(?:-Arguments\s*@\()?\s*' + acts, rest)
            if am and "--deployment-dir" not in rest and "Get-PersonalDeployDirArgs" not in rest and "--help" not in rest:
                bad.append("%s:%d: %s" % (os.path.relpath(f, root), n + 1, line.strip()[:160]))
# The marketplace's Python: a launcher argv ([launcher, ...]) is built in
# one place per module, and that place names the folder for every command
# but --help and version. The launcher's own list (deployments list) acts on
# no deployment.
for f in sorted(glob.glob(os.path.join(root, "marketplace", "**", "*.py"), recursive=True)):
    text = open(f, encoding="utf-8").read()
    for m in re.finditer(r'\[\s*(?:str\()?launcher\)?\s*,', text):
        start = text.rfind("\ndef ", 0, m.start())
        end = text.find("\ndef ", m.end())
        body = text[start:end if end > 0 else len(text)]
        line = text.count("\n", 0, m.start()) + 1
        if '"deployments", "list"' in body:
            continue
        if "--deployment-dir" not in body:
            bad.append("%s:%d: a launcher call without --deployment-dir" % (os.path.relpath(f, root), line))
print("\n".join(bad))
EXAKIT_SWEEP_PY
)"
check "no launcher call that acts on a deployment goes without --deployment-dir (shell, PowerShell, marketplace Python)" "" "$_sweep"

echo "== the installers decide the launcher before step 0 and go on, with no exit of their own"
for _sp in setup-macos.sh setup-linux.sh; do
    _f="$ROOT/setup/$_sp"
    _ck="$(grep -n '^personal_launcher_mode_decide$' "$_f" | cut -d: -f1)"
    _s0="$(grep -n 'legacy_crossing_before; fi' "$_f" | cut -d: -f1)"
    check "$_sp: the launcher is decided before step 0" yes "$([ -n "$_ck" ] && [ -n "$_s0" ] && [ "$_ck" -lt "$_s0" ] && echo yes || echo no)"
    lacks "$_sp: ...and no exit for it" 'EXAKIT_EXIT_PERSONAL_NEWER' "$(cat "$_f")"
done
_ps="$ROOT/setup/setup-windows.ps1"
_ck="$(grep -n '^    Write-PersonalLauncherNewerWarning$' "$_ps" | cut -d: -f1)"
_s0="$(grep -n 'Invoke-LegacyCrossingBefore$' "$_ps" | head -1 | cut -d: -f1)"
check "setup-windows.ps1: the warning comes before step 0" yes "$([ -n "$_ck" ] && [ -n "$_s0" ] && [ "$_ck" -lt "$_s0" ] && echo yes || echo no)"
lacks "setup-windows.ps1: ...and no exit for it" 'PersonalExitNewer' "$(cat "$_ps")"
check "the warning is the same sentence on both sides" "1 1" \
    "$(grep -c 'is on this computer. This kit is tested with Exasol Personal ' "$ROOT/setup/lib/runtime-personal.sh") $(grep -c 'is on this computer. This kit is tested with Exasol Personal ' "$ROOT/setup/lib/runtime-personal.ps1")"

echo "== the MCP step names the true reason it cannot set the server up"
mcp_reason() { # mcp_reason <deploy dir> <owner>: the two lines mcp_sidecar_apply prints
    STUB_OWNER="$2" EXAKIT_PERSONAL_DEPLOY_DIR="$1" bash -c '
        error(){ printf "ERROR %s\n" "$*"; }; info(){ printf "INFO %s\n" "$*"; }
        manifest_get(){ :; }; manifest_set(){ :; }
        exakit_component_is_managed(){ [ "$STUB_OWNER" = kit ]; }
        source "'"$ROOT"'/setup/lib/mcp.sh"
        mcp_sidecar_supported(){ return 1; }
        mcp_sidecar_apply' 2>&1
}
mkdir -p "$TMP/mcp/deploy"
out="$(mcp_reason "$TMP/mcp/none" user)"
contains "no deployment of the kit's own: says so" "ERROR This kit has no database deployment yet, so the MCP server has nothing to run beside." "$out"
lacks "...and not that a launcher predates 2.4.0" "predates" "$out"
out="$(mcp_reason "$TMP/mcp/deploy" user)"
contains "a launcher the user installed: says so" "ERROR Your own Exasol launcher has no MCP sidecar" "$out"
lacks "...and does not offer to update a launcher the kit does not own" "exakit update personal" "$out"
out="$(mcp_reason "$TMP/mcp/deploy" kit)"
contains "the kit's own old launcher keeps its message" "predates 2.4.0" "$out"
contains "...and its fix" "INFO Fix: exakit update personal" "$out"

echo "== the uninstall's leftover report says what its command really does"
leftover() { # leftover <remedy>
    EXAKIT_TEARDOWN_REMEDY="$1" bash -c '
        error(){ printf "ERROR %s\n" "$*"; }; info(){ printf "INFO %s\n" "$*"; }
        eval "$(sed -n "/^_exakit_uninstall_leftover_report()/,/^}/p" "'"$ROOT"'/setup/lib/common.sh")"
        EXAKIT_TEARDOWN_LEFTOVERS="x"
        _exakit_uninstall_leftover_report' 2>&1
}
out="$(leftover "kill 61275 2>/dev/null")"
lacks "a runner's kill is not said to delete data" "deletes the database" "$out"
contains "...it is said to stop it, only if it is the user's to stop" "INFO Stop it with this command, only if it is yours to stop (it deletes no data):" "$out"
out="$(leftover "kill 1 2>/dev/null; rm -rf '/x/default'")"
contains "a remedy that removes the folder still says it deletes the data" "INFO Remove it with (this deletes the database and all its data):" "$out"

echo
echo "personal-scenario-x: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
