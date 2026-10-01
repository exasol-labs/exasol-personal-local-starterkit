#!/usr/bin/env bash
# Driven by tests/lib/tty-replay.py under a real pty: the ADD-ONS table's whole
# life -- the state panel, the selection, and the install progress that fills the
# same rows in -- so the replay can assert what a terminal is actually left
# holding. The bug this shape exists to catch is the table STACKING: the frames
# are only ever wrong on a screen that can be wrong.
#
# Everything below the stubs is shipping code: _exakit_marketplace_apply and
# _exakit_marketplace_install_one drive the table, and only the add-on modules'
# own hooks are faked. Ids that are not registered add-ons on purpose -- this
# exercises the GENERIC path (_exakit_addon_fn resolves demo-alpha to
# demo_alpha_install), which is the only path a real add-on takes either.
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"

# Three add-ons: two that install, one that fails, so the warn a failure owes the
# reader is proved to land BELOW the finished table rather than inside the frame.
demo_alpha_install() { sleep 1; return 0; }
demo_alpha_summary() { printf 'dashboards at http://127.0.0.1:8000\n'; }
demo_beta_install()  { sleep 1; return 0; }
# Deliberately longer than the Status column: the cell has to give way, not the
# table's width.
demo_beta_summary()  { printf 'load JSON with: exasol-json-tables ingest --input <file.json>\n'; }
demo_gamma_install() { sleep 1; return 1; }

# The state table is printed BEFORE the selection and stays: it is a different,
# deliberate thing, and the live table has to overwrite its own frames and
# nothing above them.
printf '\n'
ui_panel_begin "Marketplace add-ons"
ui_panel_line "$(printf '%-14s %-14s %s' "Add-on" "Version" "Description")"
ui_panel_line "$(printf '%-14s %-14s %s' "demo-alpha" "1.0.0" "A demo dashboard server")"
ui_panel_line "$(printf '%-14s %-14s %s' "demo-beta" "2.0.0" "A demo JSON loader")"
ui_panel_line "$(printf '%-14s %-14s %s' "demo-gamma" "3.0.0" "A demo that fails")"
ui_panel_end
printf '\n'

EXAKIT_ADDON_TABLE_STATE="$W/addons"
_exakit_addon_table_build "$EXAKIT_ADDON_TABLE_STATE" demo-alpha demo-beta demo-gamma
UI_TABLE_TITLE="Add-ons to install"
UI_TABLE_COL1="Add-on"          # what exakit_marketplace_menu sets, so the
                                # scenario shows the heading a user gets
ui_table_tick "$EXAKIT_ADDON_TABLE_STATE" "$EXAKIT_TABLE_DEFAULTS"
# The selection phase leaves its table drawn, exactly as ui_table_menu does --
# and the first progress frame has to overwrite THAT, not print a second one
# underneath it.
ui_table_render "$EXAKIT_ADDON_TABLE_STATE" 0
_exakit_marketplace_apply "demo-alpha,demo-beta,demo-gamma"
rm -rf "$W"
