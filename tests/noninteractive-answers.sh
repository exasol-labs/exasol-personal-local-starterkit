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

echo ""
echo "noninteractive-answers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
