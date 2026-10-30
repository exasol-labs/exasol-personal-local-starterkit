#!/usr/bin/env bash
# Public workflow CLI contract, including the Python marketplace adapter.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/user" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
export EXAKIT_VERSION_POLICY=pinned
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
PASS=0 FAIL=0

check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi
}
contains() {
    case "$3" in *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
        *) FAIL=$((FAIL + 1)); printf '  FAIL %s: [%s] absent from [%s]\n' "$1" "$2" "$3" ;; esac
}
run() { OUT="$(bash "$ROOT/setup/exakit" workflow "$@" 2>&1)"; CODE=$?; }

run; check "missing action" 2 "$CODE"; contains "names usage" "exakit workflow list" "$OUT"
run frobnicate; check "unknown action" 2 "$CODE"; contains "names supported actions" "supported: list, show" "$OUT"
run list --bogus; check "unknown option" 2 "$CODE"; contains "names bad option" "--bogus" "$OUT"
run show ../other; check "path is not an id" 2 "$CODE"
run show nope; check "invalid id" 2 "$CODE"; contains "id shape" "wf-YYYYMMDD-xxxxxx" "$OUT"
run show; check "missing id" 2 "$CODE"
run list extra; check "list argument" 2 "$CODE"
run frobnicate --json; check "JSON refusal exit" 2 "$CODE"
check "JSON refusal is one object" yes "$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if d["rejected"] and not d["ok"] else "no")')"
check "refusals created no workflows" 0 "$(find "$EXAKIT_HOME" -name 'wf-*.jsonl' | wc -l | tr -d ' ')"

run list --json; check "missing notebook exit" 1 "$CODE"
check "missing notebook remedy" 'exakit marketplace notebook' "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["remedy"])')"
printf '{"components":{"notebook":{"version":"3.1.0"}}}\n' > "$EXAKIT_HOME/manifest.json"
run list; check "missing venv exit" 1 "$CODE"; contains "missing venv remedy" "exakit notebook setup" "$OUT"

mkdir -p "$EXAKIT_HOME/notebook-venv/bin"
cat > "$EXAKIT_HOME/notebook-venv/bin/python" <<STUB
#!/bin/sh
PYTHONPATH="$ROOT/notebook/package" exec python3 "\$@"
STUB
chmod +x "$EXAKIT_HOME/notebook-venv/bin/python"
run list; check "empty list exit" 0 "$CODE"; contains "empty list message" "No workflows yet" "$OUT"
WF="$(PYTHONPATH="$ROOT/notebook/package" python3 -c 'import importlib; w=importlib.import_module("exakit_nb.workflow"); wid=w.workflow("demo"); w.log_event(w.SQL,sql="SELECT 1",rows=1)' | sed -n 's/^Workflow \([^:]*\):.*/\1/p')"
check "workflow file exists" yes "$([ -f "$EXAKIT_HOME/workflows/$WF.jsonl" ] && echo yes || echo no)"
run list --json; check "JSON list exit" 0 "$CODE"
check "JSON list contents" "$WF|demo|2" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; r=json.load(sys.stdin)[0]; print("|".join(str(r[k]) for k in ("id","name","events")))')"
run show "$WF" --json; check "JSON show exit" 0 "$CODE"
check "event order" "start,sql" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(",".join(e["kind"] for e in json.load(sys.stdin)))')"
run show wf-20200101-abcdef; check "missing workflow exit" 1 "$CODE"
run show wf-20200101-abcdef --json; check "missing workflow JSON exit" 1 "$CODE"
check "missing workflow JSON is one object" no "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print("yes" if json.load(sys.stdin)["ok"] else "no")')"
run --help; check "help exit" 0 "$CODE"; contains "help describes workflow" "workflow" "$OUT"
contains "public entry routes to Python" '_exakit_marketplace_cli workflow_cli' "$(cat "$ROOT/setup/exakit")"
check "help metadata lists workflow" workflow "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(c["command"] for c in d["commands"] if c["command"]=="workflow"))' "$ROOT/setup/help/exakit.json")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
