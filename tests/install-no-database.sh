#!/usr/bin/env bash
# install-no-database.sh - an install that ends with no usable database must
# not exit 0.
#
#   bash tests/install-no-database.sh
#
# THE BUG (scenario X on WSL, X1): "! Local deployment failed ...", then
# "Skipping exapump, the sample data, the AI bridge and pyexasol", and the
# installer exited 0 over a machine where nothing that needs the database
# was set up. A script or an agent that checks the code read that run as a
# working install.
#
# What is pinned, for setup-macos.sh and setup-linux.sh alike, by running the
# scripts' own code (the database step's if/else and everything from the
# connection panel to the end), not a copy of it:
#   - the first-run arm: a deploy that fails softly ends with exit 7, and the
#     closing ready line is not printed, and the summary never says "ready"
#   - the resume arm: a deployed database that does not start ends with 7
#   - a soft failure beside a working database (the MCP step) still ends 0
#   - a clean run ends 0 and prints the ready line
#   - 7 is the documented constant, and the Windows twin uses the same number
#
# Everything runs against a sandboxed HOME and EXAKIT_HOME, with the steps'
# work stubbed: no launcher, no database, no installed kit is touched.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
    fi
}
contains() { # contains <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s contains "%s"\n' "$1" "$2" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}
lacks() { # lacks <label> <needle> <haystack>
    case "$3" in
        *"$2"*) FAIL=$((FAIL + 1)); printf '  FAIL %s: must not contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
        *)      PASS=$((PASS + 1)); printf '  ok   %s lacks "%s"\n' "$1" "$2" ;;
    esac
}

SBHOME="$TMP/home"
mkdir -p "$SBHOME"
case "$SBHOME" in "$HOME"|"$HOME/") echo "refusing: sandbox HOME is the real HOME"; exit 1 ;; esac

# The harness: the real common.sh, the steps' work stubbed, then the setup
# script's own database step and its own closing lines, run as written.
# STUB_DEPLOY_RC: what personal_deploy_local answers (1 = the soft failure).
# STUB_BEGIN_RC: what begin_step answers (0 = first run, 1 = the step is done).
# STUB_START_RC: what the resume arm's start answers.
# STUB_MCP_FAILED=1: the MCP step did not complete (a working database).
cat > "$TMP/run.sh" <<'HARNESS'
set -u
. "$ROOT_REPO/setup/lib/common.sh" >/dev/null 2>&1
EXAKIT_MANIFEST="$EXAKIT_HOME/manifest.json"; export EXAKIT_MANIFEST
EXAKIT_FAILURE_NOTE="$EXAKIT_HOME/.last-failure"; export EXAKIT_FAILURE_NOTE
EXAKIT_LOG_FILE=""
KIT_ROOT="$EXAKIT_HOME"
# The steps' work.
begin_step() { return "${STUB_BEGIN_RC:-0}"; }
mark_step() { printf 'MARK %s\n' "$1"; }
personal_deploy_local() { [ "${STUB_DEPLOY_RC:-0}" = 0 ] && return 0; exakit_note_failure "the launcher refused the deploy"; return 1; }
personal_clear_stale_record() { :; }
personal_deployment_exists() { return 0; }
personal_deployment_running() { return 1; }
personal_start() { [ "${STUB_START_RC:-0}" = 0 ]; }
personal_wait_ready_or_deploy() { return 0; }
exakit_retire_start_soft_failure() { :; }
rollback_clear() { :; }
exakit_install_command() { printf 'curl -fsSL https://www.exasol.com/install/starter-kit.sh | sh'; }
# The closing lines' neighbours, which have nothing to do with the exit.
connection_summary() { printf 'PANEL\n'; }
exakit_print_whats_new_box() { :; }
exakit_print_ready_line() { [ -z "${EXAKIT_SOFT_FAILED:-}" ] && printf 'READY LINE\n'; return 0; }
exakit_autostart_default_on() { :; }
exakit_marketplace_offer() { :; }
exakit_addons_early_report() { :; }
exakit_core_rerun_active() { return 1; }
ui_rule() { :; }
exakit_closing_hint() { printf 'CLOSING\n'; }
exakit_prune_soft_failures() { :; }
# The script's database step (its whole if/else) and its closing lines.
_arm="$(awk '/^if begin_step runtime/ {on=1} on {print} on && /^fi$/ {exit}' "$ROOT_REPO/setup/$SETUP")"
_close="$(sed -n '/^connection_summary$/,$p' "$ROOT_REPO/setup/$SETUP")"
[ -n "$_arm" ] && [ -n "$_close" ] || { printf 'HARNESS could not find the steps in %s\n' "$SETUP"; exit 99; }
eval "$_arm"
[ "${STUB_MCP_FAILED:-0}" = 1 ] && exakit_record_soft_failure mcp "exakit mcp-setup" "the MCP server did not answer" "AI client (MCP) setup"
eval "$_close"
printf 'FELL THROUGH\n'
HARNESS

run() { # run <setup script> env... -> output, then RC=<code>
    _s="$1"; shift
    rm -rf "$TMP/kit-home"; mkdir -p "$TMP/kit-home"
    env HOME="$SBHOME" EXAKIT_HOME="$TMP/kit-home" ROOT_REPO="$ROOT" SETUP="$_s" "$@" \
        bash "$TMP/run.sh" 2>&1
    printf 'RC=%s\n' "$?"
}

for SETUP in setup-macos.sh setup-linux.sh; do
    echo "$SETUP:"

    out="$(run "$SETUP" STUB_DEPLOY_RC=1)"
    contains "a failed deploy is recorded as a soft failure" "The database was not installed" "$out"
    contains "  the install exits 7 (no usable database)" "RC=7" "$out"
    lacks    "  and the ready line is not printed" "READY LINE" "$out"
    lacks    "  and the closing summary does not say ready" "ready" "$out"
    contains "  it says no database is usable" "No database is usable, so the steps that need one were skipped." "$out"
    contains "  the closing lines still ran" "CLOSING" "$out"

    out="$(run "$SETUP" STUB_BEGIN_RC=1 STUB_START_RC=1)"
    contains "a deployed database that does not start" "The database was not started" "$out"
    contains "  exits 7 too" "RC=7" "$out"

    out="$(run "$SETUP" STUB_DEPLOY_RC=0 STUB_MCP_FAILED=1)"
    contains "a soft failure beside a working database" "AI client (MCP) setup" "$out"
    contains "  still exits 0, as before" "RC=0" "$out"
    lacks    "  and does not fall through without an exit" "FELL THROUGH" "$out"

    out="$(run "$SETUP" STUB_DEPLOY_RC=0)"
    contains "a clean run exits 0" "RC=0" "$out"
    contains "  with the ready line" "READY LINE" "$out"
done

echo "the code is the documented one, on both sides:"
check "EXAKIT_EXIT_NO_DATABASE is 7" "7" \
    "$(sed -n 's/^EXAKIT_EXIT_NO_DATABASE=//p' "$ROOT/setup/lib/common.sh")"
check "the Windows twin is 7 too" "7" \
    "$(sed -n 's/^\$script:ExakitExitNoDatabase = //p' "$ROOT/setup/lib/exakit-common.ps1")"
contains "setup-windows.ps1 ends a no-database run with it" 'if ($installExit -ne 0) { exit $installExit }' \
    "$(cat "$ROOT/setup/setup-windows.ps1")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
