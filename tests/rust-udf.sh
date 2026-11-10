#!/usr/bin/env bash
# The public Rust UDF command reaches its single Python implementation.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$WORK/uv-cache}" EXAKIT_VERSION_POLICY=pinned
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"

OUT="$(bash "$ROOT/setup/exakit" rust-udf build score_model --json 2>/dev/null)"; code=$?
[ "$code" -eq 4 ] || { echo "missing UDF devkit should exit 4, got $code"; exit 1; }
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d["ok"] and d["remedy"]=="exakit marketplace udf-devkit"'

printf '{"components":{"udf_devkit":{"version":"0.1.0"}}}\n' > "$EXAKIT_HOME/manifest.json"
OUT="$(bash "$ROOT/setup/exakit" rust-udf new score_model --json 2>/dev/null)"; code=$?
[ "$code" -eq 0 ] || { echo "rust-udf new failed: $OUT"; exit 1; }
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] and d["features"]==["VALUE_"]'
test -f "$EXAKIT_HOME/rust-udfs/score_model/src/lib.rs"
test -f "$EXAKIT_HOME/rust-udfs/score_model/Cargo.toml"
printf 'rust-udf public Bash CLI: OK\n'
