#!/usr/bin/env bash
# The data question ("Data to load") under a real pty (tests/lib/tty-replay.py
# types the keys). It is ONE table: the "Sample datasets" parent with the
# pending datasets under it, your own file or folder, an external source (shown
# disabled, coming soon) and Skip. The answer lands on one line, SELECTION=,
# for tests/data-question.sh.
#
#   DQ_SCENE=source    the whole data question (exakit_data_load_select)
#   DQ_SCENE=yesno     a two-row either/or checkbox menu (Yes / No, No exclusive)
#   DQ_PENDING=none    every sample is loaded already (nothing pending)
#   DQ_PERSONA=1       the persona service names who each dataset is for
#   EXAKIT_DATASETS_PRESELECT passes through, as the persona flow sets it
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"
[ "${DQ_PERSONA:-0}" = 1 ] && . "$ROOT/setup/lib/persona.sh"
# Never a managed-Python download from a test.
run_python_any() { python3 "$@"; }
EXAKIT_LOG_FILE="$W/log"; : > "$EXAKIT_LOG_FILE"
exakit_pending_datasets() {
    [ "${DQ_PENDING:-}" = none ] && return 0
    printf 'tpch|TPC-H retail benchmark\nenergy|Smart-meter energy readings\nbanking_complaints|Banking complaints (CFPB, ~7k complaints)\n'
}
case "${DQ_SCENE:-source}" in
    yesno)
        EXAKIT_CHECKBOX_EXCLUSIVE=2
        ui_checkbox_menu "Explore marketplace ?" "1" "Yes" "No"
        printf 'SELECTION=%s\n' "$EXAKIT_CHECKBOX_SELECTION"
        ;;
    *)
        exakit_data_load_select "Skip"
        printf 'SELECTION=%s\n' "$EXAKIT_DATA_LOAD_SELECTION"
        ;;
esac
rm -rf "$W"
