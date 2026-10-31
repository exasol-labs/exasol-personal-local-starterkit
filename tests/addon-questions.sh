#!/usr/bin/env bash
# addon-questions.sh — an add-on that asks something at install asks it BEFORE
# the marketplace's progress table animates (the optional <id>_questions hook),
# never under it. Asked from inside the install, the notebook add-on's "Notebook
# tools" checklist was redrawn over by the live table: two frames on screen and
# the question's text bleeding through at the right edge.
#
#   bash tests/addon-questions.sh
#
# A real pty (tests/lib/tty-replay.py) drives shipping code with stub add-ons
# (tests/lib/addon-questions-scenario.sh). Also pins the hook in both twins.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;; *) FAIL=$((FAIL + 1)); printf '  FAIL %s: [%s] not found\n' "$1" "$2" ;; esac; }

echo "the question comes first, then one table:"
if command -v python3 >/dev/null 2>&1; then
    out="$(python3 "$ROOT/tests/lib/tty-replay.py" "$ROOT/tests/lib/addon-questions-scenario.sh" "$ROOT" "Demo tools" '\r' 2>&1)"
    screen="$(printf '%s\n' "$out" | sed -n '/=== FINAL SCREEN ===/,/=== tables on screen/p')"
    check "exactly one add-ons table on screen" "1" "$(printf '%s\n' "$screen" | grep -c '╭─ Add-ons to install')"
    check "...with one bottom border" "1" "$(printf '%s\n' "$screen" | grep -c '╰')"
    check "the question is above the table, whole" "1" "$(printf '%s\n' "$screen" | grep -c 'Demo tools - untick any you do not want')"
    check "no question text inside the frame" "0" "$(printf '%s\n' "$screen" | grep '│' | grep -c 'Tool one\|Tool two')"
    has "the install got the answer" "ANSWER=1,2" "$out"
    has "both add-ons finished in that table" "demo-beta   ✓ installed" "$screen"
else
    check "python3 for the pty replay" "skipped" "skipped"
fi

echo "keys typed while the table animates do not move it:"
if command -v python3 >/dev/null 2>&1; then
    # Three Enters while the installs run: echoed, each moved the cursor a line
    # and the next frame drew below the last - four frames stacked on screen.
    out="$(python3 "$ROOT/tests/lib/tty-replay.py" "$ROOT/tests/lib/addon-table-scenario.sh" "$ROOT" "Add-ons to install" '\r\r\r' 2 2>&1)"
    has "one table on screen, Enter pressed three times during the install" "tables on screen: 1 top borders" "$out"
    has "...at every instant" "worst instant: 1 tables on screen" "$out"
fi
_begin_range='/^ui_table_begin() {/,/^}/p'      # assigned first: bash 3.2
_end_range='/^ui_table_end() {/,/^}/p'
has "the shell twin holds the keys while it animates" "_ui_input_hold" "$(sed -n "$_begin_range" "$ROOT/setup/lib/ui.sh")"
has "...and lets go (and drops them) when it ends" "_ui_input_release" "$(sed -n "$_end_range" "$ROOT/setup/lib/ui.sh")"
has "the Windows twin drops them too" "while ([Console]::KeyAvailable)" "$(cat "$ROOT/setup/lib/ui.ps1")"

echo "the hook, in both twins:"
ECOMMON="$(cat "$ROOT/setup/lib/exakit-common.ps1")"
_apply_range='/^_exakit_marketplace_apply_python() {/,/ui_table_begin/p'          # assigned first: bash 3.2
_apply_ps_range='/^function Invoke-ExakitMarketplaceApplyPython {/,/Start-ExakitTable/p'
has "apply asks the questions before the table starts" '_exakit_marketplace_questions "$1"' \
    "$(sed -n "$_apply_range" "$ROOT/setup/lib/common.sh")"
has "...and so does the twin" 'Invoke-ExakitMarketplaceQuestions -Ids $Ids' \
    "$(sed -n "$_apply_ps_range" "$ROOT/setup/lib/exakit-common.ps1")"
has "the notebook add-on asks through the hook" "notebook_questions()" "$(cat "$ROOT/setup/lib/common.sh")"
has "...its twin is registered" 'QuestionsFn = "Read-NotebookQuestions"' "$ECOMMON"
has "...and exports the answer the install reads" 'export EXAKIT_NOTEBOOK_FRONTENDS' "$(cat "$ROOT/setup/lib/common.sh")"
# Where the table carried the add-on's own child rows (the notebook's tools),
# those rows were the question: the hook is not asked again, and the frame is
# left for the progress to fill in. tests/notebook-tools-table.sh drives it.
_q_range='/^_exakit_marketplace_questions() {/,/^}/p'       # assigned first: bash 3.2
_q_ps_range='/^function Invoke-ExakitMarketplaceQuestions {/,/^}/p'
has "an add-on whose child rows answered is not asked again" '_exakit_addon_table_child_rows "$_mq_id"' \
    "$(sed -n "$_q_range" "$ROOT/setup/lib/common.sh")"
has "...nor on Windows" 'Get-ExakitAddonTableChildRows -Id $addon.Id' \
    "$(sed -n "$_q_ps_range" "$ROOT/setup/lib/exakit-common.ps1")"

printf '\naddon-questions.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
