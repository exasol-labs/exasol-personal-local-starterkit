#!/usr/bin/env bash
# notebook-separate-views.sh — JupyterLab and Marimo each show their own
# notebooks. JupyterLab is rooted at the notebooks folder, which also holds the
# Marimo copies (marimo/); its file browser hides that folder through the kit's
# settings file (--config, never the user's global Jupyter config). Marimo is
# rooted at marimo/ and so lists only Marimo notebooks.
#
#   bash tests/notebook-separate-views.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;; *) FAIL=$((FAIL + 1)); printf '  FAIL %s: [%s] not found\n' "$1" "$2" ;; esac; }

export HOME="$WORK/home" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
# shellcheck disable=SC1091
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/notebook.sh"
run_python_any() { python3 "$@"; }
EXAKIT_LOG_FILE="$WORK/log"; : > "$EXAKIT_LOG_FILE"
mkdir -p "$EXAKIT_NOTEBOOK_HOME"
manifest_init >/dev/null 2>&1

echo "JupyterLab hides the Marimo copies:"
cfg="$(_notebook_jupyter_config)"
check "the settings file lives in the kit's notebook folder" "$EXAKIT_NOTEBOOK_HOME/jupyter_server_config.json" "$cfg"
check "...and hides marimo/ beside Jupyter's own defaults" \
    '__pycache__ *.pyc *.pyo .DS_Store *~ .ipynb_checkpoints marimo' \
    "$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["ContentsManager"]["hide_globs"]))' "$cfg")"
# The start passes it with --config: a spawn stub records the command line.
notebook_find_jupyter() { printf 'kit %s\n' "$WORK/bin/jupyter-lab"; }
_notebook_api_answers() { return 1; }
_notebook_secret() { printf 'x'; }
_notebook_wait_up() { return 0; }
_notebook_spawn() { shift 3; printf '%s\n' "$@" > "$WORK/argv"; }
( notebook_server_start 28888 ) > "$WORK/start.out" 2>&1; echo "rc=$?" >> "$WORK/start.out"
check "the start itself goes through" "rc=0" "$(tail -n 1 "$WORK/start.out")"
has "the start reads it with --config" "--config=$EXAKIT_NOTEBOOK_HOME/jupyter_server_config.json" "$(cat "$WORK/argv")"
has "...rooted at the notebooks folder as before" "--ServerApp.root_dir=$EXAKIT_NOTEBOOK_DIR" "$(cat "$WORK/argv")"
has "the Windows twin passes the same file" '"--config=`"$(Write-NotebookJupyterConfig)`""' "$(cat "$ROOT/setup/lib/notebook.ps1")"
has "...with the same globs" '"hide_globs": ["__pycache__", "*.pyc", "*.pyo", ".DS_Store", "*~", ".ipynb_checkpoints", "marimo"]' \
    "$(sed -n '/^function Write-NotebookJupyterConfig/,/^}/p' "$ROOT/setup/lib/notebook.ps1")"

echo "Marimo is rooted at its own folder:"
has "marimo edit opens marimo/, not the notebooks folder" 'edit "$_nmt_dir"' "$(cat "$ROOT/setup/lib/notebook.sh")"
has "...where its folder is the marimo/ one" '_nmt_dir="$EXAKIT_NOTEBOOK_DIR/marimo"' "$(cat "$ROOT/setup/lib/notebook.sh")"

printf '\nnotebook-separate-views.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
