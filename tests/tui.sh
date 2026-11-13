#!/usr/bin/env bash
# exakit's terminal view, as the CLI launches it (setup/lib/tui.sh): a bare `exakit` opens it only for a person at a
# terminal, `exakit <persona-id>` opens that persona's page (or prints it without a terminal), `exakit tui` refuses
# without one, and its options are checked. The view itself is tested in test_tui.py.

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
contains() { # contains <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}

export HOME="$WORK/home" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
EXAKIT="$ROOT/setup/exakit"

echo "without a terminal nothing changes for scripts and agents:"
out="$(bash "$EXAKIT" </dev/null 2>&1)"; code=$?
check "bare exakit, piped: exit 0" "0" "$code"
contains "bare exakit, piped: the help" "exakit status" "$out"
out="$(bash "$EXAKIT" data-scientist </dev/null 2>&1)"; code=$?
check "exakit <persona>, piped: exit 0" "0" "$code"
contains "exakit <persona>, piped: the persona, as persona show prints it" "Data Scientist" "$out"
out="$(bash "$EXAKIT" tui </dev/null 2>&1)"; code=$?
check "exakit tui, piped: refused" "2" "$code"
contains "exakit tui, piped: says what to use instead" "exakit status --json" "$out"
out="$(bash "$EXAKIT" tui --tab nope </dev/null 2>&1)"; code=$?
check "an unknown tab is refused" "2" "$code"
contains "and the tabs are named" "status, marketplace, clients, sources, personas" "$out"
out="$(bash "$EXAKIT" no-such-word </dev/null 2>&1)"; code=$?
check "a word that is neither command nor persona is still unknown" "2" "$code"
out="$(bash "$EXAKIT" data-scientist extra </dev/null 2>&1)"; code=$?
check "a persona with more words is not a persona page" "2" "$code"

echo "the decision a bare exakit makes:"
# shellcheck disable=SC1091
. "$ROOT/setup/lib/tui.sh"
check "piped: no view" "no" "$(exakit_tui_wanted </dev/null >/dev/null && echo yes || echo no; true)"
check "EXAKIT_NO_TUI=1: no view" "no" "$(EXAKIT_NO_TUI=1 exakit_tui_wanted && echo yes || echo no)"
check "CI: no view" "no" "$(CI=1 exakit_tui_wanted && echo yes || echo no)"
check "TERM=dumb: no view" "no" "$(TERM=dumb exakit_tui_wanted && echo yes || echo no)"

echo "the launcher:"
check "the view runs on the kit's one Textual pin" "yes" \
    "$(grep -q 'from launch import textual_pin' "$ROOT/setup/tui/start.py" && echo yes || echo no)"
check "and adds no environment of its own" "no" "$(grep -q 'tui-venv' "$ROOT/setup/lib/tui.sh" "$ROOT/setup/lib/tui.ps1" && echo yes || echo no)"
out="$(EXAKIT_UV_BIN=/nonexistent PATH=/usr/bin:/bin python3 "$ROOT/setup/tui/start.py" "$ROOT" --cli=true 2>&1 </dev/null)"; code=$?
if [ "$code" = 11 ]; then
    contains "no uv and no pinned Textual: says what is missing" "needs uv or Textual" "$out"
else
    PASS=$((PASS + 1)); printf '  ok   (skipped: this machine has a uv or the pinned Textual on the plain PATH)\n'
fi

echo "the shells are twins:"
for fn in exakit_tui_wanted:Test-ExakitTuiWanted cmd_tui:Invoke-CmdTui exakit_tui_persona:Invoke-ExakitTuiPersona \
          exakit_tui_is_persona:Test-ExakitTuiIsPersona; do
    sh_fn="${fn%%:*}"; ps_fn="${fn#*:}"
    check "$sh_fn has its twin $ps_fn" "yes" \
        "$(grep -q "^$sh_fn()" "$ROOT/setup/lib/tui.sh" && grep -q "^function $ps_fn" "$ROOT/setup/lib/tui.ps1" && echo yes || echo no)"
done
check "exakit.ps1 has the tui command" "yes" "$(grep -q '"tui" *{ Invoke-CmdTui' "$ROOT/setup/exakit.ps1" && echo yes || echo no)"
check "exakit.ps1 opens a persona's page" "yes" "$(grep -q 'Invoke-ExakitTuiPersona -Id \$Command' "$ROOT/setup/exakit.ps1" && echo yes || echo no)"

printf '\ntui.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
