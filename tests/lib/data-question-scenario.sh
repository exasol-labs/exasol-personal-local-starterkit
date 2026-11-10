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
#   DQ_SCENE=install   the installer's data step as an interactive install
#                      reaches it: the real exakit_persona_flow (only its Python
#                      controller is a stand-in, answering "data"), the real
#                      table, and for the external row the real
#                      exakit_vs_connect_wizard starting the real setup/exakit
#                      connect, whose menu comes from the real engine's catalog.
#                      The datasets and the file are stubs that say LOAD/FILE.
#                      DQ_STDIN=pipe gives the step a pipe on stdin, as
#                      `curl ... | sh` gives a setup script nobody re-pointed
#                      at the terminal; without it stdin is the terminal, as
#                      install.sh's own `< /dev/tty` gives setup
#   DQ_SCENE=persona-stdin  the real exakit_persona_flow, its controller
#                      answering "question" and then "data": what stdin the
#                      persona question and the data step get
#   DQ_PENDING=none    every sample is loaded already (nothing pending)
#   DQ_PERSONA=1       the persona service names who each dataset is for
#   DQ_VS=1            the virtual-schema module is loaded and the kit's
#                      pyexasol is there, so the external row can be picked
#   EXAKIT_DATASETS_PRESELECT passes through, as the persona flow sets it
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
# The install scene's child is the real `exakit`: it finds this kit home, never
# the one in the real HOME.
export EXAKIT_HOME EXAKIT_BIN_DIR
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"
[ "${DQ_PERSONA:-0}" = 1 ] && . "$ROOT/setup/lib/persona.sh"
case "${DQ_SCENE:-}" in
    install|persona-stdin)
        . "$ROOT/setup/lib/persona.sh"
        # The persona service's answer: offer the data. What it runs is real.
        _exakit_marketplace_cli() { printf 'data||\n'; } ;;
esac
if [ "${DQ_SCENE:-}" = install ]; then
    # A kit home the real `exakit connect` accepts: an install record with a
    # runtime, and the kit's pyexasol (here, this python3). The menu is the
    # engine's catalog, which needs no database.
    mkdir -p "$EXAKIT_HOME/pyexasol-venv/bin"
    ln -s "$(command -v python3)" "$EXAKIT_HOME/pyexasol-venv/bin/python"
    printf '{"runtime": {"type": "personal", "dsn": "127.0.0.1:8563", "user": "sys"}}\n' > "$EXAKIT_HOME/manifest.json"
    . "$ROOT/setup/lib/virtual-schemas.sh"
    pyexasol_venv_python() { printf '%s\n' "$EXAKIT_HOME/pyexasol-venv/bin/python"; }
fi
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
    install)
        exakit_load_dataset() { printf 'LOAD %s\n' "$2"; }
        exakit_load_local_file() { printf 'FILE\n'; }
        if [ "${DQ_STDIN:-}" = pipe ]; then
            # A pipe on stdin, in this shell (a `|` would run the step in a
            # subshell and lose its answer).
            exakit_persona_flow "$ROOT" < <(:)
        else
            exakit_persona_flow "$ROOT"
        fi
        printf 'RC=%s SELECTION=%s\n' "$?" "$EXAKIT_DATA_LOAD_SELECTION"
        ;;
    persona-stdin)
        _exakit_marketplace_cli() {
            case " $* " in *" --phase selected "*) printf 'data||\n' ;; *) printf 'question||\n' ;; esac
        }
        exakit_persona_question() {
            _dq_in=no; [ -t 0 ] && _dq_in=yes
            printf 'QUESTION STDIN TERMINAL=%s\n' "$_dq_in"
        }
        exakit_persona_data() {
            _dq_in=no; [ -t 0 ] && _dq_in=yes
            printf 'DATA STEP STDIN TERMINAL=%s\n' "$_dq_in"
        }
        _dq_in=no; [ -t 0 ] && _dq_in=yes
        printf 'SETUP STDIN TERMINAL=%s\n' "$_dq_in"
        exakit_persona_flow "$ROOT"
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
