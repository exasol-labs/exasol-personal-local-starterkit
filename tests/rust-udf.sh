#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export EXAKIT_HOME="$WORK/home"
mkdir -p "$EXAKIT_HOME"
udf_devkit_installed_version() { echo 0.1.0; }
pyexasol_venv_python() { command -v python3; }
exakit_repo_root() { echo "$ROOT"; }
manifest_get() { :; }
reject() { echo "$*" >&2; exit 2; }
. "$ROOT/setup/lib/rust-udf.sh"
result="$(cmd_rust_udf new score_model --json)"
printf '%s' "$result" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] and d["features"]==["VALUE_"]'
test -f "$EXAKIT_HOME/rust-udfs/score_model/src/lib.rs"
printf 'rust-udf shell wrapper: OK\n'
