#!/usr/bin/env bash
# Render worker events through the shipping fallback table adapter.
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
printf '{}\n' > "$EXAKIT_HOME/manifest.json"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"
. "$ROOT/tests/lib/mock-addon-events.sh"

demo_alpha_questions() {
    ui_checkbox_menu "Demo tools - untick any you do not want" "1,2" "Tool one" "Tool two"
    DEMO_ALPHA_ANSWER="${EXAKIT_CHECKBOX_SELECTION:-}"
    export DEMO_ALPHA_ANSWER
}
demo_alpha_install() { sleep 1; printf 'ANSWER=%s\n' "${DEMO_ALPHA_ANSWER:-unasked}" > "$W/answer"; return 0; }
demo_beta_install()  { sleep 1; return 0; }

EXAKIT_ADDON_TABLE_STATE="$W/addons"
_exakit_addon_table_build "$EXAKIT_ADDON_TABLE_STATE" demo-alpha demo-beta
UI_TABLE_TITLE="Add-ons to install"
UI_TABLE_COL1="Add-on"
ui_table_tick "$EXAKIT_ADDON_TABLE_STATE" "$EXAKIT_TABLE_DEFAULTS"
# The selection phase leaves its table drawn, as ui_table_menu does.
ui_table_render "$EXAKIT_ADDON_TABLE_STATE" 0
_exakit_marketplace_apply "demo-alpha,demo-beta"
cat "$W/answer"
rm -rf "$W"
