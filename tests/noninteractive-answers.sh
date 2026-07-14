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

echo ""
echo "noninteractive-answers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
