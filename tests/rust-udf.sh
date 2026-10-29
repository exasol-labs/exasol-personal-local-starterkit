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
# A missing shared bucket must reach the Python fallback with launcher and
# deployment paths; the wrapper must not refuse it or leak process env changes.
cat > "$WORK/python-probe" <<'PROBE'
#!/bin/sh
test "$EXAKIT_RUST_BUCKET_DIR" = "" || exit 1
test "$EXAKIT_RUST_UDF_ROOT" = "" || exit 1
test "$EXAKIT_RUST_LAUNCHER" = "$EXAKIT_HOME/launcher" || exit 1
test "$EXAKIT_RUST_DEPLOYMENT" = "$EXAKIT_HOME/deployment" || exit 1
test "$2 $3 $4 $5" = "deploy score_model --yes --json" || exit 1
printf '{"ok":true}\n'
PROBE
chmod +x "$WORK/python-probe"
pyexasol_venv_python() { echo "$WORK/python-probe"; }
udf_bucket_locate() { return 1; }
personal_cli() { echo "$EXAKIT_HOME/launcher"; }
export EXAKIT_PERSONAL_DEPLOY_DIR="$EXAKIT_HOME/deployment"
export EXAKIT_RUST_LAUNCHER=original
result="$(cmd_rust_udf deploy score_model --yes --json)"
test "$result" = '{"ok":true}'
test "$EXAKIT_RUST_LAUNCHER" = original
printf 'rust-udf shell wrapper: OK\n'
