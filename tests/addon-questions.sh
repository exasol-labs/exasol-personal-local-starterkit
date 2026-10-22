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

echo "the hook, in both twins:"
ECOMMON="$(cat "$ROOT/setup/lib/exakit-common.ps1")"
_apply_range='/^_exakit_marketplace_apply() {/,/ui_table_begin/p'          # assigned first: bash 3.2
_apply_ps_range='/^function Invoke-ExakitMarketplaceApply {/,/Start-ExakitTable/p'
has "apply asks the questions before the table starts" '_exakit_marketplace_questions "$1"' \
    "$(sed -n "$_apply_range" "$ROOT/setup/lib/common.sh")"
has "...and so does the twin" 'Invoke-ExakitMarketplaceQuestions -Ids $Ids' \
    "$(sed -n "$_apply_ps_range" "$ROOT/setup/lib/exakit-common.ps1")"
has "the notebook add-on asks through the hook" "notebook_questions()" "$(cat "$ROOT/setup/lib/notebook.sh")"
has "...its twin is registered" 'QuestionsFn = "Read-NotebookQuestions"' "$ECOMMON"
has "...and exports the answer the install reads" 'EXAKIT_NOTEBOOK_FRONTENDS="$NOTEBOOK_FRONT_ENDS"' "$(cat "$ROOT/setup/lib/notebook.sh")"

printf '\naddon-questions.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
