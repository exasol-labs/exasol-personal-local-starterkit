#!/usr/bin/env bash
# The data question ("Data to load") under a real pty (tests/lib/tty-replay.py
# types the keys). It is ONE table: the "Sample datasets" parent with the
# pending datasets under it, your own file or folder, an external source
# (disabled with its reason, or pickable with DQ_VS=1) and Skip. The answer
# lands on one line, SELECTION=, for tests/data-question.sh.
#
#   DQ_SCENE=source    the whole data question (exakit_data_load_select)
#   DQ_SCENE=yesno     a two-row either/or checkbox menu (Yes / No, No exclusive)
#   DQ_SCENE=offer     the installer's data step (exakit_maybe_offer_data_load):
#                      the question, then what was picked, in the table's order.
#                      The datasets and the file are stubs that say LOAD/FILE;
#                      the external row runs the real exakit_vs_connect_wizard
#                      from a copy of virtual-schemas.sh whose `exakit` beside
#                      it is a stub that says STUB and exits DQ_STUB_RC (0)
#   DQ_PENDING=none    every sample is loaded already (nothing pending)
#   DQ_PERSONA=1       the persona service names who each dataset is for
#   DQ_VS=1            the virtual-schema module is loaded and the kit's
#                      pyexasol is there, so the external row can be picked
#   EXAKIT_DATASETS_PRESELECT passes through, as the persona flow sets it
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"
[ "${DQ_PERSONA:-0}" = 1 ] && . "$ROOT/setup/lib/persona.sh"
if [ "${DQ_VS:-0}" = 1 ] || [ "${DQ_SCENE:-}" = offer ]; then
    _dq_vs="$ROOT/setup/lib/virtual-schemas.sh"
    if [ "${DQ_SCENE:-}" = offer ]; then
        # The installer's library layout: setup/lib/ and the command beside it.
        mkdir -p "$W/kitcopy/setup/lib"
        cp "$_dq_vs" "$W/kitcopy/setup/lib/"
        printf '#!/bin/sh\nprintf "STUB exakit %%s\\n" "$*"\nexit %s\n' "${DQ_STUB_RC:-0}" > "$W/kitcopy/setup/exakit"
        _dq_vs="$W/kitcopy/setup/lib/virtual-schemas.sh"
    fi
    . "$_dq_vs"
    pyexasol_venv_python() { printf '/bin/sh\n'; }
fi
# Never a managed-Python download from a test.
run_python_any() { python3 "$@"; }
EXAKIT_LOG_FILE="$W/log"; : > "$EXAKIT_LOG_FILE"
exakit_pending_datasets() {
    [ "${DQ_PENDING:-}" = none ] && return 0
    printf 'tpch|TPC-H retail benchmark\nenergy|Smart-meter energy readings\namazon_sales|Amazon sales (Amazon.in fashion orders, Apr-Jun 2022, ~129k lines)\n'
}
case "${DQ_SCENE:-source}" in
    yesno)
        EXAKIT_CHECKBOX_EXCLUSIVE=2
        ui_checkbox_menu "Explore marketplace ?" "1" "Yes" "No"
        printf 'SELECTION=%s\n' "$EXAKIT_CHECKBOX_SELECTION"
        ;;
    offer)
        exakit_load_dataset() { printf 'LOAD %s\n' "$2"; }
        exakit_load_local_file() { printf 'FILE\n'; }
        exakit_maybe_offer_data_load "$ROOT"
        printf 'RC=%s SELECTION=%s\n' "$?" "$EXAKIT_DATA_LOAD_SELECTION"
        ;;
    *)
        exakit_data_load_select "Skip"
        printf 'SELECTION=%s\n' "$EXAKIT_DATA_LOAD_SELECTION"
        ;;
esac
rm -rf "$W"
