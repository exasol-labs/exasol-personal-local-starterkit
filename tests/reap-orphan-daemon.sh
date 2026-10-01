#!/usr/bin/env bash
# reap-orphan-daemon.sh — regression test for personal_reap_orphan_daemon in
# setup/lib/runtime-personal.sh. The Exasol Personal launcher can leave an
# orphaned "mac-runner ... __daemon__" process bound to the database port after
# a failed deploy or a destroy that could not find its PID file. The reaper must
# kill exactly that daemon, never a foreign process, and free the port.
#
#   bash tests/reap-orphan-daemon.sh
#
# Uses spare ports (185xx) and stubbed loggers so it never touches a real
# deployment on 8563.

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
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required for this test"; exit 0; }
command -v lsof    >/dev/null 2>&1 || { echo "SKIP: lsof required for this test"; exit 0; }

# A minimal server that binds a port and accepts+closes connections, like any
# real listener. argv is passed through so ps shows the signature we assert on.
cat > "$TMP/listener.py" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(16)
while True:
    try:
        c, _ = s.accept(); c.close()
    except Exception:
        pass
PY

# Copy the listener under a name that makes ps report a "mac-runner __daemon__"
# command line (the orphan signature the reaper matches on).
cp "$TMP/listener.py" "$TMP/mac-runner-aarch64"
chmod +x "$TMP/mac-runner-aarch64"

# Redirect the listeners' stdio to /dev/null: otherwise the long-lived child
# inherits the command-substitution pipe and $(start_daemon ...) never returns.
start_daemon() { # start_daemon <port> -> echoes pid, command looks like the orphan
    python3 "$TMP/mac-runner-aarch64" "$1" __daemon__ 2 12288 >/dev/null 2>&1 &
    _pid=$!; CHILDREN="$CHILDREN $_pid"; sleep 1; echo "$_pid"
}
start_foreign() { # start_foreign <port> -> echoes pid, a non-Exasol listener
    python3 "$TMP/listener.py" "$1" >/dev/null 2>&1 &
    _pid=$!; CHILDREN="$CHILDREN $_pid"; sleep 1; echo "$_pid"
}
alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }

# Harness: stub the loggers + port_in_use, source the real module, run reaper.
# FORCE_PORT_IN_USE=1 makes the connect-based port_in_use always report "busy",
# simulating lingering CLOSE_WAIT/TIME_WAIT client sockets after a teardown — the
# reaper must still key its verdict off the LISTEN process, not the connect test.
cat > "$TMP/run.sh" <<HARNESS
info(){ :; }; warn(){ :; }; ok(){ :; }
port_in_use(){ [ "\${FORCE_PORT_IN_USE:-0}" = 1 ] && return 0; (exec 3<>"/dev/tcp/127.0.0.1/\$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }; return 1; }
# HERMETIC, like the fixtures in agent-operability.sh: the reaper now asks the
# deployment which port it is on, so a real deployment in this developer's HOME
# would answer for the ephemeral port this suite actually started a daemon on.
# An empty deployment directory makes personal_db_port fall back to the port
# set below - which is the whole point of the override.
EXAKIT_PERSONAL_DEPLOY_DIR="$TMP/no-deployment"
# THE AGE GATE IS OFF FOR THE CASES BELOW, and that is not it being ignored -
# it is the only way to test them. personal_is_orphan_daemon now spares a
# matching daemon younger than EXAKIT_PERSONAL_REAP_MIN_AGE (180s shipped),
# because a healthy runner mid-start carries exactly the name the reaper keys
# on. Every daemon this suite starts is one second old, so with the shipped
# default nothing here would ever be reaped and the cases would pass by
# accident. They run with the gate disabled; the gate itself is tested
# separately below, where the point IS the age.
EXAKIT_PERSONAL_REAP_MIN_AGE="\${EXAKIT_PERSONAL_REAP_MIN_AGE:-0}"
source "$ROOT/setup/lib/runtime-personal.sh"
EXAKIT_PERSONAL_PORT="\$1"
personal_reap_orphan_daemon
HARNESS
run_reaper()      { EXAKIT_PERSONAL_REAP_MIN_AGE=0 bash "$TMP/run.sh" "$1"; echo $?; }
run_reaper_busy() { EXAKIT_PERSONAL_REAP_MIN_AGE=0 FORCE_PORT_IN_USE=1 bash "$TMP/run.sh" "$1"; echo $?; }
# ...and the same harness with the gate at its shipped value.
run_reaper_aged() { EXAKIT_PERSONAL_REAP_MIN_AGE="$2" bash "$TMP/run.sh" "$1"; echo $?; }

# pick_port <start> — first free TCP port at or above <start>, so a stray
# listener left by an aborted earlier run can't make this suite flaky.
pick_port() {
    _p="$1"
    while lsof -nP -iTCP:"$_p" -sTCP:LISTEN -t >/dev/null 2>&1; do _p=$((_p + 1)); done
    echo "$_p"
}
P1="$(pick_port 18581)"
P2="$(pick_port $((P1 + 1)))"
P3="$(pick_port $((P2 + 1)))"

echo "personal_reap_orphan_daemon:"

# Case 1 — orphaned mac-runner daemon: reaped, port freed, returns 0.
PID="$(start_daemon "$P1")"
RC="$(run_reaper "$P1")"; sleep 1
check "orphan reaped"        no  "$(alive "$PID")"
check "orphan return code"   0   "$RC"

# Case 2 — foreign process: left untouched, returns 1 (deploy must hard-stop).
PID="$(start_foreign "$P2")"
RC="$(run_reaper "$P2")"; sleep 1
check "foreign preserved"    yes "$(alive "$PID")"
check "foreign return code"  1   "$RC"

# Case 3 — nothing on the port: no-op, returns 0.
RC="$(run_reaper "$P3")"
check "free-port return code" 0  "$RC"

# Case 4 — no listener, but the port "looks" busy (lingering client sockets):
# must return 0 (freed), not a false failure. Regression for the uninstall bug
# where a connect-based check reported the port still in use after the kill.
RC="$(run_reaper_busy "$P3")"
check "lingering-socket false positive" 0 "$RC"

echo
echo "a runner that is still coming up is NOT an orphan:"
# LIF-09, and this is the worst path in the kit. personal_status answers
# `conflict` for any port that is bound while the database does not yet answer
# SQL - which is exactly a deployment's startup window - and cmd_start reads
# `conflict` as "probably our own orphan" and calls this reaper, which
# escalates to pkill -9 -P plus kill -9. So a second `exakit start` during
# startup (two shells, an agent that retries) SIGKILLed the starting runner.
# setup/exakit records what that costs: a SIGKILLed runner leaves the launcher
# `interrupted`, after which every start fails identically forever, and the
# only cure is `exakit repair-runtime` - which deletes the database.
P4="$(pick_port $((P3 + 1)))"
PID4="$(start_daemon "$P4")"
RC4="$(run_reaper_aged "$P4" 180)"; sleep 1
check "a one-second-old daemon survives the reaper" "yes" "$(alive "$PID4")"
check "...and the reaper says the port is still held" "1" "$(printf '%s' "$RC4" | tail -1)"
kill -9 "$PID4" 2>/dev/null || true

# The gate must not become a blanket refusal: a genuinely stranded daemon,
# older than the start budget, still gets reaped. Expressed as "old" by setting
# the threshold below the process's real age rather than by waiting.
P5="$(pick_port $((P4 + 1)))"
PID5="$(start_daemon "$P5")"
RC5="$(run_reaper_aged "$P5" 1)"; sleep 1
check "a daemon past the start budget is still reaped" "no" "$(alive "$PID5")"
check "...and the port is reported free" "0" "$(printf '%s' "$RC5" | tail -1)"

# The predicate itself, on the two questions it now asks beyond the name.
_rod_src="$(sed -n '/^personal_is_orphan_daemon()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
case "$_rod_src" in
    *_personal_proc_age_seconds*) check "the predicate asks how old the process is" "yes" "yes" ;;
    *)                            check "the predicate asks how old the process is" "yes" "no"  ;;
esac
case "$_rod_src" in
    *personal_launcher_state*) check "...and what the launcher still calls it" "yes" "yes" ;;
    *)                         check "...and what the launcher still calls it" "yes" "no"  ;;
esac
# Reap only on states that mean the launcher has let go. Anything else means it
# believes the deployment is live, and we do not get to overrule it.
case "$_rod_src" in
    *"''|stopped|deployment_failed|interrupted"*) check "...reaping only what it has let go of" "yes" "yes" ;;
    *)                                            check "...reaping only what it has let go of" "yes" "no"  ;;
esac

echo
echo "exakit start reaps before it refuses:"
# THE BUG, REPRODUCED ON A REAL MACHINE. `exakit start` has a fast path for the
# "conflict" status - the port is open but nothing answers as Exasol - and it
# died there with "held by another process ..., not by Exasol. Stop that
# process". On the commonest cause of that state the sentence was FALSE: the
# holder was Exasol's own orphaned runner, the very thing
# personal_reap_orphan_daemon exists to clear. The reap never ran, and the user
# was handed a manual kill for a process the kit knew how to clean up.
#
# Read out of the source rather than executed: driving cmd_start needs an
# installed kit and a deployment, and what went wrong here was ORDER - the
# refusal standing in front of the reap - which the order of the two names
# answers exactly.
# CODE ONLY. The first version of this check grepped the raw function body and
# passed with the fix REVERTED, because the comment explaining the fix names
# personal_reap_orphan_daemon too - a guard satisfied by prose about the thing
# rather than the thing. Comment lines go before anything is located.
_cs_body="$(awk '/^cmd_start\(\)/{f=1} f{print} f&&/^}$/{if(f)exit}' "$ROOT/setup/exakit" \
    | sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d')"
_cs_reap="$(printf '%s\n' "$_cs_body" | grep -n 'personal_reap_orphan_daemon' | head -1 | cut -d: -f1)"
_cs_die="$(printf '%s\n' "$_cs_body" | grep -n 'not by Exasol' | head -1 | cut -d: -f1)"
check "the conflict branch calls the reaper at all" "yes" \
    "$([ -n "$_cs_reap" ] && echo yes || echo no)"
check "the refusal is still there for a foreign holder" "yes" \
    "$([ -n "$_cs_die" ] && echo yes || echo no)"
if [ -n "$_cs_reap" ] && [ -n "$_cs_die" ]; then
    check "and the reap comes FIRST" "yes" \
        "$([ "$_cs_reap" -lt "$_cs_die" ] && echo yes || echo "no (reap at $_cs_reap, refusal at $_cs_die)")"
else
    check "and the reap comes FIRST" "yes" "no (one of them is missing)"
fi
# A reap that succeeds must go on to START the database, not fall through to
# the refusal or return silently having done half the job.
# Guarded: with no reap line, "${_cs_reap},$p" is the invalid sed address
# ",$p", and BSD sed prints a parse error over the failure this is reporting.
_cs_after=""
if [ -n "$_cs_reap" ]; then
    _cs_after="$(printf '%s\n' "$_cs_body" | sed -n "${_cs_reap},\$p" \
        | grep -n 'exakit_ensure_runtime_running' | head -1 | cut -d: -f1)"
fi
check "a freed port then starts the database" "yes" \
    "$([ -n "$_cs_after" ] && echo yes || echo no)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
