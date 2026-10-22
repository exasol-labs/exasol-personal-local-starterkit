#!/usr/bin/env bash
# notebook-tools-table.sh — the notebook add-on's tools (JupyterLab, Marimo,
# Positron) are CHILD ROWS of its row in the marketplace's add-ons table, one
# level deeper in the tree, ticked right there; there is no separate "Notebook
# tools" checklist on that path. Each row says before anything installs what
# will become of its tool, and then how the install settled it.
#
#   bash tests/notebook-tools-table.sh
#
# What it pins:
#   - the tree: "│  ├─ JupyterLab" under a notebook row drawn as a tee,
#     "   ├─ ..." under a corner (the persona closing offer), the last child a
#     corner; at 80 columns every notebook row is whole
#   - the Version column carries the versions.json pins; the Description says
#     whether a JupyterLab / Positron was found (no network: the find helpers)
#   - the ticks: Enter keeps all three; unticking Marimo, unticking the notebook
#     (its tools go too, and it is not installed), ticking a tool while the
#     notebook is unticked (the notebook comes back) - and the ticked tools
#     reach the install as EXAKIT_NOTEBOOK_FRONTENDS without its question hook
#   - one table on screen during and after the install, each tool row with its
#     own final status
#   - the group rule ("claim"), the default ticks from the record or the
#     variable, and the scripted path that draws no table keeping the hook
#
# A real pty (tests/lib/tty-replay.py) drives shipping code with stubbed probes
# and installs (tests/lib/notebook-tools-scenario.sh). Sandboxed; no network,
# nothing installed.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib/utf8-locale.sh"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;; *) FAIL=$((FAIL + 1)); printf '  FAIL %s: [%s] not found\n' "$1" "$2" ;; esac; }
lacks() { case "$3" in *"$2"*) FAIL=$((FAIL + 1)); printf '  FAIL %s: [%s] present\n' "$1" "$2" ;; *) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;; esac; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PIN_J="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["components"]["notebook"]["frontends"]["jupyterlab"])' "$ROOT/versions.json")"
PIN_M="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["components"]["notebook"]["frontends"]["marimo"])' "$ROOT/versions.json")"

# replay <keys> [VAR=value ...] — the scenario under a pty; sets OUT and SCREEN.
replay() {
    _r_keys="$1"; shift
    OUT="$(env "$@" python3 "$ROOT/tests/lib/tty-replay.py" "$ROOT/tests/lib/notebook-tools-scenario.sh" \
        "$ROOT" "Marketplace add-ons" "$_r_keys" 2>&1)"
    SCREEN="$(printf '%s\n' "$OUT" | sed -n '/=== FINAL SCREEN ===/,/=== tables on screen/p')"
}
# row <label> — the screen line carrying that row's label.
row() { printf '%s\n' "$SCREEN" | grep -- "$1" | head -1; }
# widest — the widest line on the screen, in characters.
widest() { printf '%s\n' "$SCREEN" | python3 -c 'import sys; print(max(len(l.rstrip("\n")) for l in sys.stdin))'; }

if ! command -v python3 >/dev/null 2>&1 || [ -z "${EXAKIT_TEST_UTF8_LOCALE:-}" ]; then
    check "python3 and a UTF-8 locale for the pty replay" "skipped" "skipped"
else
    echo "the selection: the tools are the notebook row's children, at 80 columns:"
    replay '\r' NBT_STOP=menu
    check "one table on screen" "1" "$(printf '%s\n' "$SCREEN" | grep -c '╭─ Marketplace add-ons')"
    has "the notebook row is a tee"                      "├─ notebook"       "$SCREEN"
    has "JupyterLab hangs off it, its spine carried on"   "│  ├─ JupyterLab"  "$SCREEN"
    has "Marimo too"                                     "│  ├─ Marimo"      "$SCREEN"
    has "Positron is the last of them"                   "│  └─ Positron"    "$SCREEN"
    has "the next add-on closes the tree"                "└─ demo-alpha"     "$SCREEN"
    lacks "nothing cut short"                            "…"                 "$SCREEN"
    check "nothing past 80 columns" "yes" "$([ "$(widest)" -le 80 ] && echo yes || echo "no: $(widest)")"
    has "JupyterLab shows its pin"                       "$PIN_J"            "$(row '├─ JupyterLab')"
    has "Marimo shows its pin"                           "$PIN_M"            "$(row '├─ Marimo')"
    # The Version column starts where JupyterLab's pin does; Positron's is blank.
    _vcol="$(row '├─ JupyterLab' | python3 -c 'import sys; l=sys.stdin.read(); print(l.index(sys.argv[1]))' "$PIN_J")"
    check "Positron has no version" "" "$(row '└─ Positron' | python3 -c 'import sys; print(sys.stdin.read()[int(sys.argv[1]):int(sys.argv[1])+6].strip())' "$_vcol")"
    has "no JupyterLab here: the kit installs one"       "not on this machine: installed into the" "$(row '├─ JupyterLab')"
    has "no Positron here: the folder is prepared"       "not on this machine: the notebooks folder" "$(row '└─ Positron')"
    has "all three ticked"                               "[✓] │  ├─ Marimo"  "$SCREEN"
    has "Select All ticked"                              "[✓] Select All"    "$SCREEN"
    has "Enter keeps all three"                          "FRONTENDS=jupyterlab,marimo,positron" "$OUT"
    has "...and the add-ons picked are the add-ons"      "PICKED=notebook,demo-alpha" "$OUT"
    lacks "no separate Notebook tools checklist"         "Notebook tools"    "$OUT"

    echo "the descriptions say what was found:"
    replay '\r' NBT_STOP=menu NBT_JUPYTER=own NBT_POSITRON=yes
    has "a JupyterLab on PATH is used as it is"          "yours (/opt/tools/bin/jupyter-lab) is" "$SCREEN"
    has "a Positron here is pointed at the kit's Python" "yours: pointed at the kit's Python" "$(row '└─ Positron')"

    echo "the persona closing offer shows the same children, under a corner:"
    replay '\r' NBT_STOP=menu NBT_ONLY=notebook
    has "the offer's heading"                            "Add-ons for your personas" "$SCREEN"
    has "the notebook is the only row: a corner"         "└─ notebook"       "$SCREEN"
    has "its children carry no spine of its"             "[✓]    ├─ JupyterLab" "$SCREEN"
    has "...the last one a corner"                       "[✓]    └─ Positron" "$SCREEN"
    check "nothing past 80 columns there either" "yes" "$([ "$(widest)" -le 80 ] && echo yes || echo "no: $(widest)")"
    has "Enter keeps all three there too"                "FRONTENDS=jupyterlab,marimo,positron" "$OUT"

    echo "the install fills the same table in, tool by tool:"
    replay '\r'
    has "one table, during and after the install"        "tables on screen: 1 top borders, 1 bottom borders" "$OUT"
    has "...at every instant"                            "worst instant: 1 tables on screen" "$OUT"
    has "the install got all three"                      "FRONTENDS=jupyterlab,marimo,positron" "$OUT"
    has "...without its question hook"                   "QUESTIONS=none"    "$OUT"
    has "both add-ons installed"                         "INSTALLED=notebook demo-alpha" "$OUT"
    has "JupyterLab: the kit's, at its pin"              "✓ installed $PIN_J" "$(row '├─ JupyterLab')"
    has "Marimo: at its pin"                             "✓ installed $PIN_M" "$(row '├─ Marimo')"
    has "Positron: not here, the folder is ready"        "not on this machine - folder ready" "$(row '└─ Positron')"
    has "the notebook row finished too"                  "✓ notebooks: exakit notebook" "$(row '├─ notebook')"
    lacks "no half-drawn bar left behind"                "░"                 "$SCREEN"

    echo "unticking Marimo leaves it out:"
    replay 'jj \r' NBT_JUPYTER=own NBT_POSITRON=yes
    has "the install got the other two"                  "FRONTENDS=jupyterlab,positron" "$OUT"
    has "Select All let go"                              "[ ] Select All"    "$SCREEN"
    has "Marimo: skipped"                                "skipped"           "$(row '├─ Marimo')"
    has "JupyterLab: yours, with the kernel"             "✓ yours, kernel added" "$(row '├─ JupyterLab')"
    has "Positron: configured"                           "✓ configured"      "$(row '└─ Positron')"
    has "one table"                                      "tables on screen: 1 top borders, 1 bottom borders" "$OUT"

    echo "unticking the notebook unticks its tools, and it is not installed:"
    replay ' \r'
    has "the notebook row unticked"                      "[ ] ├─ notebook"   "$SCREEN"
    has "...JupyterLab with it"                          "[ ] │  ├─ JupyterLab" "$SCREEN"
    has "...Marimo"                                      "[ ] │  ├─ Marimo"  "$SCREEN"
    has "...Positron"                                    "[ ] │  └─ Positron" "$SCREEN"
    has "only the other add-on installed"                "INSTALLED=demo-alpha" "$OUT"
    has "the notebook never ran"                         "FRONTENDS=not-installed" "$OUT"

    echo "ticking a tool while the notebook is unticked ticks the notebook:"
    replay ' j \r'
    has "the notebook came back"                         "[✓] ├─ notebook"   "$SCREEN"
    has "...with that one tool"                          "[✓] │  ├─ JupyterLab" "$SCREEN"
    has "...and not the others"                          "[ ] │  ├─ Marimo"  "$SCREEN"
    has "the install got that one tool"                  "FRONTENDS=jupyterlab" "$OUT"
    has "the others: skipped"                            "skipped"           "$(row '└─ Positron')"
fi

echo "the pieces, without a terminal:"
(
    export HOME="$WORK/home" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
    mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
    unset EXAKIT_NOTEBOOK_FRONTENDS EXAKIT_NOTEBOOK_JUPYTER EXAKIT_NOTEBOOK_MARIMO
    . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/notebook.sh"
    run_python_any() { python3 "$@"; }
    EXAKIT_LOG_FILE="$WORK/log"; : > "$EXAKIT_LOG_FILE"
    manifest_get() { [ "$1" = components.notebook.front_ends ] && [ -n "${NBT_RECORDED:-}" ] && printf '%s\n' "$NBT_RECORDED"; }
    notebook_find_jupyter() { return 1; }
    notebook_find_positron() { return 1; }
    notebook_marimo_installed() { return 1; }
    printf 'CHILDREN %s\n' "$(notebook_table_children | cut -d'|' -f1,5 | tr '\n' ' ')"
    printf 'RECORDED %s\n' "$(NBT_RECORDED=jupyterlab,positron notebook_table_children | cut -d'|' -f1,5 | tr '\n' ' ')"
    printf 'VARIABLE %s\n' "$(EXAKIT_NOTEBOOK_FRONTENDS=marimo notebook_table_children | cut -d'|' -f1,5 | tr '\n' ' ')"
    printf 'SKIPVAR %s\n' "$(EXAKIT_NOTEBOOK_MARIMO=skip notebook_table_children | cut -d'|' -f1,5 | tr '\n' ' ')"
    notebook_default_front_ends; _d_rc=$?
    printf 'DEFAULT %s|%s\n' "$_d_rc" "$NOTEBOOK_FRONT_ENDS"
    printf 'PICKED1 %s\n' "$(notebook_table_children_picked "jupyterlab,positron"; printf '%s' "$EXAKIT_NOTEBOOK_FRONTENDS")"
    printf 'PICKED0 %s\n' "$(notebook_table_children_picked ""; printf '%s' "$EXAKIT_NOTEBOOK_FRONTENDS")"
    # The table the marketplace builds from them: ids, defaults, group specs.
    EXAKIT_ADDON_TABLE_CHILDREN="$(notebook_table_children | sed 's/^/notebook|/')"
    EXAKIT_ADDON_TABLE_META=""; EXAKIT_ADDON_TABLE_DISABLED=""
    _exakit_addon_table_build "$WORK/t" notebook demo-alpha
    printf 'KINDS %s\n' "$(cut -d'|' -f1 "$WORK/t" | tr '\n' ' ')"
    printf 'IDS %s\n' "$(printf '%s' "$EXAKIT_ADDON_TABLE_IDS" | tr '\n' ',')"
    printf 'GROUP %s\n' "$EXAKIT_TABLE_GROUP"
    printf 'DEFAULTS %s\n' "$EXAKIT_TABLE_DEFAULTS"
    printf 'SKIP %s\n' "$EXAKIT_ADDON_TABLE_ROW_SKIP"
    printf 'KIDROWS %s\n' "$(_exakit_addon_table_child_rows notebook)"
    printf 'NOKIDS [%s]\n' "$(_exakit_addon_table_child_rows demo-alpha)"
    printf 'ROW %s\n' "$(_exakit_addon_table_row notebook)"
    # A recorded choice without Marimo: its row starts unticked, and so does
    # Select All.
    EXAKIT_ADDON_TABLE_CHILDREN="$(NBT_RECORDED=jupyterlab,positron notebook_table_children | sed 's/^/notebook|/')"
    _exakit_addon_table_build "$WORK/t" notebook demo-alpha
    printf 'RDEFAULTS %s\n' "$EXAKIT_TABLE_DEFAULTS"
    # Questions: skipped where the rows answered, asked where no table was drawn.
    notebook_questions() { printf 'ASKED '; }
    EXAKIT_ADDON_TABLE_STATE="$WORK/t"
    printf 'TABLEQ [%s]\n' "$(_exakit_marketplace_questions notebook)"
    EXAKIT_ADDON_TABLE_STATE=""
    printf 'SCRIPTQ [%s]\n' "$(_exakit_marketplace_questions notebook)"
    # The child-row reporter: a no-op without a live table.
    printf 'NOTABLE %s\n' "$(exakit_addon_table_child marimo done "installed" && echo set || echo plain)"
) > "$WORK/pieces" 2>&1
P="$(cat "$WORK/pieces")"
has "all three ticked by default"                 "CHILDREN jupyterlab|1 marimo|1 positron|1" "$P"
has "a recorded choice decides the ticks"         "RECORDED jupyterlab|1 marimo|0 positron|1" "$P"
has "EXAKIT_NOTEBOOK_FRONTENDS decides them"      "VARIABLE jupyterlab|0 marimo|1 positron|0" "$P"
has "EXAKIT_NOTEBOOK_MARIMO=skip leaves one out"  "SKIPVAR jupyterlab|1 marimo|0 positron|1" "$P"
has "the default helper does not ask, and says it is only a default" "DEFAULT 1|jupyterlab,marimo,positron" "$P"
has "ticked rows become the answer"               "PICKED1 jupyterlab,positron" "$P"
has "no ticked row is none"                       "PICKED0 none" "$P"
has "the rows' kinds"                             "KINDS group tee tee-tee tee-tee tee-corner corner plain" "$P"
has "child ids are <id>:<key>"                    "IDS ,notebook,notebook:jupyterlab,notebook:marimo,notebook:positron,demo-alpha,," "$P"
has "the notebook is a claim parent inside Select All" "GROUP 2:3:5:claim 1:2:6:all" "$P"
has "every row ticked"                            "DEFAULTS 1,2,3,4,5,6" "$P"
has "Skip moves down past the children"           "SKIP 7" "$P"
has "the child rows are found by key"             "KIDROWS jupyterlab:3,marimo:4,positron:5" "$P"
has "an add-on without children has none"         "NOKIDS []" "$P"
has "the add-on row is still the add-on's"        "ROW 2" "$P"
has "an unticked tool unticks Select All"         "RDEFAULTS 2,3,5,6" "$P"
has "the table answered: no question"             "TABLEQ []" "$P"
has "no table: the hook is asked"                 "SCRIPTQ [ASKED ]" "$P"
has "no live table: the caller's line is the record" "NOTABLE plain" "$P"

echo "the claim rule, alone:"
(
    # Assigned first: bash 3.2 (see tests/bash32-guard.sh).
    _helpers='/^_ui_checkbox_toggle()/,/^}/p;/^_ui_checkbox_group_children()/,/^}/p;/^_ui_checkbox_apply_group()/,/^}/p;/^_ui_checkbox_apply_one_group()/,/^}/p'
    eval "$(sed -n "$_helpers" "$ROOT/setup/lib/common.sh")"
    _UI_CHECKBOX_SELECTABLE=""
    G="2:3:5:claim 1:2:6:all"
    press() { _p_s="$(_ui_checkbox_toggle "$1" 7 "$2")"; _ui_checkbox_apply_group "$_p_s" "$2" "$G" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$//'; }
    printf 'A %s\n' "$(press 1,2,3,4,5,6 2)"     # untick the notebook
    printf 'B %s\n' "$(press 6 3)"               # tick a tool, notebook unticked
    printf 'C %s\n' "$(press 2,3,6 3)"           # untick the last ticked tool
    printf 'D %s\n' "$(press 1,2,3,4,5,6 4)"     # untick one tool
    printf 'E %s\n' "$(press 6 1)"               # Select All
    printf 'F %s\n' "$(press 2,6 2)"             # untick the notebook with no tools
) > "$WORK/claim" 2>&1
C="$(cat "$WORK/claim")"
has "unticking the notebook unticks its tools and Select All" "A 6" "$C"
has "ticking a tool ticks the notebook"            "B 2,3,6" "$C"
has "the notebook may stand with no tool"          "C 2,6" "$C"
has "one tool unticked lets Select All go, not the notebook" "D 2,3,5,6" "$C"
has "Select All covers the tools too"              "E 1,2,3,4,5,6" "$C"
has "the notebook unticked alone"                  "F 6" "$C"

echo "the twins carry the same pieces:"
NB_PS="$(cat "$ROOT/setup/lib/notebook.ps1")"
CO_PS="$(cat "$ROOT/setup/lib/exakit-common.ps1")"
UI_PS="$(cat "$ROOT/setup/lib/ui.ps1")"
has "the registry names the children hook"        'ChildrenFn  = "Get-NotebookTableChildren"' "$CO_PS"
has "...and the answer hook"                       'ChildrenPickedFn = "Set-NotebookTableChildrenPicked"' "$CO_PS"
has "the table menu takes nested groups"           '[string[]]$Groups = @(),' "$UI_PS"
has "...with the claim rule"                       '$gmode -eq "claim"' "$UI_PS"
has "the checkbox menu knows it too"               '$gmode -eq "claim"' "$CO_PS"
has "the deeper connectors"                        '"tee-tee"' "$UI_PS"
has "a tool settles its row on Windows"            'Set-ExakitAddonTableChild -Key "marimo"' "$NB_PS"
has "the default helper on Windows"                'function Get-NotebookDefaultFrontEnds' "$NB_PS"

printf '\nnotebook-tools-table.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
