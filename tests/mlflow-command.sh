#!/usr/bin/env bash
# mlflow-command.sh — `exakit mlflow` end to end against a stub MLflow server.
#
#   bash tests/mlflow-command.sh
#
# What it pins:
#   - status and url are read-only and name the remedy while nothing runs
#   - start refuses without the UDF dev kit, names the marketplace
#   - start brings a server up on 127.0.0.1, records server.json {url, port,
#     pid} (the contract the exasol-mlflow client reads), answers /health, and
#     records that MLflow is wanted (components.udf_devkit.mlflow.enabled)
#   - a second start reuses the running server; a busy --port is refused
#   - stop removes server.json and keeps the wish; `exakit start` (the
#     udf_devkit_start hook) brings it back; stop --disable and disable clear
#     the wish, after which `exakit start` starts nothing and status says so
#   - the service hooks: status words, the log target line
#   - replay hands its arguments and exit code through to exasol_mlflow
#
# A sandboxed kit home; the notebook venv is a shim around python3 with a fake
# `mlflow` package (so `import mlflow.server` passes) and a stub `mlflow`
# executable that serves /health. No database, no real MLflow.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
# Resolved: the service matches its server by the database path on the
# command line, and macOS's /var is a symlink to /private/var.
WORK="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() {
    for _pidfile in "$WORK"/kit/mlflow/server.json; do
        [ -f "$_pidfile" ] || continue
        _pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid", ""))' "$_pidfile" 2>/dev/null)"
        [ -n "$_pid" ] && kill "$_pid" 2>/dev/null
    done
    [ -n "${HOLDER_PID:-}" ] && kill "$HOLDER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
    fi
}
contains() { # contains <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}
field() { # field <json> <key> — one value of a JSON object
    printf '%s' "$1" | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else str(v).lower() if isinstance(v, bool) else v)' "$2" 2>/dev/null
}

export HOME="$WORK/user" EXAKIT_HOME="$WORK/kit" EXAKIT_NOTEBOOK_VENV="$WORK/venv"
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_NOTEBOOK_VENV/bin" "$WORK/site/mlflow" "$WORK/site/exasol_mlflow"
EXAKIT_MLFLOW_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
export EXAKIT_MLFLOW_PORT

# The venv: python3 with the fake packages on its path. Removed first, so a
# symlink at that path can never redirect the write into a real interpreter.
rm -f "$EXAKIT_NOTEBOOK_VENV/bin/python" "$EXAKIT_NOTEBOOK_VENV/bin/mlflow"
printf '#!/bin/sh\nPYTHONPATH="%s" exec python3 "$@"\n' "$WORK/site" > "$EXAKIT_NOTEBOOK_VENV/bin/python"
chmod +x "$EXAKIT_NOTEBOOK_VENV/bin/python"
: > "$WORK/site/mlflow/__init__.py"
: > "$WORK/site/mlflow/server.py"
: > "$WORK/site/exasol_mlflow/__init__.py"
cat > "$WORK/site/exasol_mlflow/__main__.py" <<'PY'
import sys
print("replay-args: " + " ".join(sys.argv[1:]))
sys.exit(3)
PY
# The server: GET /health -> OK on the port it is given.
cat > "$EXAKIT_NOTEBOOK_VENV/bin/mlflow" <<'PY'
#!/usr/bin/env python3
import http.server, sys
args = sys.argv[1:]
port = int(args[args.index("--port") + 1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK" if self.path == "/health" else b"stub")
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
chmod +x "$EXAKIT_NOTEBOOK_VENV/bin/mlflow"

# One scenario per subshell: the real modules; refusals exit the subshell.
run() { # run <shell code>
    (
        # shellcheck disable=SC1091
        . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"
        . "$ROOT/setup/lib/notebook.sh"; . "$ROOT/setup/lib/mlflow.sh"
        EXAKIT_LOG_FILE="$WORK/log"
        [ -f "$EXAKIT_HOME/manifest.json" ] || manifest_init >/dev/null 2>&1
        eval "$1"
    )
}
enabled() { run 'manifest_get components.udf_devkit.mlflow.enabled 2>/dev/null || echo unset' 2>/dev/null; }

echo "nothing running: status and url are read-only:"
out="$(run 'cmd_mlflow status --json' 2>/dev/null)"
check "status says stopped" "stopped" "$(field "$out" status)"
check "...and names the remedy" "exakit mlflow start" "$(field "$out" remedy)"
check "status writes nothing" "no" "$([ -e "$EXAKIT_HOME/mlflow" ] && echo yes || echo no)"
check "url prints nothing" "" "$(run 'cmd_mlflow url' 2>/dev/null)"

echo "start needs the UDF dev kit:"
out="$(run 'cmd_mlflow start' 2>&1)"; rc=$?
check "refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
contains "...naming the marketplace" "exakit marketplace udf-devkit" "$out"
check "...and wanting nothing" "unset" "$(enabled)"
run 'manifest_set components.udf_devkit.version 0.1.0' >/dev/null 2>&1

echo "start brings it up, records it and wants it:"
out="$(run 'cmd_mlflow start --json' 2>/dev/null)"; rc=$?
check "exit 0" "0" "$rc"
check "running" "running" "$(field "$out" status)"
url="$(field "$out" url)"
check "on 127.0.0.1 at the chosen port" "http://127.0.0.1:$EXAKIT_MLFLOW_PORT" "$url"
rec="$(cat "$EXAKIT_HOME/mlflow/server.json" 2>/dev/null)"
check "server.json carries the url" "$url" "$(field "$rec" url)"
check "...the port" "$EXAKIT_MLFLOW_PORT" "$(field "$rec" port)"
check "...and the pid" "$(field "$out" pid)" "$(field "$rec" pid)"
check "/health answers OK" "OK" "$(curl -fsS --max-time 3 "$url/health" 2>/dev/null)"
check "the wish is recorded" "true" "$(enabled)"
pid1="$(field "$rec" pid)"
out="$(run 'cmd_mlflow start --json' 2>/dev/null)"
check "a second start reuses the server" "$pid1" "$(field "$out" pid)"
check "url prints the address" "$url" "$(run 'cmd_mlflow url' 2>/dev/null)"
check "the service hook says running" "running" "$(run 'udf_devkit_status' 2>/dev/null)"
check "the log target is udf-devkit-mlflow" "udf-devkit-mlflow|MLflow server|$EXAKIT_HOME/mlflow/server.log" "$(run 'udf_devkit_log_path')"

echo "stop is for the session; exakit start brings it back:"
out="$(run 'cmd_mlflow stop --json' 2>/dev/null)"; rc=$?
check "stop: exit 0" "0" "$rc"
check "stop: stopped" "stopped" "$(field "$out" status)"
check "server.json is removed" "no" "$([ -e "$EXAKIT_HOME/mlflow/server.json" ] && echo yes || echo no)"
check "the process is gone" "no" "$(kill -0 "$pid1" 2>/dev/null && echo yes || echo no)"
check "the wish is kept" "true" "$(enabled)"
check "the hook says plain stopped" "stopped" "$(run 'udf_devkit_status' 2>/dev/null)"
run 'udf_devkit_start' >/dev/null 2>&1
check "exakit start (the hook) brings it back" "running" "$(field "$(run 'cmd_mlflow status --json' 2>/dev/null)" status)"

echo "disable clears the wish; exakit start then starts nothing:"
out="$(run 'cmd_mlflow stop --disable' 2>&1)"; rc=$?
check "stop --disable: exit 0" "0" "$rc"
contains "...says how to want it again" "until: exakit mlflow start" "$out"
check "...the wish is cleared" "false" "$(enabled)"
run 'udf_devkit_start' >/dev/null 2>&1
check "exakit start (the hook) starts nothing" "no" "$([ -e "$EXAKIT_HOME/mlflow/server.json" ] && echo yes || echo no)"
check "status says it is not enabled" "stopped (not enabled: exakit mlflow start)" "$(run 'udf_devkit_status' 2>/dev/null)"
run 'cmd_mlflow start' >/dev/null 2>&1
check "start wants it again" "true" "$(enabled)"
out="$(run 'cmd_mlflow disable --json' 2>/dev/null)"; rc=$?
check "disable: exit 0, stopped" "0 stopped" "$rc $(field "$out" status)"
check "disable clears the wish" "false" "$(enabled)"

echo "a busy --port is refused, and nothing is wanted for it:"
HOLD="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -c 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(120)' "$HOLD" &
HOLDER_PID=$!
sleep 0.5
out="$(run "cmd_mlflow start --port $HOLD" 2>&1)"; rc=$?
check "refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
contains "...naming the port" "No free port from $HOLD" "$out"
check "...and the wish stays cleared" "false" "$(enabled)"
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""

echo "arguments:"
out="$(run 'cmd_mlflow frob' 2>&1)"
contains "an unknown action is refused, naming disable too" "replay, disable" "$out"
out="$(run 'cmd_mlflow stop --frob' 2>&1)"
contains "stop names its options" "--disable" "$out"
out="$(run 'cmd_mlflow status --port 1' 2>&1)"
contains "status takes --json only" "only --json" "$out"

echo "replay hands through to exasol_mlflow:"
out="$(run 'cmd_mlflow replay --json' 2>&1)"; rc=$?
contains "its arguments" "replay-args: replay --json" "$out"
check "and its exit code" "3" "$rc"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
