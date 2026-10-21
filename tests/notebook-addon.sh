#!/usr/bin/env bash
# notebook-addon.sh — the notebook add-on's own behaviour in
# setup/lib/notebook.sh (the generic marketplace layer is tests/marketplace.sh).
#
#   bash tests/notebook-addon.sh
#
# What it pins:
#   - one uv resolution: the connector pinned with its extras, the companion
#     packages, and the two packages the kit carries (exakit_nb, exasol-mlflow)
#   - the kit's notebooks are copied once into their persona folders (Jupyter
#     and Marimo); one the user already has is never overwritten
#   - the notebook tools are one checklist, all three ticked; the variables
#     answer it; Positron is configured (settings kept, bad JSON left alone)
#   - `exakit notebook` refuses an unknown option and a bad --port, and says so
#     before touching anything when the add-on is not installed
#   - an uninstall keeps the user's notebooks, and its dry run says so
#   - the shipped notebooks, helpers and kit scripts name no address and no
#     credential, the scripts compile, and each .ipynb is built from its .py
#
# A sandboxed kit home; no database, no network, no real venv.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

export HOME="$WORK/home" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
# shellcheck disable=SC1091
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/notebook.sh"
EXAKIT_LOG_FILE="$WORK/log"; : > "$EXAKIT_LOG_FILE"

echo "the install is one pinned resolution:"
EXAKIT_NOTEBOOK_VERSION="3.1.0"
specs="$(_notebook_specs)"
check "the connector, pinned, with its extras" "exasol-notebook-connector[bucketfs,ibis,pyexasol,sqlalchemy]==3.1.0" "$(printf '%s\n' "$specs" | head -1)"
contains "the kernel package" "ipykernel>=6.29,<8" "$specs"
contains "the client model library" "scikit-learn>=1.4,<2" "$specs"
contains "the MLflow client, not the server" "mlflow-skinny>=2.14,<4" "$specs"
check "the kit's helper package" "$ROOT/notebook/package" "$(printf '%s\n' "$specs" | tail -2 | head -1)"
check "the kit's MLflow client package" "$ROOT/packages/exasol-mlflow" "$(printf '%s\n' "$specs" | tail -1)"
check "JupyterLab is not in it" "" "$(printf '%s\n' "$specs" | grep -i jupyterlab || true)"

echo "notebooks are copied once, into persona folders, never over the user's:"
NB="$EXAKIT_NOTEBOOK_DIR/starter-kit-notebooks"
mkdir -p "$NB/general"
printf 'mine' > "$NB/general/start_here.ipynb"
added="$(notebook_copy_notebooks | tr '\n' ' ')"
check "what is missing comes, each in its persona's folder" \
    "data-scientist/explore.ipynb data-scientist/text_classification.ipynb ml-engineer/bank_marketing_mlflow.ipynb ml-engineer/train.ipynb " "$added"
check "the user's own stays" "mine" "$(cat "$NB/general/start_here.ipynb")"
check "a second run adds nothing" "" "$(notebook_copy_notebooks)"
contains "a README names the end-to-end path" "4. \`ml-engineer/bank_marketing_mlflow.ipynb\` (ML Engineer)" "$(cat "$NB/README.md")"
check "every catalog entry ships its notebook" "" \
    "$(python3 "$ROOT/notebook/kit/notebooks.py" list "$ROOT" | while IFS='|' read -r _ _ _ j m; do
        [ -z "$j" ] || [ -f "$ROOT/notebook/notebooks/$j" ] || printf ' %s' "$j"
        [ -z "$m" ] || [ -f "$ROOT/notebook/marimo/$m" ] || printf ' %s' "$m"; done)"
check "the Marimo ones go to marimo/<persona>/, no README" \
    "data-scientist/explore.py data-scientist/text_classification.py ml-engineer/bank_marketing_mlflow.py ml-engineer/train.py |no" \
    "$(notebook_copy_notebooks marimo | tr '\n' ' ')|$([ -e "$EXAKIT_NOTEBOOK_DIR/marimo/README.md" ] && echo yes || echo no)"

echo "the notebook tools: one checklist, all three ticked:"
check "without a terminal the ticks stand" "jupyterlab,marimo,positron" \
    "$( (unset EXAKIT_NOTEBOOK_FRONTENDS EXAKIT_NOTEBOOK_JUPYTER EXAKIT_NOTEBOOK_MARIMO; notebook_choose_front_ends >/dev/null 2>&1 </dev/null; printf '%s' "$NOTEBOOK_FRONT_ENDS") )"
check "EXAKIT_NOTEBOOK_MARIMO=skip leaves Marimo out" "jupyterlab,positron" \
    "$( (unset EXAKIT_NOTEBOOK_FRONTENDS; EXAKIT_NOTEBOOK_MARIMO=skip; notebook_choose_front_ends >/dev/null 2>&1 </dev/null; printf '%s' "$NOTEBOOK_FRONT_ENDS") )"
check "EXAKIT_NOTEBOOK_FRONTENDS answers it" "marimo,positron" \
    "$( (EXAKIT_NOTEBOOK_FRONTENDS="Marimo, positron"; notebook_choose_front_ends; printf '%s' "$NOTEBOOK_FRONT_ENDS") )"
check "Marimo's pin is the one notebook/catalog.json converts with" "$EXAKIT_NOTEBOOK_MARIMO_PACKAGE" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["marimo_package"])' "$ROOT/notebook/catalog.json")"

echo "Positron is configured, never installed:"
mkdir -p "$EXAKIT_NOTEBOOK_DIR/.vscode"
printf '{"editor.fontSize": 14}' > "$EXAKIT_NOTEBOOK_DIR/.vscode/settings.json"
notebook_prepare_positron
settings="$(cat "$EXAKIT_NOTEBOOK_DIR/.vscode/settings.json")"
contains "the folder names the kit's Python" "\"python.defaultInterpreterPath\": \"$(notebook_venv_python)\"" "$settings"
contains "the user's own settings stay" '"editor.fontSize": 14' "$settings"
printf '{not json' > "$EXAKIT_NOTEBOOK_DIR/.vscode/settings.json"
check "a file that is not JSON is left alone" "1|{not json" \
    "$(notebook_prepare_positron && echo 0 || echo 1)|$(cat "$EXAKIT_NOTEBOOK_DIR/.vscode/settings.json")"
check "no positron and no app: none found" "1" "$( (PATH=/usr/bin:/bin; HOME="$WORK/nohome"; notebook_find_positron >/dev/null && echo 0 || echo 1) )"

echo "exakit notebook refuses what it does not know:"
for args in "--frob" "--port" "--port abc" "--port 80" "--marimo --positron"; do
    # shellcheck disable=SC2086
    out="$( (notebook_cmd $args) 2>&1)"; rc=$?
    check "refuses: $args" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
done
out="$( (notebook_cmd --check) 2>&1)"
contains "not installed names the marketplace" "exakit marketplace notebook" "$out"

echo "an uninstall keeps the notebooks:"
out="$(notebook_uninstall 1 2>&1)"
contains "the dry run says so" "your notebooks stay in $EXAKIT_NOTEBOOK_DIR" "$out"
notebook_uninstall >/dev/null 2>&1
check "the notebooks are still there" "mine" "$(cat "$NB/general/start_here.ipynb")"

echo "the shipped files hold no address and no credential:"
found=""
for f in "$ROOT"/notebook/notebooks/* "$ROOT"/notebook/marimo/* "$ROOT"/notebook/package/exakit_nb/*.py "$ROOT"/notebook/kit/*.py; do
    for needle in 127.0.0.1 localhost :8563 'password=' 'dsn='; do
        grep -qF -- "$needle" "$f" && found="$found $(basename "$f"):$needle"
    done
done
check "no address or credential" "" "$found"

if command -v python3 >/dev/null 2>&1; then
    check "the kit scripts compile" "ok" "$(python3 -m py_compile "$ROOT"/notebook/kit/*.py && echo ok)"
    check "each .ipynb is built from its .py" "ok" "$(python3 "$ROOT/tools/notebooks.py" --check && echo ok)"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
