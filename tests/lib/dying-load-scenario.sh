#!/usr/bin/env bash
# The standalone `exakit data-load` path, with a load that die()s half way.
#
# This is the shape that shipped broken: die() exits, so called straight from the
# menu it ended the command with the table still animating. The orphan animator's
# next frame moved the cursor up and cleared -- wiping the error message and
# repainting a table frozen at 99%. Driven by tests/lib/tty-replay.py under a
# real pty, which is the only way to see any of that.
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"

exakit_pending_datasets() {
    printf 'tpch|TPC-H retail benchmark\nenergy|Smart-meter energy readings\n'
}
manifest_get() { printf 'starter-kit\n'; }
exakit_repo_root() { printf '%s\n' "$ROOT"; }
exakit_note_failure() { :; }

# Stands in for the interactive menu: same table, same ticks, left on screen.
exakit_data_load_select() {
    EXAKIT_TABLE_STATE="$W/t"
    exakit_data_table_build "$EXAKIT_TABLE_STATE"
    ui_table_tick "$EXAKIT_TABLE_STATE" "$EXAKIT_TABLE_DEFAULTS"
    ui_table_render "$EXAKIT_TABLE_STATE" 0
    EXAKIT_DATA_LOAD_SELECTION="tpch,energy"
}

# tpch dies where the real one did: at the very end, counting rows. energy must
# still load afterwards, animated -- that is what proves the subshell's exit did
# not take this shell's animator with it.
exakit_load_dataset() {
    _row="$(exakit_data_table_row "$2")"
    ui_table_set "$EXAKIT_TABLE_STATE" "$_row" running 99 100 3 "$2 · counting rows"
    sleep 1
    if [ "$2" = tpch ]; then
        die "Row count mismatch in TPCH: expected 173,745 rows, found 0."
    fi
    ui_table_set "$EXAKIT_TABLE_STATE" "$_row" done "" "" "" "" \
        "completed · 2 tables, 108,050 rows  (1s)"
}

UI_TABLE_TITLE="Datasets to load"
exakit_data_load_menu
rm -rf "$W"
