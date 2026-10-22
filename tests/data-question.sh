#!/usr/bin/env bash
# data-question.sh — the data question and `exakit data-load`'s arguments.
#
#   bash tests/data-question.sh
#
# What it pins:
#   - Enter on the exclusive row of ANY checkbox menu answers that row alone
#     (the first data question's Skip, an either/or menu's No), under a real pty
#   - the first data question keeps Skip on row 4: "Connect an external source"
#     is shown disabled, and so is "Sample datasets" once every sample is in
#   - a persona that wants no samples, or only ones already loaded, makes Skip
#     the default answer of both data questions (Enter never does nothing)
#   - who each dataset is for is a "For" column on the samples table, so a
#     name is never cut off at 80 columns
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

replay() { # replay <keys> [VAR=value ...] — the scenario's answer lines
    _rp_keys="$1"; shift
    env "$@" python3 "$ROOT/tests/lib/tty-replay.py" "$ROOT/tests/lib/data-question-scenario.sh" "$ROOT" \
        "Sample datasets" "$_rp_keys" 2>&1
}

echo "Enter on the exclusive row answers it alone (a real pty):"
if command -v python3 >/dev/null 2>&1; then
    # Down, down: row 3 is disabled, so the cursor lands on Skip. "Sample
    # datasets" stays ticked; Enter on Skip used to load the samples anyway.
    out="$(replay 'jj\r')"
    has "Enter on Skip in the first question skips" "SELECTION=none" "$out"
    has "...and asks nothing more" "SOURCE=none" "$out"
    check "...without a samples table" "" "$(printf '%s\n' "$out" | grep -c '^  ╭─ Sample datasets' | grep -v '^0$')"
    out="$(replay 'k\r')"
    has "Up from the first row wraps to Skip, and Enter skips" "SELECTION=none" "$out"
    out="$(replay '\r\r')"
    has "Enter on the samples still opens them, all ticked" "SELECTION=tpch,energy,banking_complaints" "$out"
    out="$(replay 'j\r\r')"
    has "Enter on a row that is not exclusive confirms what is ticked" "SOURCE=sample" "$out"
    out="$(replay 'j\r' DQ_SCENE=yesno)"
    has "an either/or menu: Enter on No is No" "SELECTION=2" "$out"
    out="$(replay '\r' DQ_SCENE=yesno)"
    has "...and Enter on Yes is still Yes" "SELECTION=1" "$out"

    echo "a persona's datasets: Skip when none of them is still to load:"
    out="$(replay '\r' EXAKIT_DATASETS_PRESELECT=none)"
    has "persona datasets none: Enter skips" "SELECTION=none" "$out"
    out="$(replay '\r' EXAKIT_DATASETS_PRESELECT=fda_recalls)"
    has "persona datasets all loaded already: Enter skips" "SELECTION=none" "$out"
    out="$(replay '\r\r' EXAKIT_DATASETS_PRESELECT=energy)"
    has "persona datasets still to load: Enter, Enter loads exactly those" "SELECTION=energy" "$out"
    out="$(replay ' \r\r' EXAKIT_DATASETS_PRESELECT=none)"
    has "...and with none wanted, the samples can still be picked" "SOURCE=sample" "$out"

    echo "who each dataset is for, whole, at 80 columns:"
    out="$(TTY_REPLAY_COLS=80 replay '\r\r' DQ_PERSONA=1 EXAKIT_DATASETS_PRESELECT=banking_complaints)"
    has "the table draws once" "1 top borders, 1 bottom borders" "$out"
    has "a For column" "For" "$(printf '%s\n' "$out" | grep 'Dataset')"
    has "the persona is shown in full" "AI / Data Scientist" "$out"
    has "and the dataset name is not cut" "Smart-meter energy readings" "$out"
    lacks "nothing is truncated" "…" "$(printf '%s\n' "$out" | sed -n '/Sample datasets ─/,/╰/p')"
    has "the persona's dataset is the one picked" "SELECTION=banking_complaints" "$out"
else
    check "pty replays need python3" "skipped" "skipped"
fi

echo "the first question's rows (Skip stays row 4):"
rows() { # the labels and defaults the first question is asked with
    (
        ui_checkbox_menu() { printf 'DEFAULT=%s EXCL=%s\n' "$2" "$EXAKIT_CHECKBOX_EXCLUSIVE"; shift 2; printf '%s\n' "$@"; EXAKIT_CHECKBOX_SELECTION="$EXAKIT_CHECKBOX_EXCLUSIVE"; }
        exakit_data_source_select 2>/dev/null
    ) | sed '/^$/d'
}
out="$( exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }; rows )"
check "four rows, external disabled, Skip exclusive" \
    "DEFAULT=1 EXCL=4|Sample datasets - 1 ready to load, picked next|Your own file or folder - CSV, Parquet or JSON|!Connect an external source - coming soon|Skip|" \
    "$(printf '%s\n' "$out" | tr '\n' '|')"
out="$( exakit_pending_datasets() { :; }; rows )"
check "every sample loaded: the samples row is disabled, your own file the default" \
    "DEFAULT=2 EXCL=4|!Sample datasets - all of them are loaded already" "$(printf '%s\n' "$out" | head -n 2 | tr '\n' '|' | sed 's/|$//')"
out="$( exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }; EXAKIT_DATASETS_PRESELECT=none rows | head -n 1 )"
check "persona datasets none: Skip is the default" "DEFAULT=4 EXCL=4" "$out"
out="$( exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }; EXAKIT_DATASETS_PRESELECT=fda_recalls,energy rows | head -n 1 )"
check "persona datasets none of them pending: Skip is the default" "DEFAULT=4 EXCL=4" "$out"
out="$( exakit_pending_datasets() { :; }; EXAKIT_DATASETS_PRESELECT=tpch rows | head -n 1 )"
check "persona datasets all loaded and nothing pending: Skip, not your own file" "DEFAULT=4 EXCL=4" "$out"
out="$( exakit_pending_datasets() { printf 'tpch|TPC-H\nenergy|Energy\n'; }; EXAKIT_DATASETS_PRESELECT=energy rows | head -n 1 )"
check "persona datasets pending: the samples are the default" "DEFAULT=1 EXCL=4" "$out"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }
        EXAKIT_DATASETS_PRESELECT=none exakit_data_source_select >/dev/null 2>&1 </dev/null; printf '%s' "$EXAKIT_DATA_SOURCE") )"
check "without a terminal the persona's none stands" "none" "$out"

echo "the samples table: Skip when nothing on offer is wanted:"
table() { # table <pending-ids...> — EXAKIT_TABLE_DEFAULTS~EXAKIT_TABLE_ROW_SKIP
    (
        _tb_ids="$*"
        exakit_pending_datasets() { for _i in $_tb_ids; do printf '%s|%s label\n' "$_i" "$_i"; done; }
        EXAKIT_DATA_TABLE_NO_LOCAL=1 exakit_data_table_build "$WORK/table"
        printf '%s~%s' "$EXAKIT_TABLE_DEFAULTS" "$EXAKIT_TABLE_ROW_SKIP"
    )
}
check "no persona: every pending row ticked" "1,2,3~4" "$(table tpch energy)"
check "persona's dataset pending: that row" "3~4" "$(EXAKIT_DATASETS_PRESELECT=energy table tpch energy)"
check "persona's datasets loaded already: Skip" "4~4" "$(EXAKIT_DATASETS_PRESELECT=fda_recalls table tpch energy)"
check "persona datasets none: Skip" "4~4" "$(EXAKIT_DATASETS_PRESELECT=none table tpch energy)"
check "nothing pending and no file row: Skip, never row 0" "1~1" "$(table)"
out="$( (exakit_pending_datasets() { :; }; exakit_data_table_build "$WORK/table"; printf '%s~%s' "$EXAKIT_TABLE_DEFAULTS" "$EXAKIT_TABLE_ROW_LOCAL") )"
check "nothing pending with a file row: the file row, as before" "1~1" "$out"

echo "who each dataset is for is a column, not a suffix:"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H retail benchmark (~175k rows)\nfda_recalls|FDA recalls (openFDA, ~5k)\n'; }
        EXAKIT_DATA_TABLE_NO_LOCAL=1 exakit_data_table_build "$WORK/table"
        printf '%s~%s~%s' "$EXAKIT_TABLE_HAS_FOR" "$(cut -d'|' -f2 "$WORK/table" | tr '\n' ';')" "$(cut -d'|' -f11 "$WORK/table" | tr '\n' ';')") )"
check "the names stay names; the personas go in column 2" \
    "1~Select All;TPC-H retail benchmark;FDA recalls;Skip;~;General;AI / Data Scientist;;" "$out"
out="$( (exakit_persona_dataset_hints() { :; }
        exakit_pending_datasets() { printf 'tpch|TPC-H retail benchmark\n'; }
        EXAKIT_DATA_TABLE_NO_LOCAL=1 exakit_data_table_build "$WORK/table"; printf '%s' "$EXAKIT_TABLE_HAS_FOR") )"
check "no persona service, no For column" "0" "$out"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }
        _exakit_prompt_tty() { :; }
        EXAKIT_DATA_LOAD_SELECTION=""; exakit_data_samples_select Skip >/dev/null 2>&1
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
        cmd_data_load "$@"
    ) 2>&1
}
check "--force <dataset> reloads exactly that dataset" "LOAD fda_recalls --force" "$(dl tpch --force fda_recalls | grep '^LOAD')"
check "<dataset> --force, the other order, too" "LOAD fda_recalls --force" "$(dl tpch fda_recalls --force | grep '^LOAD')"
check "bare --force still reloads the bundled sample" "LOAD tpch(sample) --force" "$(dl tpch --force | grep '^LOAD')"
check "a dataset id wins over EXAKIT_DATA_FILE in the environment" "LOAD fda_recalls " \
    "$(EXAKIT_DATA_FILE="$WORK" dl fda_recalls fda_recalls | grep -E '^(LOAD|MENU)')"
check "...and over EXAKIT_DATASETS" "LOAD energy " "$(EXAKIT_DATASETS=tpch dl "tpch energy" energy | grep -E '^(LOAD|MENU)')"
out="$(dl tpch fda_recalls)"
has "an id already loaded names the reload command for it" "exakit data-load --force fda_recalls" "$out"
has "two targets are refused" "REJECT: data-load takes one file, folder or dataset at a time" "$(dl tpch tpch energy)"
has "--force with a file is refused, with the file's own answer" "EXAKIT_ON_EXISTING=replace" "$(dl tpch --force "$WORK")"
has "an unknown option is refused" "REJECT: Unknown option '--nope'" "$(dl tpch --nope)"
check "a dataset id is matched exactly" "yes" "$(dl tpch TPCH | grep -q 'No such file, folder or dataset' && echo yes || echo no)"
lacks "the old hint without a dataset is gone" "replace it with: exakit data-load --force," "$(cat "$ROOT/setup/exakit")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
