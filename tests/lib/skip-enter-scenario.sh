#!/usr/bin/env bash
# The sample-datasets question under a real pty (tests/lib/tty-replay.py types
# the keys): the pending datasets start ticked, the reader moves to Skip and
# presses Enter. The answer must be Skip ("none"), not the ticked datasets. It
# is the second data question - the source question before it is checked in
# tests/personas.sh - so it is asked here directly.
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"
EXAKIT_LOG_FILE="$W/log"; : > "$EXAKIT_LOG_FILE"
exakit_pending_datasets() {
    printf 'tpch|TPC-H retail benchmark\nenergy|Smart-meter energy readings\nweather|City weather daily history\n'
}
EXAKIT_DATA_LOAD_SELECTION=""
exakit_data_samples_select "Skip"
[ -n "$EXAKIT_DATA_LOAD_SELECTION" ] || EXAKIT_DATA_LOAD_SELECTION="none"
printf 'SELECTION=%s\n' "$EXAKIT_DATA_LOAD_SELECTION"
rm -rf "$W"
