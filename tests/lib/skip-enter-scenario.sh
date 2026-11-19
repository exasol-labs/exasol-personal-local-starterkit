#!/usr/bin/env bash
# The data question ("Data to load", one table) under a real pty
# (tests/lib/tty-replay.py types the keys): the pending datasets start ticked,
# the reader moves to Skip and presses Enter. The answer must be Skip ("none"),
# not the ticked datasets. Rows: the "Sample datasets" parent, three datasets,
# your own file, an external source (disabled - the cursor steps over it), Skip.
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"
EXAKIT_LOG_FILE="$W/log"; : > "$EXAKIT_LOG_FILE"
exakit_pending_datasets() {
    printf 'tpch|TPC-H retail benchmark\nenergy|Smart-meter energy readings\nweather|City weather daily history\n'
}
exakit_data_load_select "Skip"
printf 'SELECTION=%s\n' "$EXAKIT_DATA_LOAD_SELECTION"
rm -rf "$W"
