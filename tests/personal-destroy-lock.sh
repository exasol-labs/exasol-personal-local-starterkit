#!/usr/bin/env bash
# personal-destroy-lock.sh — behavioural tests for personal_destroy in
# setup/lib/runtime-personal.sh: a lock a crashed launcher left behind no
# longer blocks an uninstall.
#
#   bash tests/personal-destroy-lock.sh
#
# What it pins:
#   - destroy fails with "locked by another operation" and no launcher runs:
#     `diag unlock --auto-approve`, then destroy once more, which succeeds.
#   - the same lock while a launcher IS running: never unlock (it could leave
#     the deployment half-written); the warning quotes the launcher's error.
#   - any other failure: no unlock, no retry; the launcher's error is quoted.
#
# Uses a stub launcher in a temp folder; never touches a real deployment.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
CHILDREN=""
cleanup() { for _p in $CHILDREN; do kill -9 "$_p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

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

# The stub launcher: `destroy` answers from $TMP/destroy.<n> (n = 1, 2, ...),
# `diag unlock` succeeds; every call is recorded in $TMP/calls.
STUB="$TMP/bin/exasol"
mkdir -p "$TMP/bin"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
echo "$*" >> "$STUB_DIR/calls"
case "$1 $2" in
    "destroy --remove")
        n=$(( $(cat "$STUB_DIR/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/n"
        cat "$STUB_DIR/destroy.$n.out" 2>/dev/null
        exit "$(cat "$STUB_DIR/destroy.$n.rc" 2>/dev/null || echo 0)" ;;
    "diag unlock") exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB"
LOCK='Error: Deployment directory is locked by another operation. Please wait. Do not use `unlock` unless you are certain that no other exasol launcher instance is running.'

# --- harness: the real module, loggers and the common layer stubbed ------------
run_case() { # run_case <name>: personal_teardown --data in a fresh shell; prints WARN lines and the outcome
    STUB_DIR="$TMP/$1" bash -c '
        info(){ :; }; ok(){ :; }; warn(){ printf "WARN %s\n" "$*"; }
        die(){ printf "DIE %s\n" "$*"; exit 1; }
        ui_spin_begin(){ :; }; ui_spin_end(){ :; }
        _exakit_log_file(){ :; }
        manifest_set(){ :; }; manifest_get(){ :; }
        run_logged(){ "$@" >/dev/null 2>&1; }
        EXAKIT_PERSONAL_DEPLOY_DIR="$STUB_DIR/deployment"
        source "'"$ROOT"'/setup/lib/runtime-personal.sh"
        personal_cli(){ printf "%s" "'"$STUB"'"; }
        personal_deployment_exists(){ return 0; }
        personal_reap_orphan_daemon(){ return 0; }
        personal_db_port(){ printf 8563; }
        personal_teardown --data
        echo "RC $?"
    '
}
setup_case() { # setup_case <name> <rc1> <out1> [<rc2> <out2>]
    mkdir -p "$TMP/$1"
    printf '%s\n' "$2" > "$TMP/$1/destroy.1.rc"; printf '%s\n' "$3" > "$TMP/$1/destroy.1.out"
    if [ $# -ge 5 ]; then printf '%s\n' "$4" > "$TMP/$1/destroy.2.rc"; printf '%s\n' "$5" > "$TMP/$1/destroy.2.out"; fi
}
calls() { cat "$TMP/$1/calls" 2>/dev/null | tr '\n' '|'; }

echo "== a stale lock is released and the destroy retried"
setup_case stale 1 "$LOCK" 0 "destroyed"
out="$(run_case stale)"
check "stale: launcher calls" "destroy --remove --auto-approve|diag unlock --auto-approve|destroy --remove --auto-approve|" "$(calls stale)"
check "stale: no warning" "" "$(printf '%s\n' "$out" | grep '^WARN' || true)"

echo "== a running launcher keeps its lock"
setup_case busy 1 "$LOCK"
sh -c "sleep 60; : $STUB" &   # a process whose command line names the launcher (the ; keeps sh from exec-ing sleep)
CHILDREN="$CHILDREN $!"
sleep 0.3
out="$(run_case busy)"
check "busy: no unlock" "destroy --remove --auto-approve|" "$(calls busy)"
contains "busy: the launcher's words" "locked by another operation" "$out"
contains "busy: the folder to check" "$TMP/busy/deployment" "$out"
kill -9 $CHILDREN 2>/dev/null; wait 2>/dev/null; CHILDREN=""

echo "== any other failure is quoted, never retried"
setup_case other 1 "$(printf 'Destroying...\nwarning: slow\nError: disk full')"
out="$(run_case other)"
check "other: one destroy" "destroy --remove --auto-approve|" "$(calls other)"
contains "other: the last error line" "(it said: Error: disk full)" "$out"

echo
echo "personal-destroy-lock: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
