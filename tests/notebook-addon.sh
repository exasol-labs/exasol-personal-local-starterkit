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
echo "a full kit uninstall keeps your work (notebooks, MLflow runs, dashboards; audit DAY-01):"
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
    mkdir -p "$EXAKIT_HOME/mlflow/artifacts" "$EXAKIT_HOME/dash-server/instance/gitops-repo" "$EXAKIT_HOME/dash-server/venv"
    printf 'registry' > "$EXAKIT_HOME/mlflow/mlflow.db"
    printf 'board' > "$EXAKIT_HOME/dash-server/instance/gitops-repo/sales.json"
}
seed_kit
out="$(full_uninstall 1 2>&1)"
contains "the dry run names the work that stays" "your work stays in $EXAKIT_HOME: notebooks, MLflow runs and models, dashboards" "$out"
check "the dry run removes nothing" "yes" "$([ -f "$EXAKIT_HOME/manifest.json" ] && echo yes || echo no)"
out="$(full_uninstall 0 2>&1)"
contains "the real run says so" "your work was kept there (notebooks, MLflow runs and models, dashboards)" "$out"
check "the user's notebook and MLflow store are still there" "precious|runs" \
    "$(cat "$EXAKIT_NOTEBOOK_DIR/my-work/analysis.ipynb" 2>/dev/null)|$(cat "$EXAKIT_NOTEBOOK_DIR/my-work/mlflow/mlflow.db" 2>/dev/null)"
check "the kit's MLflow store and the dashboards are still there" "registry|board" \
    "$(cat "$EXAKIT_HOME/mlflow/mlflow.db" 2>/dev/null)|$(cat "$EXAKIT_HOME/dash-server/instance/gitops-repo/sales.json" 2>/dev/null)"
check "everything else in the kit home is gone" "dash-server mlflow notebooks" "$(ls -A "$EXAKIT_HOME" | sort | tr '\n' ' ' | sed 's/ $//')"
check "...and Dash Server keeps only its instance" "instance" "$(ls -A "$EXAKIT_HOME/dash-server" | tr '\n' ' ' | sed 's/ $//')"
out="$(full_uninstall 1 2>&1)"; rc=$?
check "a home holding only kept work is still a kit home to the guard" "0" "$rc"
seed_kit
out="$(EXAKIT_UNINSTALL_NOTEBOOKS=remove full_uninstall 1 2>&1)"
contains "EXAKIT_UNINSTALL_NOTEBOOKS=remove: the dry run says they go" "$EXAKIT_NOTEBOOK_DIR" "$out"
EXAKIT_UNINSTALL_NOTEBOOKS=remove full_uninstall 0 >/dev/null 2>&1
check "and the real run removes the whole kit home" "no" "$([ -e "$EXAKIT_HOME" ] && echo yes || echo no)"
mkdir -p "$EXAKIT_HOME"

echo "the install's closing screen says how to give the notebooks a model (before the panel, after the add-ons):"
hint() { ( exakit_marketplace_addon_installed() { [ "$1" = notebook ]; }; UI_FANCY=0 exakit_model_setup_hint 2>&1 ); }
HINT="$(hint)"
contains "the model id and the address" 'export EXAKIT_MODEL_ID="claude-opus-5-5"' "$HINT"
contains "the key through a hidden read, never a value" "read -rs EXAKIT_PROVIDER_API_KEY; export EXAKIT_PROVIDER_API_KEY" "$HINT"
contains "Langfuse the same way" "LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY" "$HINT"
contains "and the notebook command that shows it again" "nb.model_setup()" "$HINT"
check "no key value, no secret pattern" "" "$(printf '%s' "$HINT" | grep -E 'API_KEY=|SECRET_KEY=|sk-' || true)"
check "every line fits 80 columns" "" "$(printf '%s\n' "$HINT" | awk 'length > 80')"
check "silent when a model is already set" "" "$(EXAKIT_MODEL_ID=set hint)"
check "silent without the notebook add-on" "" "$( ( exakit_marketplace_addon_installed() { false; }; exakit_model_setup_hint 2>&1 ) )"
for _s in setup-macos.sh setup-linux.sh; do
    check "$_s prints it after the persona's add-ons and before the panel" "yes" \
        "$(awk '/_exakit_marketplace_cli installer_flow --phase services/{a=NR} /exakit_model_setup_hint/{if(!h)h=NR} /^connection_summary/{c=NR} END{print (a&&h&&c&&a<h&&h<c)?"yes":"no"}' "$ROOT/setup/$_s")"
done
check "the Windows installer too" "yes" \
    "$(awk '/installer_flow -AllowFailure/{a=NR} /Write-ExakitModelSetupHint/{if(!h)h=NR} /Show-ExakitConnectionSummary$/{c=NR} END{print (a&&h&&c&&a<h&&h<c)?"yes":"no"}' "$ROOT/setup/setup-windows.ps1")"
check "the PowerShell twin types the key hidden too" "yes" "$(grep -q 'Read-Host "Model API key" -AsSecureString' "$ROOT/setup/lib/exakit-common.ps1" && echo yes)"
if command -v pwsh >/dev/null 2>&1; then
    PS_HINT="$(cd "$ROOT" && HOME="$WORK/pshome" EXAKIT_HOME="$WORK/pskit" pwsh -NoProfile -Command '. ./setup/lib/ui.ps1; . ./setup/lib/exakit-common.ps1; function Test-ExakitMarketplaceAddonInstalled { param($Id) $Id -eq "notebook" }; $script:UiFancy = $false; Write-ExakitModelSetupHint' 2>&1)"
    contains "pwsh: the same panel, PowerShell lines" '$env:EXAKIT_MODEL_ID = "claude-opus-5-5"' "$PS_HINT"
    contains "pwsh: the key through a secure prompt" 'Read-Host "Model API key" -AsSecureString' "$PS_HINT"
    check "pwsh: no key value, no secret pattern" "" "$(printf '%s' "$PS_HINT" | grep -E 'API_KEY=|SECRET_KEY=|sk-' || true)"
    check "pwsh: every line fits 80 columns" "" "$(printf '%s\n' "$PS_HINT" | awk 'length > 80')"
else
    echo "  skip pwsh is not installed - the PowerShell panel is checked as text only"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
