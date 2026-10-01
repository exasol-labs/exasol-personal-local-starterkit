#!/usr/bin/env bash
# A step spinner is STILL RUNNING when the table starts -- which is what happens
# during an install, and what produced several table top borders side by side on
# one line at differing widths.
#
# Two things went wrong together: ui_table_begin overwrote _UI_SPIN_PID and left
# the spinner an orphan, and the orphan kept printing a line with no trailing
# newline. Cursor-up preserves the column, so every frame after that drew from
# wherever the spinner had left the cursor.
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"
exakit_pending_datasets() {
    printf 'tpch|TPC-H retail benchmark\nenergy|Smart-meter energy readings\nweather|City weather daily history\n'
}
UI_TABLE_TITLE="Datasets to load"; S="$W/t"
exakit_data_table_build "$S"; ui_table_tick "$S" "$EXAKIT_TABLE_DEFAULTS"
ui_table_render "$S" 0

# The step is narrating when the loads begin. Its line is ~44 columns and ends
# without a newline, which is the whole point.
ui_spin_begin "Confirming the database can persist schema changes"
sleep 1
ui_table_begin "$S" || exit 0
ui_table_set "$S" 2 running 20 83 6 "tpch · loading 8 data files"; sleep 1
ui_table_set "$S" 2 done "" "" "" "" "completed · 8 tables, 173,745 rows  (3s)"
ui_table_set "$S" 3 running 24 100 4 "energy · loading 1 data file"; sleep 1
ui_table_set "$S" 3 done "" "" "" "" "completed · 2 tables, 108,050 rows  (1s)"
ui_table_set "$S" 4 done "" "" "" "" "completed · 2 tables,  10,970 rows  (1s)"
sleep 1
ui_table_end "$S"
rm -rf "$W"
