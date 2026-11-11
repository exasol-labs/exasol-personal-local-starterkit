#!/usr/bin/env bash
# data-question.sh — the data question and `exakit data-load`'s arguments.
#
#   bash tests/data-question.sh
#
# What it pins:
#   - the data question is ONE table, "Data to load": the "Sample datasets"
#     parent with the pending datasets under it, your own file or folder, an
#     external source (pickable where virtual schemas can run, else disabled
#     with the reason) and Skip - drawn once
#   - under a real pty: Enter keeps what is ticked, Enter on Skip answers none,
#     Up past the first row wraps to Skip, the cursor steps over the disabled
#     external row, ticking the file row with the samples answers "<ids>,local",
#     ticking the parent ticks every dataset; Enter on the exclusive row of ANY
#     checkbox menu answers that row alone; with virtual schemas available the
#     external row is picked like any other
#   - the external row runs `exakit connect` (the real wizard entry point, a
#     stub command): after the file, in both entry points; a connect that
#     failed or was cancelled is said and the load carries on; without a
#     person at the table it is only ever the command to run
#   - with every sample in, the parent is a disabled row that says so and your
#     own file is the default
#   - a persona's datasets are the rows ticked (the parent only when they are
#     every one); a persona that wants none, or only ones already loaded, makes
#     Skip the default (Enter never does nothing)
#   - who each dataset is for is a "For" column, so a name is never cut off at
#     80 columns
#   - data-load [--force] [<file-or-folder>|<dataset>] in either order; an id
#     on the command line wins over EXAKIT_DATA_FILE / EXAKIT_DATASETS
#
# The Windows twin is tests/data-question-ps.ps1. A sandboxed kit home; nothing
# is installed or loaded.


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
has() { # has <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}
lacks() { # lacks <label> <needle> <haystack>
    case "$3" in
        *"$2"*) FAIL=$((FAIL + 1)); printf '  FAIL %s: did not expect "%s" in [%s]\n' "$1" "$2" "$3" ;;
        *)      PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
    esac
}

export HOME="$WORK/home" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
unset EXAKIT_DATASETS EXAKIT_DATA_FILE EXAKIT_DATASETS_PRESELECT EXAKIT_LOAD_SAMPLE
# shellcheck disable=SC1091
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"; . "$ROOT/setup/lib/persona.sh"
# Never a managed-Python download from a test.
run_python_any() { python3 "$@"; }
EXAKIT_LOG_FILE="$WORK/log"; : > "$EXAKIT_LOG_FILE"
manifest_init >/dev/null 2>&1

replay() { # replay <keys> [VAR=value ...] — the scenario's final screen and answer
    _rp_keys="$1"; shift
    env "$@" python3 "$ROOT/tests/lib/tty-replay.py" "$ROOT/tests/lib/data-question-scenario.sh" "$ROOT" \
        "Data to load" "$_rp_keys" 2>&1
}

# The scenario's rows, with tpch, energy and amazon_sales still to load:
#   1 Sample datasets (parent)  2 tpch  3 energy  4 amazon_sales
#   5 Your file or folder       6 Connect an external source (disabled)  7 Skip
# The cursor starts on row 2, past the parent.
echo "one table answers the data question (a real pty):"
if command -v python3 >/dev/null 2>&1; then
    out="$(replay '\r')"
    has "Enter keeps what is ticked: every pending dataset" "SELECTION=tpch,energy,amazon_sales" "$out"
    has "the table draws once, and nothing else is boxed" "1 top borders, 1 bottom borders" "$out"
    check "...one box on the final screen" "1" "$(printf '%s\n' "$out" | sed -n '/=== FINAL SCREEN ===/,/^SELECTION=/p' | grep -c '╭')"
    has "the parent row is Sample datasets" "Sample datasets" "$out"
    lacks "...and the old source question is gone" "ready to load, picked next" "$out"
    out="$(replay 'jjjj\r')"
    has "Down steps over the disabled external row onto Skip, and Enter skips" "SELECTION=none" "$out"
    out="$(replay 'kk\r')"
    has "Up from the first row wraps to Skip, and Enter skips" "SELECTION=none" "$out"
    out="$(replay 'jjj\r')"
    has "Enter on the unticked file row confirms what is ticked" "SELECTION=tpch,energy,amazon_sales" "$out"
    out="$(replay 'jjj \r')"
    has "the file row picked with the samples: <ids>,local" "SELECTION=tpch,energy,amazon_sales,local" "$out"
    out="$(replay ' \r')"
    has "unticking one dataset releases the parent, the rest still load" "SELECTION=energy,amazon_sales" "$out"
    out="$(replay 'j\r' DQ_SCENE=yesno)"
    has "an either/or menu: Enter on No is No" "SELECTION=2" "$out"
    out="$(replay '\r' DQ_SCENE=yesno)"
    has "...and Enter on Yes is still Yes" "SELECTION=1" "$out"

    echo "every sample loaded already:"
    out="$(replay '\r' DQ_PENDING=none)"
    has "the cursor waits on your own file, ticked: Enter answers local" "SELECTION=local" "$out"
    has "the parent says why it cannot be picked" "Sample datasets - all" "$out"
    out="$(replay 'k\r' DQ_PENDING=none)"
    has "Up steps over the disabled parent and wraps to Skip" "SELECTION=none" "$out"

    echo "a persona's datasets: Skip when none of them is still to load:"
    out="$(replay '\r' EXAKIT_DATASETS_PRESELECT=none)"
    has "persona datasets none: Enter skips" "SELECTION=none" "$out"
    out="$(replay '\r' EXAKIT_DATASETS_PRESELECT=fraud_transactions)"
    has "persona datasets all loaded already: Enter skips" "SELECTION=none" "$out"  # fraud_transactions is not pending here
    out="$(replay '\r' EXAKIT_DATASETS_PRESELECT=energy)"
    has "persona datasets still to load: Enter loads exactly those" "SELECTION=energy" "$out"
    out="$(replay ' \r' EXAKIT_DATASETS_PRESELECT=none)"
    has "...and with none wanted, a sample can still be picked" "SELECTION=tpch" "$out"
    out="$(replay 'k \r' EXAKIT_DATASETS_PRESELECT=energy)"
    has "ticking the parent ticks every dataset" "SELECTION=tpch,energy,amazon_sales" "$out"

    echo "what each dataset is, whole, at 80 columns:"
    out="$(TTY_REPLAY_COLS=80 replay '\r' DQ_PERSONA=1 EXAKIT_DATASETS_PRESELECT=amazon_sales)"
    has "the table draws once" "1 top borders, 1 bottom borders" "$out"
    has "a Description column" "Description" "$(printf '%s\n' "$out" | grep 'Dataset')"
    has "the description is shown in full" "Online orders" "$out"
    has "and the dataset name is not cut" "Smart-meter energy readings" "$out"
    has "nor your own file" "Upload a file or folder: CSV/Parquet/JSON" "$out"
    has "nor the external source" "Connect an external source - unavailable" "$out"
    lacks "nothing is truncated" "…" "$(printf '%s\n' "$out" | sed -n '/Data to load ─/,/╰/p')"
    has "the persona's dataset is the one picked" "SELECTION=amazon_sales" "$out"

    echo "the external row, where virtual schemas can run (a real pty):"
    out="$(replay 'jjjj \r' DQ_VS=1)"
    has "the cursor stops on it, Space ticks it, it answers external" "SELECTION=tpch,energy,amazon_sales,external" "$out"
    has "...under its own name" "Connect an external source" "$out"
    lacks "...with no reason after it" "Connect an external source -" "$out"
    # The installer's own step, picked at the table: the real wizard entry
    # point runs the command beside the library - here a stub - with nothing
    # after `connect`, the same as typing `exakit connect`.
    out="$(replay 'k jjjjj \r' DQ_SCENE=offer)"
    has "the installer runs exakit connect, nothing after it" "STUB exakit connect" "$out"
    check "...no argument was added" "STUB exakit connect" "$(printf '%s\n' "$out" | grep -o 'STUB exakit connect.*' | head -n 1 | sed 's/ *$//')"
    has "...and the data step ends well" "RC=0 SELECTION=external" "$out"
    out="$(replay 'jjjj \r' DQ_SCENE=offer DQ_STUB_RC=1)"
    has "the datasets, then a connect that fails: the step still ends well" "RC=0 SELECTION=tpch,energy,amazon_sales,external" "$out"
    has "...and says so" "Connecting the external source did not finish" "$out"

    echo "an interactive install: the external row opens the same connect menu as exakit connect (a real pty):"
    # The whole installer data step, the real `exakit connect` included: the
    # table first (the external row ticked), then the connector menu - the
    # table with check boxes, never the line-by-line "Which source?" - where
    # Skip closes it. Its stdin was a here-document (the persona flow's) before
    # the fix, and a pipe when setup is started from `curl | sh`.
    _conn_skip="$(python3 -c 'import json,sys; print("j" * sum(1 for e in json.load(open(sys.argv[1]))["connectors"] if e.get("status") != "gated"))' "$ROOT/setup/virtual-schemas/catalog.json")"
    _conn_keys="k jjjjj \\r\\x02Tick one or more sources\\x03\\x02Enter to confirm\\x03$_conn_skip \\r"
    for _dq_stdin in terminal pipe; do
        out="$(TTY_REPLAY_COLS=100 TTY_REPLAY_CTTY=1 TTY_REPLAY_WAIT=40 replay "$_conn_keys" DQ_SCENE=install DQ_STDIN="$_dq_stdin")"
        has "install, stdin a $_dq_stdin: the connect menu is the table" "╭─ Connect external sources" "$out"
        has "...its rows are check boxes" "[ ] ├─ PostgreSQL" "$out"
        lacks "...never the line-by-line questions" "Which source?" "$out"
        lacks "...the replay never waited in vain" "WAIT FAILED" "$out"
        has "...Skip closes it: nothing connected, said once" "No external source was connected. Connect one any time with: exakit connect" "$out"
        has "...and the data step ends well" "RC=0 SELECTION=external" "$out"
    done

    echo "the installer's persona flow hands its steps the terminal:"
    out="$(TTY_REPLAY_CTTY=1 replay '' DQ_SCENE=persona-stdin)"
    has "setup's stdin is the terminal (install.sh's < /dev/tty)" "SETUP STDIN TERMINAL=yes" "$out"
    has "...so is the persona question's (its picker wants a terminal)" "QUESTION STDIN TERMINAL=yes" "$out"
    has "...and the data step's, not the flow's here-document" "DATA STEP STDIN TERMINAL=yes" "$out"
else
    check "pty replays need python3" "skipped" "skipped"
fi

echo "the table's rows:"
rows() { # rows <pending-ids...> — kind|label|state per row, then the id per row
    (
        _tb_ids="$*"
        exakit_pending_datasets() { for _i in $_tb_ids; do printf '%s|%s label\n' "$_i" "$_i"; done; }
        exakit_data_table_build "$WORK/table"
        cut -d'|' -f1,2,4 "$WORK/table" | tr '\n' ';'
        printf '~%s' "$(printf '%s' "$EXAKIT_TABLE_IDS" | tr '\n' ',')"
    )
}
check "parent, datasets, your file, external (disabled), Skip" \
    "group|Sample datasets|idle;tee|tpch label|idle;corner|energy label|idle;plain|Upload a file or folder: CSV/Parquet/JSON|idle;plain|Connect an external source - unavailable|disabled;plain|Skip|idle;~,tpch,energy,local,,," \
    "$(rows tpch energy)"
check "every sample loaded: the parent is a disabled row that says so" \
    "plain|Sample datasets - all of them are loaded already|disabled;plain|Upload a file or folder: CSV/Parquet/JSON|idle;plain|Connect an external source - unavailable|disabled;plain|Skip|idle;~,local,,," \
    "$(rows)"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H\nenergy|Energy\n'; }; exakit_data_table_build "$WORK/table"
        printf '%s~%s~%s~%s' "$(exakit_data_table_row energy)" "$(exakit_data_table_row local)" "$EXAKIT_TABLE_GROUP" "$EXAKIT_TABLE_EXCLUSIVE") )"
check "a dataset and the file row know their rows; the parent spans the datasets; Skip is exclusive" "3~4~1:2:3:all~6" "$out"
check "one screen: no separate source question" "" "$(command -v exakit_data_source_select)"

echo "the defaults: Skip when nothing on offer is wanted:"
table() { # table <pending-ids...> — EXAKIT_TABLE_DEFAULTS~EXAKIT_TABLE_ROW_LOCAL~EXAKIT_TABLE_ROW_SKIP
    (
        _tb_ids="$*"
        exakit_pending_datasets() { for _i in $_tb_ids; do printf '%s|%s label\n' "$_i" "$_i"; done; }
        exakit_data_table_build "$WORK/table"
        printf '%s~%s~%s' "$EXAKIT_TABLE_DEFAULTS" "$EXAKIT_TABLE_ROW_LOCAL" "$EXAKIT_TABLE_ROW_SKIP"
    )
}
check "no persona: the parent and every pending row ticked" "1,2,3~4~6" "$(table tpch energy)"
check "persona's dataset pending: that row only" "3~4~6" "$(EXAKIT_DATASETS_PRESELECT=energy table tpch energy)"
check "persona's datasets are every one: the parent too" "1,2,3~4~6" "$(EXAKIT_DATASETS_PRESELECT=tpch,energy table tpch energy)"
check "persona's datasets loaded already: Skip" "6~4~6" "$(EXAKIT_DATASETS_PRESELECT=amazon_sales table tpch energy)"
check "persona datasets none: Skip" "6~4~6" "$(EXAKIT_DATASETS_PRESELECT=none table tpch energy)"
check "ids are matched exactly" "6~4~6" "$(EXAKIT_DATASETS_PRESELECT=ENERGY table tpch energy)"
check "nothing pending: your own file, never Skip" "2~2~4" "$(table)"
# The file row is the default with every sample in whoever the persona is: the
# persona's datasets are not on offer, but the file row is the only thing this
# screen can still do.
check "nothing pending, a persona: Skip (nothing it asked for is left)" "4~2~4" "$(EXAKIT_DATASETS_PRESELECT=tpch table)"
check "nothing pending and no file row: Skip, never row 0" "2~0~2" "$(EXAKIT_DATA_TABLE_NO_LOCAL=1 table)"

echo "without a terminal the defaults are the answer:"
answer() { # answer <pending-ids...> — EXAKIT_DATA_LOAD_SELECTION, no terminal
    (
        _tb_ids="$*"
        exakit_pending_datasets() { for _i in $_tb_ids; do printf '%s|%s label\n' "$_i" "$_i"; done; }
        _exakit_prompt_tty() { :; }
        exakit_data_load_select Skip >/dev/null 2>&1 </dev/null
        printf '%s' "$EXAKIT_DATA_LOAD_SELECTION"
    )
}
check "every pending sample" "tpch,energy" "$(answer tpch energy)"
check "the persona's" "energy" "$(EXAKIT_DATASETS_PRESELECT=energy answer tpch energy)"
check "the persona's none stands" "none" "$(EXAKIT_DATASETS_PRESELECT=none answer tpch energy)"
# Every sample in: the file row is the default (above), but only a person can
# answer the path question it leads to. Nobody at the table answers none and
# says how to name a file unattended (EXAKIT_DATA_FILE); a person who presses
# Enter on it gets the file row.
check "every sample loaded, nobody at the table: none" "none" "$(answer)"
confirmed() { # confirmed — the same, with a person pressing Enter on the defaults
    (
        exakit_pending_datasets() { :; }
        ui_table_menu() { EXAKIT_TABLE_SELECTION="$EXAKIT_TABLE_DEFAULTS"; EXAKIT_TABLE_CONFIRMED=1; }
        exakit_data_load_select Skip >/dev/null 2>&1 </dev/null
        printf '%s' "$EXAKIT_DATA_LOAD_SELECTION"
    )
}
check "every sample loaded, Enter pressed: your own file" "local" "$(confirmed)"

echo "after the table: your own file, then the external source (both entry points):"
# Picked in any order, the file's question comes first and the connect wizard
# second - in exakit data-load and in the installer's offer alike, and as the
# PowerShell twin does (tests/data-question-ps.ps1).
_order_of() { # _order_of <function> — what ran after the table, in order
    (
        manifest_get() { printf 'admin\n'; }
        exakit_data_load_select() { EXAKIT_DATA_LOAD_SELECTION="external,local"; EXAKIT_TABLE_STATE=""; EXAKIT_TABLE_CONFIRMED=1; }
        _exakit_prompt_tty() { printf '/dev/tty\n'; }
        exakit_load_local_file() { printf 'local|'; }
        exakit_vs_connect_wizard() { printf 'connect|'; }
        unset EXAKIT_DATASETS EXAKIT_LOAD_SAMPLE EXAKIT_DATA_FILE
        "$1" "$ROOT" 2>/dev/null
    ) | tr -d '\n' | grep -o -E '(local|connect)\|' | tr -d '\n'
}
check "exakit data-load: the file first, then the connect wizard" "local|connect|" "$(_order_of exakit_data_load_menu)"
check "the installer's offer: the same order" "local|connect|" "$(_order_of exakit_maybe_offer_data_load)"
check "EXAKIT_DATA_FILE bypasses the table" "local~" \
    "$( (exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }; EXAKIT_DATA_FILE="$WORK" exakit_data_load_select Skip >/dev/null 2>&1
        printf '%s~%s' "$EXAKIT_DATA_LOAD_SELECTION" "$EXAKIT_TABLE_STATE") )"

echo "the external row: picked where virtual schemas can run, else disabled with the reason:"
vs_rows() { # vs_rows <pyexasol:yes|no> [defs:yes|no] — the external row's label|state, and its id
    (
        . "$ROOT/setup/lib/virtual-schemas.sh"
        if [ "$1" = yes ]; then pyexasol_venv_python() { printf '/bin/sh\n'; }
        else pyexasol_venv_python() { printf '%s\n' "$WORK/no-such-python"; }; fi
        [ "${2:-yes}" = no ] && exakit_vs_defs() { return 1; }
        exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }
        exakit_data_table_build "$WORK/table"
        printf '%s~%s' "$(sed -n 4p "$WORK/table" | cut -d'|' -f2,4)" "$(printf '%s' "$EXAKIT_TABLE_IDS" | sed -n 4p)"
    )
}
check "the module and the kit's pyexasol: pickable, under its own name" "Connect an external source|idle~external" "$(vs_rows yes)"
check "no pyexasol: disabled, and says so" "Connect an external source - no pyexasol|disabled~" "$(vs_rows no)"
check "no definitions in this kit copy: disabled, and says so" "Connect an external source - unavailable|disabled~" "$(vs_rows yes no)"
check "the module not loaded at all: disabled" "Connect an external source - unavailable|disabled~" \
    "$( (exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }; exakit_data_table_build "$WORK/table"
        printf '%s~%s' "$(sed -n 4p "$WORK/table" | cut -d'|' -f2,4)" "$(printf '%s' "$EXAKIT_TABLE_IDS" | sed -n 4p)") )"
for _setup in setup-macos.sh setup-linux.sh; do
    has "$_setup loads the module, so the install's table can offer the row" '. "$LIB_DIR/virtual-schemas.sh"' "$(cat "$ROOT/setup/$_setup")"
done

echo "the external row runs exakit connect, after the file, and never stops the load:"
# A kit copy laid out as the installer has it: setup/lib/virtual-schemas.sh and,
# beside the library, the command - here a stub that logs its arguments, says
# STUB-CONNECT where the wizard would draw, and exits STUB_RC. The real
# exakit_vs_connect_wizard and the real entry points run.
mkdir -p "$WORK/fakekit/setup/lib"
cp "$ROOT/setup/lib/virtual-schemas.sh" "$WORK/fakekit/setup/lib/"
printf '#!/bin/sh\nprintf "connect|%%s\\n" "$*" >> "$STUB_LOG"\necho STUB-CONNECT\nexit "${STUB_RC:-0}"\n' > "$WORK/fakekit/setup/exakit"
ext() { # ext <offer|menu> <stub-rc> [terminal:1|0] [confirmed:1|0] [file-rc] — what ran~status~what was said
    (
        _ext_entry="$1"; _ext_tty="${3:-1}"; _ext_conf="${4:-1}"; _ext_file_rc="${5:-0}"
        STUB_RC="$2"; STUB_LOG="$WORK/stub.log"; export STUB_RC STUB_LOG; : > "$STUB_LOG"
        . "$WORK/fakekit/setup/lib/virtual-schemas.sh"
        manifest_get() { printf 'admin\n'; }
        exakit_data_load_select() { EXAKIT_DATA_LOAD_SELECTION="external,local"; EXAKIT_TABLE_STATE=""; EXAKIT_TABLE_CONFIRMED="$_ext_conf"; }
        if [ "$_ext_tty" = 1 ]; then _exakit_prompt_tty() { printf '/dev/tty\n'; }; else _exakit_prompt_tty() { :; }; fi
        exakit_load_local_file() { printf 'local|\n' >> "$STUB_LOG"; return "$_ext_file_rc"; }
        unset EXAKIT_DATASETS EXAKIT_LOAD_SAMPLE EXAKIT_DATA_FILE
        if [ "$_ext_entry" = menu ]; then exakit_data_load_menu > "$WORK/ext.out" 2>&1
        else exakit_maybe_offer_data_load "$ROOT" > "$WORK/ext.out" 2>&1; fi
        _ext_rc=$?
        printf '%s~rc=%s~%s' "$(tr '\n' ';' < "$STUB_LOG")" "$_ext_rc" "$(tr '\n' ' ' < "$WORK/ext.out")"
    )
}
before() { # before <first> <second> <text> — yes when <first> is said before <second>
    case "$3" in *"$1"*"$2"*) echo yes ;; *) echo no ;; esac
}
check "outside exakit the wizard is the command beside the library" "$ROOT/setup/exakit" \
    "$( (. "$ROOT/setup/lib/virtual-schemas.sh"; _exakit_vs_cli) )"
check "inside exakit it is cmd_connect itself, with no arguments" "cmd_connect:[]" \
    "$( (. "$ROOT/setup/lib/virtual-schemas.sh"; _require_install() { :; }; cmd_connect() { printf 'cmd_connect:[%s]' "$*"; }; exakit_vs_connect_wizard) )"
for _entry in offer menu; do
    out="$(ext "$_entry" 0)"
    check "$_entry: the file, then exakit connect with nothing after it" "local|;connect|connect;~rc=0" "$(printf '%s' "$out" | cut -d'~' -f1,2)"
    out="$(ext "$_entry" 1)"
    check "$_entry: a connect that fails does not fail the load" "local|;connect|connect;~rc=0" "$(printf '%s' "$out" | cut -d'~' -f1,2)"
    has "$_entry: ...it is said, with the command" "Connecting the external source did not finish (see above). Retry any time with: exakit connect" "$out"
    out="$(ext "$_entry" 5)"
    has "$_entry: a connect cancelled in the wizard (exit 5) is said" "No external source was connected. Connect one any time with: exakit connect" "$out"
    check "$_entry: ...and the load ends well" "rc=0" "$(printf '%s' "$out" | cut -d'~' -f2)"
    out="$(ext "$_entry" 130)"
    has "$_entry: Ctrl+C in the wizard (130) is a cancel, not a failure" "No external source was connected" "$out"
    out="$(ext "$_entry" 0 0)"
    check "$_entry: no terminal: the wizard is never started" "local|;~rc=0" "$(printf '%s' "$out" | cut -d'~' -f1,2)"
    has "$_entry: ...the command is named, and why: no terminal" "needs a terminal. Connect one any time with: exakit connect" "$out"
    out="$(ext "$_entry" 0 1 0)"
    check "$_entry: nobody pressed Enter on the table: never started either" "local|;~rc=0" "$(printf '%s' "$out" | cut -d'~' -f1,2)"
    has "$_entry: ...with a terminal there, it is for later" "which this run does not ask. Run it later: exakit connect" "$out"
    lacks "$_entry: ...not 'needs a terminal'" "needs a terminal" "$out"
done
# What the file left to say comes before the wizard starts, so "see above" is
# next to what it points at: a refused file (3) in the installer, a file the
# person backed out of (2) in exakit data-load.
out="$(ext offer 0 1 1 3)"
check "offer: a refused file is not booked, and the wizard still runs" "local|;connect|connect;~rc=0" "$(printf '%s' "$out" | cut -d'~' -f1,2)"
check "offer: ...its note is said before the wizard starts" "yes" "$(before 'The local file was refused (see above)' STUB-CONNECT "$out")"
out="$(ext menu 0 1 1 2)"
check "menu: the note of a file backed out of is said before the wizard starts" "yes" "$(before 'Local file load skipped' STUB-CONNECT "$out")"
out="$(ext menu 0 1 1 3)"
check "menu: a refused file, then the wizard, then exit 2 (bad input)" "local|;connect|connect;~rc=2" "$(printf '%s' "$out" | cut -d'~' -f1,2)"
out="$(ext offer 0 1 1 1)"
check "offer: a failed file is not booked either (a warning, not an install failure), the wizard still runs" "local|;connect|connect;~rc=0" "$(printf '%s' "$out" | cut -d'~' -f1,2)"

echo "the installer's own Ctrl+C trap is back as it was after the wizard:"
# The runner holds INT with a trap that does nothing while the wizard runs, so
# Ctrl+C ends only the wizard. Whatever the shell had before is restored - a
# trap of its own, or none - on a cancel and on a failure alike.
# A shell started in the background without job control ignores INT, and an
# ignored signal cannot be trapped - so the check runs in a bash of its own,
# started with INT at its default (python3 resets it before the exec).
cat > "$WORK/int-trap.sh" <<'EXAKIT_INT_TRAP_EOF'
ROOT="$1"; WORK="$2"; STUB_RC="$3"; STUB_LOG="$WORK/stub.log"; export STUB_RC STUB_LOG
HOME="$WORK/home"; EXAKIT_HOME="$WORK/kit"; EXAKIT_BIN_DIR="$WORK/bin"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"
. "$WORK/fakekit/setup/lib/virtual-schemas.sh"
EXAKIT_LOG_FILE="$WORK/log"
_exakit_prompt_tty() { printf '/dev/tty\n'; }
EXAKIT_TABLE_CONFIRMED=1
if [ "$4" = - ]; then trap - INT; else trap "$4" INT; fi
_it_before="$(trap -p INT)"
exakit_data_external_run >/dev/null 2>&1
printf '%s~%s' "$_it_before" "$(trap -p INT)"
EXAKIT_INT_TRAP_EOF
int_trap() { # int_trap <stub-rc> <trap-before|-> — "before~after" of trap -p INT
    python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
        /bin/bash "$WORK/int-trap.sh" "$ROOT" "$WORK" "$1" "$2"
}
for _rc in 5 1; do
    out="$(int_trap "$_rc" 'echo held')"
    check "exit $_rc: the shell's own INT trap is restored" "trap -- 'echo held' SIGINT~trap -- 'echo held' SIGINT" "$out"
    out="$(int_trap "$_rc" -)"
    check "exit $_rc: no INT trap before, none after" "~" "$out"
done

echo "a persona's datasets and a file: the file is announced when it loads:"
out="$( (exakit_pending_datasets() { printf 'amazon_sales|Amazon sales\nfraud_transactions|Fraud\n'; }
        exakit_load_dataset() { printf 'LOAD %s\n' "$2"; }
        exakit_load_local_file() { printf 'FILE\n'; }
        _exakit_prompt_tty() { :; }
        unset EXAKIT_DATASETS EXAKIT_LOAD_SAMPLE
        EXAKIT_PERSONA_ACTIVE=1 EXAKIT_DATASETS_PRESELECT=amazon_sales,fraud_transactions EXAKIT_DATA_FILE="$WORK/mine.csv" \
            exakit_maybe_offer_data_load "$ROOT" 2>&1 | grep -E '^(LOAD|FILE)|Loading a local file' | sed 's/.*Loading a local file.*/ANNOUNCE/' | tr '\n' ';') )"
check "the persona's datasets, then the announcement, then the file" "LOAD amazon_sales;LOAD fraud_transactions;ANNOUNCE;FILE;" "$out"

echo "what each dataset is goes in a column, not on the name:"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H retail benchmark (~175k rows)\namazon_sales|Amazon sales (Amazon.in fashion orders, Apr-Jun 2022, ~129k lines)\n'; }
        exakit_data_table_build "$WORK/table"
        printf '%s~%s~%s' "$EXAKIT_TABLE_HAS_DESC" "$(cut -d'|' -f2 "$WORK/table" | tr '\n' ';')" "$(cut -d'|' -f11 "$WORK/table" | tr '\n' ';')") )"
check "the names stay names; the descriptions go in column 2" \
    "1~Sample datasets;TPC-H retail benchmark;Amazon sales;Upload a file or folder: CSV/Parquet/JSON;Connect an external source - unavailable;Skip;~;Orders, customers, parts;Online orders;;;;" "$out"
out="$( (exakit_pending_datasets() { printf 'not_a_dataset|A dataset with no conf\n'; }
        exakit_data_table_build "$WORK/table"; printf '%s' "$EXAKIT_TABLE_HAS_DESC") )"
check "no description, no Description column" "0" "$out"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }
        _exakit_prompt_tty() { :; }
        exakit_data_load_select Skip >/dev/null 2>&1
        printf '[%s]' "${UI_TABLE_COL2:-}") )"
check "the For column is gone again before the progress display" "[]" "$out"

echo "exakit data-load [--force] [<file-or-folder>|<dataset>]:"
DL_FN="$WORK/cmd_data_load.sh"
DL_RANGE='/^cmd_data_load() {/,/^}/p'      # assigned first: bash 3.2 mangles it as a literal argument
sed -n "$DL_RANGE" "$ROOT/setup/exakit" > "$DL_FN"
check "cmd_data_load is found in setup/exakit" "yes" "$([ -s "$DL_FN" ] && echo yes || echo no)"
has "the dispatcher passes every argument" 'data-load) shift; _with_notice cmd_data_load "$@" ;;' "$(cat "$ROOT/setup/exakit")"
dl() { # dl <pending-ids> <args...> — what cmd_data_load does, stubbed below the CLI
    (
        _dl_pend="$1"; shift
        . "$DL_FN"
        reject() { printf 'REJECT: %s\n' "$*"; exit 2; }
        _require_install() { :; }
        exakit_ensure_runtime_running() { :; }
        exakit_init_logging() { :; }
        exakit_repo_root() { printf '%s' "$ROOT"; }
        exakit_load_dataset() { printf 'LOAD %s %s\n' "$2" "${3:-}"; }
        exakit_load_sample_data() { printf 'LOAD tpch(sample) %s\n' "${2:-}"; }
        exakit_pending_datasets() { for _i in $_dl_pend; do printf '%s|x\n' "$_i"; done; }
        exakit_data_load_menu() { printf 'MENU FILE=%s\n' "${EXAKIT_DATA_FILE:-}"; }
        _exakit_prompt_tty() { :; }
        cmd_data_load "$@"
    ) 2>&1
}
check "--force <dataset> reloads exactly that dataset" "LOAD amazon_sales --force" "$(dl tpch --force amazon_sales | grep '^LOAD')"
check "<dataset> --force, the other order, too" "LOAD amazon_sales --force" "$(dl tpch amazon_sales --force | grep '^LOAD')"
check "bare --force still reloads the bundled sample" "LOAD tpch(sample) --force" "$(dl tpch --force | grep '^LOAD')"
check "a dataset id wins over EXAKIT_DATA_FILE in the environment" "LOAD amazon_sales " \
    "$(EXAKIT_DATA_FILE="$WORK" dl amazon_sales amazon_sales | grep -E '^(LOAD|MENU)')"
check "...and over EXAKIT_DATASETS" "LOAD energy " "$(EXAKIT_DATASETS=tpch dl "tpch energy" energy | grep -E '^(LOAD|MENU)')"
out="$(dl tpch amazon_sales)"
has "an id already loaded names the reload command for it" "exakit data-load --force amazon_sales" "$out"
has "two targets are refused" "REJECT: data-load takes one file, folder or dataset at a time" "$(dl tpch tpch energy)"
has "--force with a file is refused, with the file's own answer" "EXAKIT_ON_EXISTING=replace" "$(dl tpch --force "$WORK")"
has "an unknown option is refused" "REJECT: Unknown option '--nope'" "$(dl tpch --nope)"
check "a dataset id is matched exactly" "yes" "$(dl tpch TPCH | grep -q 'No such file, folder or dataset' && echo yes || echo no)"
out="$(EXAKIT_DATASETS=tpch,external dl tpch)"
check "EXAKIT_DATASETS names the external row: the datasets load" "LOAD tpch " "$(printf '%s\n' "$out" | grep '^LOAD')"
has "...and the external row is only the command to run" "needs a terminal. Connect one any time with: exakit connect" "$out"
lacks "...it is not an unknown id" "Unknown dataset id 'external'" "$out"
out="$(EXAKIT_DATASETS=external dl tpch; printf 'rc=%s' "$?")"
has "external alone is an answer, not 'matched no bundled dataset'" "rc=0" "$out"
lacks "...and loads nothing" "LOAD" "$out"
out="$(EXAKIT_DATASETS=tpch,external dl tpch --force)"
check "--force with tpch,external reloads tpch" "LOAD tpch --force" "$(printf '%s\n' "$out" | grep '^LOAD')"
has "...and the external row is the command to run" "needs a terminal. Connect one any time with: exakit connect" "$out"
lacks "...not an unknown id" "Unknown dataset id 'external'" "$out"
out="$(EXAKIT_DATASETS=external dl tpch --force; printf 'rc=%s' "$?")"
has "--force with external alone: the hint, exit 0, as plain data-load" "rc=0" "$out"
has "...the hint" "Connect one any time with: exakit connect" "$out"
lacks "...not 'matched no bundled dataset'" "matched no bundled dataset" "$out"
out="$(EXAKIT_DATASETS=tpch dl tpch "$WORK")"
check "a file named with EXAKIT_DATASETS set: the file, as always" "MENU FILE=$WORK" "$(printf '%s\n' "$out" | grep '^MENU')"
has "...and it says the datasets were not loaded" "EXAKIT_DATASETS is ignored when a file is named; load them with a separate exakit data-load" "$out"
lacks "a file alone: no such line" "EXAKIT_DATASETS is ignored" "$(dl tpch "$WORK")"
lacks "the old hint without a dataset is gone" "replace it with: exakit data-load --force," "$(cat "$ROOT/setup/exakit")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
