#!/usr/bin/env bash
# data-question.sh — the data question and `exakit data-load`'s arguments.
#
#   bash tests/data-question.sh
#
# What it pins:
#   - the data question is ONE table, "Data to load": the "Sample datasets"
#     parent with the pending datasets under it, your own file or folder, an
#     external source (shown disabled, coming soon) and Skip - drawn once
#   - under a real pty: Enter keeps what is ticked, Enter on Skip answers none,
#     Up past the first row wraps to Skip, the cursor steps over the disabled
#     external row, ticking the file row with the samples answers "<ids>,local",
#     ticking the parent ticks every dataset; Enter on the exclusive row of ANY
#     checkbox menu answers that row alone
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

# The scenario's rows, with tpch, energy and banking_complaints still to load:
#   1 Sample datasets (parent)  2 tpch  3 energy  4 banking_complaints
#   5 Your file or folder       6 Connect an external source (disabled)  7 Skip
# The cursor starts on row 2, past the parent.
echo "one table answers the data question (a real pty):"
if command -v python3 >/dev/null 2>&1; then
    out="$(replay '\r')"
    has "Enter keeps what is ticked: every pending dataset" "SELECTION=tpch,energy,banking_complaints" "$out"
    has "the table draws once, and nothing else is boxed" "1 top borders, 1 bottom borders" "$out"
    check "...one box on the final screen" "1" "$(printf '%s\n' "$out" | sed -n '/=== FINAL SCREEN ===/,/^SELECTION=/p' | grep -c '╭')"
    has "the parent row is Sample datasets" "Sample datasets" "$out"
    lacks "...and the old source question is gone" "ready to load, picked next" "$out"
    out="$(replay 'jjjj\r')"
    has "Down steps over the disabled external row onto Skip, and Enter skips" "SELECTION=none" "$out"
    out="$(replay 'kk\r')"
    has "Up from the first row wraps to Skip, and Enter skips" "SELECTION=none" "$out"
    out="$(replay 'jjj\r')"
    has "Enter on the unticked file row confirms what is ticked" "SELECTION=tpch,energy,banking_complaints" "$out"
    out="$(replay 'jjj \r')"
    has "the file row picked with the samples: <ids>,local" "SELECTION=tpch,energy,banking_complaints,local" "$out"
    out="$(replay ' \r')"
    has "unticking one dataset releases the parent, the rest still load" "SELECTION=energy,banking_complaints" "$out"
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
    out="$(replay '\r' EXAKIT_DATASETS_PRESELECT=pharma_trials)"
    has "persona datasets all loaded already: Enter skips" "SELECTION=none" "$out"
    out="$(replay '\r' EXAKIT_DATASETS_PRESELECT=energy)"
    has "persona datasets still to load: Enter loads exactly those" "SELECTION=energy" "$out"
    out="$(replay ' \r' EXAKIT_DATASETS_PRESELECT=none)"
    has "...and with none wanted, a sample can still be picked" "SELECTION=tpch" "$out"
    out="$(replay 'k \r' EXAKIT_DATASETS_PRESELECT=energy)"
    has "ticking the parent ticks every dataset" "SELECTION=tpch,energy,banking_complaints" "$out"

    echo "who each dataset is for, whole, at 80 columns:"
    out="$(TTY_REPLAY_COLS=80 replay '\r' DQ_PERSONA=1 EXAKIT_DATASETS_PRESELECT=banking_complaints)"
    has "the table draws once" "1 top borders, 1 bottom borders" "$out"
    has "a For column" "For" "$(printf '%s\n' "$out" | grep 'Dataset')"
    has "the persona is shown in full" "AI Scientist, ML Engineer" "$out"
    has "and the dataset name is not cut" "Smart-meter energy readings" "$out"
    has "nor your own file" "Your file or folder: CSV, Parquet, JSON" "$out"
    has "nor the external source" "Connect an external source - coming soon" "$out"
    lacks "nothing is truncated" "…" "$(printf '%s\n' "$out" | sed -n '/Data to load ─/,/╰/p')"
    has "the persona's dataset is the one picked" "SELECTION=banking_complaints" "$out"
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
    "group|Sample datasets|idle;tee|tpch label|idle;corner|energy label|idle;plain|Your file or folder: CSV, Parquet, JSON|idle;plain|Connect an external source - coming soon|disabled;plain|Skip|idle;~,tpch,energy,local,,," \
    "$(rows tpch energy)"
check "every sample loaded: the parent is a disabled row that says so" \
    "plain|Sample datasets - all of them are loaded already|disabled;plain|Your file or folder: CSV, Parquet, JSON|idle;plain|Connect an external source - coming soon|disabled;plain|Skip|idle;~,local,,," \
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
check "persona's datasets loaded already: Skip" "6~4~6" "$(EXAKIT_DATASETS_PRESELECT=pharma_trials table tpch energy)"
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
check "every sample loaded: your own file" "local" "$(answer)"
check "EXAKIT_DATA_FILE bypasses the table" "local~" \
    "$( (exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }; EXAKIT_DATA_FILE="$WORK" exakit_data_load_select Skip >/dev/null 2>&1
        printf '%s~%s' "$EXAKIT_DATA_LOAD_SELECTION" "$EXAKIT_TABLE_STATE") )"

echo "who each dataset is for is a column, not a suffix:"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H retail benchmark (~175k rows)\npharma_trials|Pharma clinical trials (ClinicalTrials.gov, ~5k trials)\n'; }
        exakit_data_table_build "$WORK/table"
        printf '%s~%s~%s' "$EXAKIT_TABLE_HAS_FOR" "$(cut -d'|' -f2 "$WORK/table" | tr '\n' ';')" "$(cut -d'|' -f11 "$WORK/table" | tr '\n' ';')") )"
check "the names stay names; the personas go in column 2" \
    "1~Sample datasets;TPC-H retail benchmark;Pharma clinical trials;Your file or folder: CSV, Parquet, JSON;Connect an external source - coming soon;Skip;~;;AI Scientist, ML Engineer;;;;" "$out"
out="$( (exakit_persona_dataset_hints() { :; }
        exakit_pending_datasets() { printf 'tpch|TPC-H retail benchmark\n'; }
        exakit_data_table_build "$WORK/table"; printf '%s' "$EXAKIT_TABLE_HAS_FOR") )"
check "no persona service, no For column" "0" "$out"
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
        cmd_data_load "$@"
    ) 2>&1
}
check "--force <dataset> reloads exactly that dataset" "LOAD pharma_trials --force" "$(dl tpch --force pharma_trials | grep '^LOAD')"
check "<dataset> --force, the other order, too" "LOAD pharma_trials --force" "$(dl tpch pharma_trials --force | grep '^LOAD')"
check "bare --force still reloads the bundled sample" "LOAD tpch(sample) --force" "$(dl tpch --force | grep '^LOAD')"
check "a dataset id wins over EXAKIT_DATA_FILE in the environment" "LOAD pharma_trials " \
    "$(EXAKIT_DATA_FILE="$WORK" dl pharma_trials pharma_trials | grep -E '^(LOAD|MENU)')"
check "...and over EXAKIT_DATASETS" "LOAD energy " "$(EXAKIT_DATASETS=tpch dl "tpch energy" energy | grep -E '^(LOAD|MENU)')"
out="$(dl tpch pharma_trials)"
has "an id already loaded names the reload command for it" "exakit data-load --force pharma_trials" "$out"
has "two targets are refused" "REJECT: data-load takes one file, folder or dataset at a time" "$(dl tpch tpch energy)"
has "--force with a file is refused, with the file's own answer" "EXAKIT_ON_EXISTING=replace" "$(dl tpch --force "$WORK")"
has "an unknown option is refused" "REJECT: Unknown option '--nope'" "$(dl tpch --nope)"
check "a dataset id is matched exactly" "yes" "$(dl tpch TPCH | grep -q 'No such file, folder or dataset' && echo yes || echo no)"
lacks "the old hint without a dataset is gone" "replace it with: exakit data-load --force," "$(cat "$ROOT/setup/exakit")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
