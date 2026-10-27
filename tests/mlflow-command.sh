#!/usr/bin/env bash
# Isolated command smoke, with no server or database process.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME/user" EXAKIT_HOME="$TEST_HOME/kit"
mkdir -p "$HOME" "$EXAKIT_HOME"
. "$ROOT/setup/lib/common.sh"
. "$ROOT/setup/lib/notebook.sh"
. "$ROOT/setup/lib/mlflow.sh"
output="$(cmd_mlflow status --json)"
printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"] == "stopped" and d["remedy"] == "exakit mlflow start"'
[ ! -e "$EXAKIT_HOME/mlflow" ] || exit 1
output="$(cmd_mlflow url)"
[ -z "$output" ] || exit 1
output="$( (cmd_mlflow start) 2>&1)"; code=$?
[ "$code" -ne 0 ] && [[ "$output" == *"exakit marketplace udf-devkit"* ]] || exit 1
echo 'mlflow-command: status, URL and missing add-on refusal passed'
