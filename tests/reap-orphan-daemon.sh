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
source "$ROOT/setup/lib/runtime-personal.sh"
EXAKIT_PERSONAL_PORT="\$1"
personal_reap_orphan_daemon
HARNESS
run_reaper()      { bash "$TMP/run.sh" "$1"; echo $?; }
run_reaper_busy() { FORCE_PORT_IN_USE=1 bash "$TMP/run.sh" "$1"; echo $?; }

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
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
