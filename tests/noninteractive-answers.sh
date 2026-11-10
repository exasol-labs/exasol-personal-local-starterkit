#!/usr/bin/env bash
# noninteractive-answers.sh — proves the install honours pre-set environment
# answers so an agent-driven or scripted install (no tty) is deterministic
# instead of silently taking defaults. Pure logic: sources the shared lib and
# exercises confirm_env() and the MCP client selection parser. No installs.
#
#   bash tests/noninteractive-answers.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

# shellcheck source=/dev/null
. "$ROOT/setup/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/exapump.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "confirm_env — an env var pre-answers the question:"
EXAKIT_TEST_ANS=1; if confirm_env EXAKIT_TEST_ANS "q" n; then r=yes; else r=no; fi
check "var=1 (default n)" yes "$r"
EXAKIT_TEST_ANS=yes; if confirm_env EXAKIT_TEST_ANS "q" n; then r=yes; else r=no; fi
check "var=yes (default n)" yes "$r"
EXAKIT_TEST_ANS=0; if confirm_env EXAKIT_TEST_ANS "q" y; then r=yes; else r=no; fi
check "var=0 (default y)" no "$r"
EXAKIT_TEST_ANS=no; if confirm_env EXAKIT_TEST_ANS "q" y; then r=yes; else r=no; fi
check "var=no (default y)" no "$r"

echo "confirm_env — unset var falls back to the default (no tty available):"
unset EXAKIT_TEST_ANS
if confirm_env EXAKIT_TEST_ANS "q" y </dev/null; then r=yes; else r=no; fi
check "unset -> default y" yes "$r"
if confirm_env EXAKIT_TEST_ANS "q" n </dev/null; then r=yes; else r=no; fi
check "unset -> default n" no "$r"

echo "the runtime update offer — an unattended run is never asked, so it never stops a database:"
# `exakit update` applies the runtime (which stops the database) only for an answer
# it was actually given. These are the two things that decide it: the pre-answer
# and whether there is a terminal at all.
unset EXAKIT_CONFIRM_RUNTIME_UPDATE
_upd_assume_yes=0
check "nobody has answered yet" "" "$(exakit_runtime_update_preanswer)"
EXAKIT_CONFIRM_RUNTIME_UPDATE=1
check "EXAKIT_CONFIRM_RUNTIME_UPDATE=1 opts in" "yes" "$(exakit_runtime_update_preanswer)"
EXAKIT_CONFIRM_RUNTIME_UPDATE=no
check "=no is a deliberate refusal" "no" "$(exakit_runtime_update_preanswer)"
EXAKIT_CONFIRM_RUNTIME_UPDATE=maybe
check "an unrecognised value answers nothing" "" "$(exakit_runtime_update_preanswer)"
unset EXAKIT_CONFIRM_RUNTIME_UPDATE
_upd_assume_yes=1
check "--yes opts in for one run" "yes" "$(exakit_runtime_update_preanswer)"
_upd_assume_yes=0
if exakit_stdin_is_tty </dev/null; then r=terminal; else r=no-terminal; fi
check "a redirected stdin is not a terminal" "no-terminal" "$r"

echo "EXAKIT_MCP_CLIENTS — client selection parses names, 'all', and numbers:"
# "claude" (or 1) expands to both Claude surfaces (desktop app + Claude Code
# CLI); "all" covers every supported client. Keep these in lockstep with
# exakit_parse_mcp_client_selection in setup/lib/common.sh.
check "claude,cursor" "claude_desktop,claude_code,cursor" "$(exakit_parse_mcp_client_selection "claude,cursor")"
check "all"           "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue" "$(exakit_parse_mcp_client_selection "all")"
check "1,2"           "claude_desktop,claude_code,codex" "$(exakit_parse_mcp_client_selection "1,2")"
check "opencode"      "opencode" "$(exakit_parse_mcp_client_selection "opencode")"
check "number 6"      "opencode" "$(exakit_parse_mcp_client_selection "6")"
check "continue"      "continue" "$(exakit_parse_mcp_client_selection "continue")"
check "number 7"      "continue" "$(exakit_parse_mcp_client_selection "7")"
check "dedupes"       "claude_desktop,claude_code" "$(exakit_parse_mcp_client_selection "claude,1,claude")"
check "single surface" "claude_code" "$(exakit_parse_mcp_client_selection "claude_code")"
check "copilot"       "vscode_copilot" "$(exakit_parse_mcp_client_selection "copilot")"
check "gemini"        "gemini_cli" "$(exakit_parse_mcp_client_selection "gemini")"
if exakit_parse_mcp_client_selection "bogus" >/dev/null 2>&1; then r=accepted; else r=rejected; fi
check "invalid rejected" rejected "$r"
# The same answer, however it is typed: case, spaces and a trailing comma do not matter, as on Windows
# (PowerShell's switch is case-free); empty and the callers' own words ("skip") are not clients.
check "case and spaces" "claude_desktop,claude_code,cursor" "$(exakit_parse_mcp_client_selection " Claude , Cursor ")"
check "upper case"      "claude_desktop,claude_code" "$(exakit_parse_mcp_client_selection "CLAUDE")"
check "trailing comma"  "claude_desktop,claude_code" "$(exakit_parse_mcp_client_selection "claude,")"
check "ALL with spaces" "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue" "$(exakit_parse_mcp_client_selection " ALL ")"
for _bad in "" "  " "," "skip" "none" "all,claude"; do
    if exakit_parse_mcp_client_selection "$_bad" >/dev/null 2>&1; then r=accepted; else r=rejected; fi
    check "[$_bad] is not a selection" rejected "$r"
done

echo "EXAKIT_DATA_FILE — naming a file answers the data-load menu:"
# The var IS the choice: with it set, exakit_data_load_select must pick the
# local-file option without drawing a menu, even with no tty at all. A revert
# leaves the checkbox menu in charge, whose no-tty defaults are the pending
# datasets or the opt-out — never "local".
EXAKIT_DATA_FILE=x
EXAKIT_DATA_LOAD_SELECTION=""
EXAKIT_HOME="$WORK/home" exakit_data_load_select "Cancel" </dev/null >/dev/null 2>&1
check "selection is local, no menu drawn" "local" "$EXAKIT_DATA_LOAD_SELECTION"
unset EXAKIT_DATA_FILE

echo "Every dataset already loaded, no tty — nothing is asked, nothing fails:"
# The local-file row is pre-ticked when nothing is pending, so Enter does
# something. With no terminal that default stood: the loader asked for a path
# nobody could give and the installer's rerun ended "one step did not complete".
(
    exakit_pending_datasets() { :; }
    EXAKIT_DATA_LOAD_SELECTION=""
    UI_FANCY=0 EXAKIT_HOME="$WORK/home" exakit_data_load_select "Skip" </dev/null > "$WORK/all-loaded.out" 2>&1
    echo "$EXAKIT_DATA_LOAD_SELECTION" > "$WORK/all-loaded.sel"
)
check "selection is none, not local" "none" "$(cat "$WORK/all-loaded.sel")"
check "...and says how to load a file unattended" "yes" \
    "$(grep -q 'name it with EXAKIT_DATA_FILE' "$WORK/all-loaded.out" && echo yes || echo no)"

echo "EXAKIT_DATA_FILE — a bad path fails instead of looping (no tty):"
# Without a tty, prompt_text hands back the same default forever, so a
# nonexistent EXAKIT_DATA_FILE must make exakit_load_local_file return
# nonzero, not re-ask. The reverted behaviour is an infinite re-prompt loop,
# so the probe runs in a background job that is killed after ~10s — a hung
# test tells nobody anything.
(
    EXAKIT_DATA_FILE=/nonexistent/file.csv
    export EXAKIT_DATA_FILE
    # In its own subshell: a refused file EXITS the loader with 3 (bad input,
    # which its callers turn into exit 2), exactly as the real callers run it.
    ( exakit_load_local_file </dev/null >/dev/null 2>&1 )
    echo "rc=$?" > "$WORK/local-file-rc"
) &
_lf_pid=$!
_lf_n=0
while kill -0 "$_lf_pid" 2>/dev/null && [ "$_lf_n" -lt 20 ]; do
    sleep 0.5
    _lf_n=$((_lf_n + 1))
done
if kill -0 "$_lf_pid" 2>/dev/null; then
    kill "$_lf_pid" 2>/dev/null
    wait "$_lf_pid" 2>/dev/null
    check "bad EXAKIT_DATA_FILE is refused promptly (exit 3 = bad input)" "rc=3" "HUNG-KILLED-AFTER-10S"
else
    wait "$_lf_pid" 2>/dev/null
    check "bad EXAKIT_DATA_FILE is refused promptly (exit 3 = bad input)" "rc=3" "$(cat "$WORK/local-file-rc" 2>/dev/null || echo "no-rc-recorded")"
fi

echo "the install's data answers - each row its own, in the table's order:"
# The real installer step (exakit_maybe_offer_data_load) with the loaders as
# stubs: what ran, in order, then its status. `external` names the
# external-source row: unattended it is only ever the command to run - the
# wizard (a stub here that says CONNECT) is never started.
offer() { # offer — LOAD/FILE/CONNECT in order~rc~what was said~NOTE=the failure note
    (
        # OFFER_FAIL names a dataset whose load fails; OFFER_FILE_RC is what the
        # file loader answers (3: refused, 1: failed). The failure note is kept.
        exakit_load_dataset() { printf 'LOAD %s\n' "$2" >> "$WORK/offer.log"; [ "$2" != "${OFFER_FAIL:-}" ]; }
        exakit_load_sample_data() { printf 'LOAD tpch(sample)\n' >> "$WORK/offer.log"; }
        exakit_load_local_file() { printf 'FILE %s\n' "$EXAKIT_DATA_FILE" >> "$WORK/offer.log"; echo "FILE-RAN"; return "${OFFER_FILE_RC:-0}"; }
        exakit_vs_connect_wizard() { printf 'CONNECT\n' >> "$WORK/offer.log"; }
        exakit_bundled_datasets() { printf 'tpch|TPC-H\nenergy|Energy\namazon_sales|Amazon\n'; }
        exakit_note_failure() { printf '%s' "$*" > "$WORK/offer.note"; }
        _exakit_prompt_tty() { :; }
        : > "$WORK/offer.log"; : > "$WORK/offer.note"
        EXAKIT_HOME="$WORK/home" exakit_maybe_offer_data_load "$ROOT" </dev/null > "$WORK/offer.out" 2>&1
        _o_rc=$?
        printf '%s~rc=%s~%s~NOTE=%s' "$(tr '\n' ';' < "$WORK/offer.log")" "$_o_rc" "$(tr '\n' ' ' < "$WORK/offer.out")" "$(cat "$WORK/offer.note")"
    )
}
unset EXAKIT_DATASETS EXAKIT_LOAD_SAMPLE EXAKIT_DATA_FILE
out="$(EXAKIT_DATASETS=tpch,external offer)"
check "EXAKIT_DATASETS=tpch,external: the dataset loads, the wizard does not start" "LOAD tpch;~rc=0" "$(printf '%s' "$out" | cut -d'~' -f1,2)"
check "...the external row is one line naming the command" "yes" \
    "$(printf '%s' "$out" | grep -q 'needs a terminal. Connect one any time with: exakit connect' && echo yes || echo no)"
check "...and external is not an unknown id" "no" "$(printf '%s' "$out" | grep -q "Unknown dataset id 'external'" && echo yes || echo no)"
out="$(EXAKIT_DATASETS=external offer)"
check "EXAKIT_DATASETS=external alone: an answer, nothing loaded, nothing failed" "~rc=0" "$(printf '%s' "$out" | cut -d'~' -f1,2)"
out="$(EXAKIT_DATASETS=nope offer)"
check "an id the kit does not ship still fails the step" "~rc=1" "$(printf '%s' "$out" | cut -d'~' -f1,2)"
# A persona answers through EXAKIT_DATASETS; the file named beside it used to be
# dropped without a word. Now each answers its own row: the datasets, then the
# file, then the external row's command.
out="$(EXAKIT_DATASETS=amazon_sales,external EXAKIT_DATA_FILE="$WORK/mine.csv" offer)"
check "EXAKIT_DATASETS and EXAKIT_DATA_FILE: the datasets, then the file" "LOAD amazon_sales;FILE $WORK/mine.csv;~rc=0" "$(printf '%s' "$out" | cut -d'~' -f1,2)"
check "...then the external row's command, last" "yes" \
    "$(printf '%s' "$out" | cut -d'~' -f3 | grep -q 'Loading a local file (EXAKIT_DATA_FILE).*Connect one any time with: exakit connect' && echo yes || echo no)"
out="$(EXAKIT_LOAD_SAMPLE=0 EXAKIT_DATA_FILE="$WORK/mine.csv" offer)"
check "EXAKIT_LOAD_SAMPLE=0 and a file: the samples are skipped, the file loads" "FILE $WORK/mine.csv;~rc=0" "$(printf '%s' "$out" | cut -d'~' -f1,2)"
out="$(EXAKIT_LOAD_SAMPLE=1 EXAKIT_DATA_FILE="$WORK/mine.csv" offer)"
check "EXAKIT_LOAD_SAMPLE=1 and a file: the sample, then the file" "LOAD tpch(sample);FILE $WORK/mine.csv;~rc=0" "$(printf '%s' "$out" | cut -d'~' -f1,2)"
out="$(EXAKIT_LOAD_SAMPLE=0 offer)"
check "EXAKIT_LOAD_SAMPLE=0 alone still skips everything, as it said" "yes" \
    "$(printf '%s' "$out" | grep -q 'Skipping data loading (EXAKIT_LOAD_SAMPLE=0)' && echo yes || echo no)"
# A refused file beside a dataset answer (a persona's, or EXAKIT_DATASETS) is
# bad input, not a failed step: a warning, and the step is not booked.
out="$(EXAKIT_DATASETS=amazon_sales EXAKIT_DATA_FILE="$WORK/mine.tsv" OFFER_FILE_RC=3 offer)"
check "a dataset answer and a refused file: the dataset, the file, nothing booked" "LOAD amazon_sales;FILE $WORK/mine.tsv;~rc=0" "$(printf '%s' "$out" | cut -d'~' -f1,2)"
check "...the refusal is a warning" "yes" "$(printf '%s' "$out" | grep -q 'The local file was refused (see above)' && echo yes || echo no)"
# An answer that matches nothing is said before the file loads, as on Windows.
out="$(EXAKIT_DATASETS=nope EXAKIT_DATA_FILE="$WORK/mine.csv" offer)"
check "no dataset matched: said before the file loads" "yes" \
    "$(printf '%s' "$out" | cut -d'~' -f3 | grep -q 'matched no bundled dataset.*FILE-RAN' && echo yes || echo no)"
# A dataset and the file both fail: the step is failed once, naming both.
out="$(EXAKIT_DATASETS=tpch EXAKIT_DATA_FILE="$WORK/mine.csv" OFFER_FAIL=tpch OFFER_FILE_RC=1 offer)"
check "a dataset and the file both fail: the step fails" "rc=1" "$(printf '%s' "$out" | cut -d'~' -f2)"
check "...and the note names both reasons" "yes" \
    "$(printf '%s' "$out" | sed -n 's/.*~NOTE=//p' | grep -q "loading dataset 'tpch' did not finish.*loading the local file did not finish" && echo yes || echo no)"
# No answer variables and no terminal: the table's defaults stand, and the
# external row is never one of them.
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }
        exakit_vs_available() { return 0; }
        offer) )"
check "no answers, no terminal: the pending samples, never the wizard" "LOAD tpch;~rc=0" "$(printf '%s' "$out" | cut -d'~' -f1,2)"

echo ""
echo "noninteractive-answers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
