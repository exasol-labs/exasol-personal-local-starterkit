#!/usr/bin/env bash
# lakehouse-picker.sh - the tree group modes of the checkbox widget (collapse,
# one, first) and the `exakit connect` source menu built on them: one
# "Lakehouse (Iceberg / Delta)" row that opens into its catalogs, and the
# files under the picked catalog.
#
#   bash tests/lakehouse-picker.sh
#
# 1. the pure rules (_ui_checkbox_apply_group and the _ui_checkbox_tree_*
#    helpers), key by key;
# 2. the same key sequences through the PowerShell twins (Update-ExakitTreeGroup
#    and friends in ui.ps1), compared line for line - skipped without pwsh;
# 3. ui_checkbox_menu with tree specs under a real pty (tests/lib/tty-replay.py);
# 4. the connect menu under a real pty: every one of the 9 catalog x files
#    paths, the refused Enter, the branch that closes, the disabled rows the
#    cursor skips, the menu's 11 entries, Skip.
# The menus without tree specs are guarded by their own suites
# (checkbox-group.sh, table-menu-ps.ps1, notebook-tools-table.sh, ...).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0
pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }
check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected <$2>, got <$3>)"; fi
}
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (missing: $2)" ;; esac; }
lacks() { case "$3" in *"$2"*) fail "$1 (present: $2)" ;; *) pass "$1" ;; esac; }

# shellcheck disable=SC1091
. "$ROOT/setup/lib/ui.sh"
# shellcheck disable=SC1091
. "$ROOT/setup/lib/common.sh"
# shellcheck disable=SC1091
. "$ROOT/setup/lib/virtual-schemas.sh"

printf '\n== the tree rules, key by key ==\n'
# The connect menu's shape in small: 1 PG, 2 Lake, 3 REST (4 vended, 5 s3,
# 6 azure, 7 gcs disabled), 8 Glue (9 note, disabled), 10 None (11 s3, 12 azure,
# 13 gcs disabled), 14 Skip.
TREE_SPECS="3:4:7:collapse+one+first 8:9:9:collapse 10:11:13:collapse+one+first 2:3:13:collapse+one"
TREE_PICKABLE="1 2 3 4 5 6 8 10 11 12 14"
# One sequence of presses, a line per press: <row> <selection> <hidden> <missing>.
# The PowerShell twin prints the same lines for the same presses.
TREE_PRESSES="2 3 6 6 3 10 12 8 1 2"
tree_trace() {
    _UI_CHECKBOX_SELECTABLE="$TREE_PICKABLE"
    _tt_sel=""
    for _tt_k in $TREE_PRESSES; do
        _tt_sel="$(_ui_checkbox_toggle "$_tt_sel" 14 "$_tt_k")"
        _tt_sel="$(_ui_checkbox_apply_group "$_tt_sel" "$_tt_k" "$TREE_SPECS")"
        _tt_sorted="$(printf '%s' "$_tt_sel" | tr ',' '\n' | sort -n | paste -sd, -)"
        _UI_CHECKBOX_SPECS="$TREE_SPECS"
        _tt_hidden="$(_ui_checkbox_tree_hidden "$_tt_sel" | tr ' ' '\n' | sort -n | paste -sd' ' -)"
        printf '%s %s [%s] %s\n' "$_tt_k" "${_tt_sorted:--}" "$_tt_hidden" \
            "$(_ui_checkbox_tree_missing "$_tt_sel")"
    done
    _UI_CHECKBOX_SELECTABLE=""
}
TRACE="$(tree_trace)"
line() { printf '%s\n' "$TRACE" | sed -n "${1}p"; }
check "opening Lakehouse picks no catalog, shows the catalogs, and Enter would be refused" \
    "2 2 [4 5 6 7 9 11 12 13] 2" "$(line 1)"
check "picking a catalog pre-selects its first files option" "3 2,3,4 [9 11 12 13] " "$(line 2)"
check "picking another files option moves the radio" "6 2,3,6 [9 11 12 13] " "$(line 3)"
check "Space on the picked files option changes nothing" "6 2,3,6 [9 11 12 13] " "$(line 4)"
check "Space on the picked catalog keeps it and its files" "3 2,3,6 [9 11 12 13] " "$(line 5)"
check "picking another catalog closes the old branch; its first valid option (s3) is picked" \
    "10 2,10,11 [4 5 6 7 9] " "$(line 6)"
check "...and its own options can be picked" "12 2,10,12 [4 5 6 7 9] " "$(line 7)"
check "Glue has no files choice: picked alone, its note shown" "8 2,8 [4 5 6 7 11 12 13] " "$(line 8)"
check "another source is independent of the tree" "1 1,2,8 [4 5 6 7 11 12 13] " "$(line 9)"
check "unticking Lakehouse hides and clears its whole subtree" "2 1 [3 4 5 6 7 8 9 10 11 12 13] " "$(line 10)"
_UI_CHECKBOX_SPECS="$TREE_SPECS"
_UI_CHECKBOX_SELECTABLE="$TREE_PICKABLE"
check "the radio rows are the catalogs and the files, never a disabled row" \
    "4 5 6 11 12 3 8 10" "$(_ui_checkbox_tree_radio)"
_UI_CHECKBOX_SELECTABLE=""; _UI_CHECKBOX_SPECS=""
# A spec without a tree mode never reaches the tree rules: the any/all/master/
# claim behaviour is what it was.
check "an all-mode group still ticks every child with its parent" "1,2,3" \
    "$(_ui_checkbox_apply_group "1" 1 "1:2:3:all" | tr ',' '\n' | sort -n | paste -sd, -)"
_ui_checkbox_tree_begin "1:2:3:all 4:5:6:master"
check "a menu without tree specs has no tree state" "0| | " "$_UI_TREE_ON|$_UI_TREE_RADIO|$_UI_TREE_HIDDEN"
_ui_checkbox_tree_end

printf '\n== the PowerShell twins answer the same ==\n'
if command -v pwsh >/dev/null 2>&1; then
    PS_TRACE="$(TREE_SPECS="$TREE_SPECS" TREE_PICKABLE="$TREE_PICKABLE" TREE_PRESSES="$TREE_PRESSES" \
        pwsh -NoProfile -NonInteractive -File "$ROOT/tests/lib/tree-trace.ps1" "$ROOT" 2>&1)"
    check "Update-ExakitTreeGroup and friends: the same trace, press by press" "$TRACE" "$PS_TRACE"
    PS_OUT="$(pwsh -NoProfile -NonInteractive -File "$ROOT/tests/lakehouse-picker-ps.ps1" 2>&1)"; PS_RC=$?
    printf '%s\n' "$PS_OUT" | grep -E '^  (ok|FAIL) |^passed' | sed 's/^/    /'
    check "the PowerShell menus (tests/lakehouse-picker-ps.ps1) pass" "0" "$PS_RC"
else
    printf 'skip no pwsh on this machine: the twins are checked on CI and on Windows\n'
fi

if ! command -v python3 >/dev/null 2>&1; then
    printf 'skip no python3: the pty replays need it\n'
    printf '\n%d checks, %d failed\n' "$checks" "$fails"
    [ "$fails" -eq 0 ]; exit $?
fi

printf '\n== ui_checkbox_menu with tree specs, on a terminal ==\n'
cb() { # cb <keys> - the replay's report
    TTY_REPLAY_RAW="${TMPDIR:-/tmp}/tree-checkbox.raw" \
        python3 "$ROOT/tests/lib/tty-replay.py" "$ROOT/tests/lib/tree-checkbox-scenario.sh" "$ROOT" "Pick" "$1" 2>&1
}
OUT="$(cb 'j j j \r')"
has "the collapsed rows open under the ticked parent, as radio rows" "(•) Cat A" "$OUT"
check "...the first option is pre-picked, and Space on it keeps it" "SEL=2,3,4" "$(printf '%s\n' "$OUT" | grep '^SEL=')"
lacks "...a closed group's rows are not drawn" "note: automatic" "$(printf '%s\n' "$OUT" | sed -n '/FINAL/,/SEL=/p')"
OUT="$(cb 'j \rjj \r')"
check "Enter with an open group and nothing picked is refused; the cursor skips the hidden rows" \
    "SEL=2,7" "$(printf '%s\n' "$OUT" | grep '^SEL=')"
has "...and says what to pick" "Pick one of the options under Lake." "$(cat "${TMPDIR:-/tmp}/tree-checkbox.raw")"
has "...the picked catalog's note is drawn" "note: automatic" "$OUT"

printf '\n== exakit connect: the source menu ==\n'
pick() { # pick <keys> - the replay's report in PICK_OUT, its answer line in PICK
    PICK_OUT="$(TTY_REPLAY_COLS=100 python3 "$ROOT/tests/lib/tty-replay.py" \
        "$ROOT/tests/lib/lakehouse-picker-scenario.sh" "$ROOT" "Connect external sources" "$1" 2>&1)"
    PICK_RC=$?
    PICK="$(printf '%s\n' "$PICK_OUT" | grep '^PICKED=' | tail -1)"
}
LAKE='jjjjjjjjj '                                          # down to row 10, open it
# Every catalog x files path the engine accepts: 9.
while IFS='|' read -r label keys want; do
    [ -n "$label" ] || continue
    pick "$LAKE$keys\\r"
    check "$label" "$want" "$PICK"
    [ "$PICK_RC" = 0 ] || fail "...$label left more than one menu on screen (replay exit $PICK_RC)"
done <<'PATHS'
Iceberg REST + vended (pre-selected)|j |PICKED=lakehouse CATALOG=iceberg-rest FILES=vended RC=0
Iceberg REST + S3|j jj |PICKED=lakehouse CATALOG=iceberg-rest FILES=s3 RC=0
Iceberg REST + Azure|j jjj |PICKED=lakehouse CATALOG=iceberg-rest FILES=azure RC=0
Unity + vended (pre-selected)|jj |PICKED=lakehouse CATALOG=unity FILES=vended RC=0
Unity + S3|jj jj |PICKED=lakehouse CATALOG=unity FILES=s3 RC=0
Unity + Azure|jj jjj |PICKED=lakehouse CATALOG=unity FILES=azure RC=0
Glue (files automatic: S3)|jjj |PICKED=lakehouse CATALOG=glue FILES=s3 RC=0
No catalog + S3 (the first valid option, pre-selected)|jjjj |PICKED=lakehouse CATALOG=none FILES=s3 RC=0
No catalog + Azure|jjjj jj |PICKED=lakehouse CATALOG=none FILES=azure RC=0
PATHS

pick "${LAKE}jj jjj \\r"
check "the pick reaches the form as presets (exakit_vs_preset)" \
    "PRESET=lakehouse catalog=unity;lakehouse files=azure" "$(printf '%s\n' "$PICK_OUT" | grep '^PRESET=')"
pick "${LAKE}jjj \\r"
check "...Glue's implied files too" \
    "PRESET=lakehouse catalog=glue;lakehouse files=s3" "$(printf '%s\n' "$PICK_OUT" | grep '^PRESET=')"
pick 'jjjjjjjj \\r'
check "...and nothing for a source without a subtree" "PRESET=" "$(printf '%s\n' "$PICK_OUT" | grep '^PRESET=')"

printf '\n== the subtree is the lakehouse connector'"'"'s own settings ==\n'
TREE="$(_exakit_vs_lakehouse_tree)"
check "built from connectors/lakehouse/connector.json, not the fallback" "$(python3 -c '
import json, sys
st = json.load(open(sys.argv[1]))["settings"]
print(" ".join(c["value"] for c in st["catalog"]["choices"]), "|", " ".join(f["value"] for f in st["files"]["choices"]))' \
    "$ROOT/setup/virtual-schemas/connectors/lakehouse/connector.json")" \
    "$(printf '%s' "$TREE" | python3 -c 'import json, sys; t = json.load(sys.stdin); print(" ".join(c["id"] for c in t["catalogs"]), "|", " ".join(f["id"] for f in t["files"]))')"
check "...a catalog with one valid store (Glue) gets it as automatic" "s3" \
    "$(printf '%s' "$TREE" | python3 -c 'import json, sys; print(next(c.get("auto", "") for c in json.load(sys.stdin)["catalogs"] if c["id"] == "glue"))')"
check "...a store the engine marks disabled is never picked" "False" \
    "$(printf '%s' "$TREE" | python3 -c 'import json, sys; print(next(f["supported"] for f in json.load(sys.stdin)["files"] if f["id"] == "gcs"))')"
check "...the same tree as the built-in fallback for an older kit copy" \
    "$(exakit_vs_defs() { return 1; }; _exakit_vs_lakehouse_tree | python3 -c 'import json, sys; t = json.load(sys.stdin); print([(c["id"], c["label"], c["files"], c.get("auto")) for c in t["catalogs"]], [(f["id"], f["label"], f.get("supported", True)) for f in t["files"]])')" \
    "$(printf '%s' "$TREE" | python3 -c 'import json, sys; t = json.load(sys.stdin); print([(c["id"], c["label"], c["files"], c.get("auto")) for c in t["catalogs"]], [(f["id"], f["label"], f.get("supported", True)) for f in t["files"]])')"

pick "$LAKE\\r"
SCREEN="$(printf '%s\n' "$PICK_OUT" | sed -n '/=== FINAL SCREEN ===/,/=== tables on screen/p')"
check "Lakehouse open, Enter with no catalog is refused (the menu stays)" "" "$PICK"
has "...and says what to pick" "Pick one of the options under Lakehouse (Iceberg / Delta)." "$PICK_OUT"
has "...the catalogs hang under Lakehouse" "│  ├─ ( ) Iceberg REST catalog" "$SCREEN"
has "...the last catalog closes the branch" "│  └─ ( ) No catalog - Parquet files in a folder" "$SCREEN"
lacks "...no files are offered before a catalog is picked" "Let the catalog give access" "$SCREEN"
lacks "...no arrows on a parent row" "▸" "$SCREEN"
lacks "...in either direction" "▾" "$SCREEN"

pick "${LAKE}j jjjj \\r"
check "the cursor steps over the Google Cloud Storage row to the next catalog" \
    "PICKED=lakehouse CATALOG=unity FILES=vended RC=0" "$PICK"
pick "${LAKE}j "
SCREEN="$(printf '%s\n' "$PICK_OUT" | sed -n '/=== FINAL SCREEN ===/,/=== tables on screen/p')"
has "the picked catalog's files hang under it" "│  │  ├─ (•) Let the catalog give access" "$SCREEN"
has "...Google Cloud Storage is a row nobody can pick" "│  │  └─ Google Cloud Storage - not supported yet" "$SCREEN"
pick "${LAKE}jjj "
SCREEN="$(printf '%s\n' "$PICK_OUT" | sed -n '/=== FINAL SCREEN ===/,/=== tables on screen/p')"
has "Glue shows its files as a note, not a choice" "│  │  └─ files: Amazon S3 (automatic)" "$SCREEN"
pick "${LAKE}j jjjjjj \\r"
check "picking another catalog closes the old branch (No catalog, its first option: S3)" \
    "PICKED=lakehouse CATALOG=none FILES=s3 RC=0" "$PICK"
pick "${LAKE}j k k \\r"
check "unticking Lakehouse drops its catalog and files with it" \
    "PICKED=databricks CATALOG= FILES= RC=0" "$PICK"
pick " ${LAKE}jjj \\r"
check "Lakehouse goes with other sources" "PICKED=postgresql lakehouse CATALOG=glue FILES=s3 RC=0" "$PICK"
pick 'k\r'
check "Enter on Skip picks nothing" "PICKED= CATALOG= FILES= RC=5" "$PICK"

pick 'k'
SCREEN="$(printf '%s\n' "$PICK_OUT" | sed -n '/=== FINAL SCREEN ===/,/=== tables on screen/p')"
check "the menu has 11 sources" "11" "$(printf '%s\n' "$SCREEN" | grep -cE '^  │ \[ \] [├└]─ ')"
PICKER_OLD_CATALOG=1 pick 'k'
SCREEN="$(printf '%s\n' "$PICK_OUT" | sed -n '/=== FINAL SCREEN ===/,/=== tables on screen/p')"
check "...also while the catalog still lists iceberg-rest and unity: the one Lakehouse row folds them" \
    "11" "$(printf '%s\n' "$SCREEN" | grep -cE '^  │ \[ \] [├└]─ ')"
lacks "...no Unity row of its own" "Unity Catalog (lakehouse engine)" "$SCREEN"

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
