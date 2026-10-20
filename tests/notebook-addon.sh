#!/usr/bin/env bash
# notebook-addon.sh — the notebook add-on's own behaviour in
# setup/lib/notebook.sh (the generic marketplace layer is tests/marketplace.sh).
#
#   bash tests/notebook-addon.sh
#
# What it pins:
#   - one uv resolution: the connector pinned with its extras, the companion
#     packages, and the two packages the kit carries (exakit_nb, exasol-mlflow)
#   - the kit's notebooks are copied once; one the user already has is never
#     overwritten
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

echo "notebooks are copied once, never over the user's:"
mkdir -p "$EXAKIT_NOTEBOOK_DIR"
printf 'mine' > "$EXAKIT_NOTEBOOK_DIR/start_here.ipynb"
added="$(notebook_copy_notebooks | tr '\n' ' ')"
shipped="$(cd "$ROOT/notebook/notebooks" && ls ./*.ipynb | sed 's|^\./||' | grep -v '^start_here.ipynb$' | tr '\n' ' ')"
check "what is missing comes" "$shipped" "$added"
check "the user's own stays" "mine" "$(cat "$EXAKIT_NOTEBOOK_DIR/start_here.ipynb")"
check "a second run adds nothing" "" "$(notebook_copy_notebooks)"

echo "exakit notebook refuses what it does not know:"
for args in "--frob" "--port" "--port abc" "--port 80"; do
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
check "the notebooks are still there" "mine" "$(cat "$EXAKIT_NOTEBOOK_DIR/start_here.ipynb")"

echo "the shipped files hold no address and no credential:"
found=""
for f in "$ROOT"/notebook/notebooks/* "$ROOT"/notebook/package/exakit_nb/*.py "$ROOT"/notebook/kit/*.py; do
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
