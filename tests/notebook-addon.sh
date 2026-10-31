#!/usr/bin/env bash
# Full-kit removal preserves notebooks unless the user explicitly removes them.
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
export EXAKIT_EXAPUMP_CONFIG_DIR="$WORK/home/.exapump"
unset EXAKIT_NOTEBOOK_VENV EXAKIT_NOTEBOOK_HOME EXAKIT_UNINSTALL_NOTEBOOKS
export EXAKIT_NOTEBOOK_DIR="$EXAKIT_HOME/notebooks"
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"
. "$ROOT/setup/lib/common.sh"
run_python_any() { python3 "$@"; }
EXAKIT_MARKETPLACE_PYTHON_HOOKS=1 _exakit_marketplace_python_hooks
EXAKIT_LOG_FILE="$WORK/log"
: > "$EXAKIT_LOG_FILE"
echo "a full kit uninstall keeps the notebooks:"
full_uninstall() { # full_uninstall <dry> — the real engine with the externals stubbed
    ( exakit_service_ids() { :; }; exakit_mcp_operation() { :; }; exakit_mcp_clients_from_args() { :; }
      _exakit_remove_installed_skills() { :; }; exakit_marketplace_installed_addons() { echo notebook; }
      exakit_marketplace_addons() { echo "notebook|x"; }
      exakit_uninstall_run "$1" )
}
seed_kit() {
    manifest_init >/dev/null 2>&1
    manifest_set components.notebook.version 3.1.0
    exakit_record_ownership notebook kit
    mkdir -p "$EXAKIT_NOTEBOOK_DIR/my-work/mlflow" "$EXAKIT_HOME/logs" "$EXAKIT_HOME/pyexasol-venv"
    printf 'precious' > "$EXAKIT_NOTEBOOK_DIR/my-work/analysis.ipynb"
    printf 'runs' > "$EXAKIT_NOTEBOOK_DIR/my-work/mlflow/mlflow.db"
}
seed_kit
out="$(full_uninstall 1 2>&1)"
contains "the dry run says the notebooks stay" "your notebooks stay in $EXAKIT_HOME/notebooks" "$out"
check "the dry run removes nothing" "yes" "$([ -f "$EXAKIT_HOME/manifest.json" ] && echo yes || echo no)"
out="$(full_uninstall 0 2>&1)"
contains "the real run says so" "your notebooks were kept in $EXAKIT_HOME/notebooks" "$out"
check "the user's notebook and MLflow store are still there" "precious|runs" \
    "$(cat "$EXAKIT_NOTEBOOK_DIR/my-work/analysis.ipynb" 2>/dev/null)|$(cat "$EXAKIT_NOTEBOOK_DIR/my-work/mlflow/mlflow.db" 2>/dev/null)"
check "everything else in the kit home is gone" "notebooks" "$(ls -A "$EXAKIT_HOME" | tr '\n' ' ' | sed 's/ $//')"
out="$(full_uninstall 1 2>&1)"; rc=$?
check "a home holding only kept notebooks is still a kit home to the guard" "0" "$rc"
seed_kit
out="$(EXAKIT_UNINSTALL_NOTEBOOKS=remove full_uninstall 1 2>&1)"
contains "EXAKIT_UNINSTALL_NOTEBOOKS=remove: the dry run says they go" "$EXAKIT_NOTEBOOK_DIR" "$out"
EXAKIT_UNINSTALL_NOTEBOOKS=remove full_uninstall 0 >/dev/null 2>&1
check "and the real run removes the whole kit home" "no" "$([ -e "$EXAKIT_HOME" ] && echo yes || echo no)"
mkdir -p "$EXAKIT_HOME"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
