#!/usr/bin/env bash
# personal-fresh-password.sh - a replaced database is a new database. From
# Exasol Personal 2.4 it has its own random sys password and, always, its own
# users, so the exapump profile and the MCP read-only user are rebuilt, never
# skipped as "already done":
#   - exapump_profile_password_stale: the profile against the credential file
#   - step_artifact_state exapump: "missing", with its reason, over a stale profile
#   - personal_forget_database_steps drops exapump and mcp, nothing else, and
#     runs on the fresh deploy path right before the manifest is recorded
#   - the PowerShell twins
#
# The real functions, extracted, over a flat manifest and a temp profile.
# No database, no launcher.

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

# --- harness ------------------------------------------------------------------
eval "$(sed -n '/^exapump_profile_password_stale()/,/^}/p' "$ROOT/setup/lib/exapump.sh")"
eval "$(sed -n '/^step_artifact_state()/,/^}/p' "$ROOT/setup/lib/common.sh")"
eval "$(sed -n '/^personal_forget_database_steps()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
MF="$TMP/manifest"
manifest_get() { grep "^$1=" "$MF" 2>/dev/null | tail -1 | cut -d= -f2-; grep -q "^$1=" "$MF" 2>/dev/null; }
manifest_set() { { grep -v "^$1=" "$MF" 2>/dev/null || true; } > "$MF.n"; mv "$MF.n" "$MF"; printf '%s=%s\n' "$1" "$2" >> "$MF"; }
manifest_del() { { grep -v "^$1=" "$MF" 2>/dev/null || true; } > "$MF.n"; mv "$MF.n" "$MF"; }
require_python3() { :; }
run_python() { python3 "$@"; }
exakit_unmark_step() { printf '%s\n' "$1" >> "$TMP/unmarked"; }
EXAPUMP_CONFIG="$TMP/config.toml"
EXAKIT_EXAPUMP_PROFILE="starter-kit"
CRED="$TMP/personal_sys_password"
printf '#!/bin/sh\nexit 0\n' > "$TMP/exapump"; chmod +x "$TMP/exapump"
: > "$MF"
manifest_set components.exapump.path "$TMP/exapump"
manifest_set runtime.password_file "$CRED"

profile() { # profile <password literal, as written between the quotes>
    printf '[other]\nhost = "db.example"\npassword = "unrelated"\n\n[starter-kit]\nhost = "127.0.0.1"\nport = 8563\nuser = "sys"\npassword = "%s"\ntls = true\nvalidate_certificate = false\n' "$1" > "$EXAPUMP_CONFIG"
}
stale() { exapump_profile_password_stale >/dev/null 2>&1; printf '%s' "$?"; }
state() { EXAKIT_STEP_RERUN_REASON=""; step_artifact_state exapump; }
reason() { EXAKIT_STEP_RERUN_REASON=""; step_artifact_state exapump >/dev/null; printf '%s' "$EXAKIT_STEP_RERUN_REASON"; }

echo "exapump_profile_password_stale: the profile against the credential file"
rm -f "$EXAPUMP_CONFIG"; printf 'alpha\n' > "$CRED"
check "no profile -> not stale"                   1 "$(stale)"
profile "alpha"
check "same password -> not stale"                1 "$(stale)"
printf 'beta16characters\n' > "$CRED"
check "new password on file -> stale"             0 "$(stale)"
printf 'p"w\\d\n' > "$CRED"
profile 'p\"w\\d'
check "PowerShell-escaped quote and backslash"    1 "$(stale)"
profile 'p"w\d'
check "shell writer, unescaped"                   1 "$(stale)"
: > "$CRED"
check "empty credential file -> not stale"        1 "$(stale)"
printf 'alpha\n' > "$CRED"; profile "alpha"
manifest_del runtime.password_file
check "no password_file recorded -> not stale"    1 "$(stale)"
manifest_set runtime.password_file "$CRED"
printf '[starter-kit]\nhost = "127.0.0.1"\n' > "$EXAPUMP_CONFIG"
check "profile without a password line"          1 "$(stale)"
out="$(profile "alpha"; printf 'beta\n' > "$CRED"; exapump_profile_password_stale 2>&1)"
check "prints nothing, ever"                      "" "$out"

echo
echo "step_artifact_state exapump: a stale profile re-runs the step, with its reason"
printf 'alpha\n' > "$CRED"; profile "alpha"
check "binary + matching profile -> present"      present "$(state)"
printf 'beta\n' > "$CRED"
check "binary + stale profile -> missing"         missing "$(state)"
contains "  and says why"                         "no longer accepts" "$(reason)"
rm -f "$EXAPUMP_CONFIG"
check "profile gone -> missing (as before)"       missing "$(state)"
contains "  with the older reason"                "profile is gone" "$(reason)"
profile "beta"
check "profile rewritten -> present again"        present "$(state)"
rm -f "$TMP/exapump"
check "binary gone -> missing (as before)"        missing "$(state)"

echo
echo "personal_forget_database_steps: exapump and mcp, nothing else"
rm -f "$TMP/unmarked"
personal_forget_database_steps; rc=$?
check "returns 0"                                 0 "$rc"
check "drops exactly exapump then mcp"            "exapump mcp" "$(tr '\n' ' ' < "$TMP/unmarked" | sed 's/ $//')"
rm -f "$TMP/unmarked"
( unset -f exakit_unmark_step; personal_forget_database_steps ); rc=$?
check "without the helper -> no-op, rc 0"         0 "$rc"
check "  and nothing dropped"                     0 "$( [ -f "$TMP/unmarked" ] && wc -l < "$TMP/unmarked" | tr -d ' ' || echo 0)"

echo
echo "wiring: the fresh deploy path, right before the manifest is recorded"
RP="$ROOT/setup/lib/runtime-personal.sh"
check "called once in runtime-personal.sh"        1 "$(grep -c '^    personal_forget_database_steps$' "$RP")"
check "  on the line before the fresh record"     1 "$(grep -B1 '^    personal_record_manifest "healthy"$' "$RP" | grep -c 'personal_forget_database_steps')"
check "  never on a reuse path (indented deeper)" 0 "$(grep -c '^        *personal_forget_database_steps' "$RP")"
check "step_artifact_state asks the probe"        1 "$(grep -c 'exapump_profile_password_stale; then' "$ROOT/setup/lib/common.sh")"
RPS="$ROOT/setup/lib/runtime-personal.ps1"
check "ps1: Clear-PersonalDatabaseSteps defined"  1 "$(grep -c '^function Clear-PersonalDatabaseSteps' "$RPS")"
check "  called once"                             1 "$(grep -c '^    Clear-PersonalDatabaseSteps$' "$RPS")"
check "  before the fresh record"                 1 "$(grep -B1 '^    Set-PersonalManifest "healthy"$' "$RPS" | grep -c 'Clear-PersonalDatabaseSteps')"
check "  drops exapump and mcp"                   1 "$(grep -c '@("exapump", "mcp")' "$RPS")"
check "ps1: artifact state asks the twin probe"   1 "$(grep -c 'Test-ExapumpProfilePasswordStale)) {' "$ROOT/setup/lib/exakit-common.ps1")"
check "ps1: the probe exists"                     1 "$(grep -c '^function Test-ExapumpProfilePasswordStale' "$ROOT/setup/lib/exapump.ps1")"

# The Windows twin, wherever a PowerShell is at hand to run it.
if command -v pwsh >/dev/null 2>&1; then
    echo
    if pwsh -NoProfile -NonInteractive -File "$ROOT/tests/personal-fresh-password-ps.ps1"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "  FAIL personal-fresh-password-ps.ps1"
    fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
